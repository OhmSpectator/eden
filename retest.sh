#!/bin/bash

# USB Boot Priority Test Setup Script (v2)
# This script sets up Eden with a bootable USB disk for testing USB boot priority
# feature via LPS (Local Profile Server) or Controller API.
#
# Two test modes:
#   - LPS mode (default): Tests boot order via LPS /api/v1/appbootinfo endpoint
#   - Controller mode (--controller): Tests boot order via VmConfig.boot_order in EdgeDevConfig
#
# Test Cases covered by usb_boot_priority.txt (LPS mode):
# 1. Custom resolution, no fw_cfg -> HDD boot (Ubuntu) - default boot order
# 2. No resolution, no fw_cfg -> USB boot (Debian) - OVMF default prefers USB
# 3. Custom resolution, fw_cfg="usb" -> USB boot (Debian) - fw_cfg overrides
# 4. No resolution, fw_cfg="usb" -> USB boot (Debian) - fw_cfg confirms USB priority
# 5. Custom resolution, fw_cfg="nousb" -> HDD boot (Ubuntu) - fw_cfg deprioritizes USB
# 6. No resolution, fw_cfg="nousb" -> HDD boot (Ubuntu) - fw_cfg overrides OVMF default
#
# Test Cases covered by usb_boot_priority_controller.txt (Controller mode):
# 1. Custom resolution + --boot-order=usb -> USB boot (Debian) - fw_cfg overrides resolution
# 2. Custom resolution + --boot-order=nousb -> HDD boot (Ubuntu) - fw_cfg confirms HDD priority
# 3. Custom resolution + no --boot-order -> HDD boot (Ubuntu) - resolution causes HDD boot
# 4. No resolution + --boot-order=nousb -> HDD boot (Ubuntu) - fw_cfg overrides OVMF default
#
# Additional: Persistence tests and multi-VM per-VM boot control

set -e

# Parse arguments
EVE_TAG=""
SKIP_USB_DISK=false
SKIP_BUILD=false
FULL_CLEAN=false
TEST_FILE="usb_boot_priority"
DRY_RUN=false
CONTROLLER_TEST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-usb)
            SKIP_USB_DISK=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --full-clean)
            FULL_CLEAN=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --test)
            TEST_FILE="$2"
            shift 2
            ;;
        --controller)
            CONTROLLER_TEST=true
            # Controller tests are now at the beginning of usb_boot_priority
            # The full test runs both controller and LPS tests
            TEST_FILE="usb_boot_priority"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [EVE_TAG]"
            echo ""
            echo "Options:"
            echo "  --skip-usb     Skip USB disk creation (use existing)"
            echo "  --skip-build   Skip Eden build (use existing binary)"
            echo "  --full-clean   Do a full clean before building"
            echo "  --dry-run      Setup only, don't run tests"
            echo "  --test FILE    Test file to run (default: usb_boot_priority)"
            echo "  --controller   Run controller API tests first (default behavior now)"
            echo "  --help, -h     Show this help"
            echo ""
            echo "  EVE_TAG        EVE version tag (auto-detected if not provided)"
            echo ""
            echo "Test file options:"
            echo "  usb_boot_priority             Full test (Controller API + LPS tests)"
            echo "  usb_boot_priority_controller  Controller API only test (standalone)"
            echo "  usb_boot_multivm_only         Only the multi-VM test (for retesting)"
            exit 0
            ;;
        *)
            EVE_TAG="$1"
            shift
            ;;
    esac
done

# Store cloud images outside dist to survive clean
CACHE_DIR="/home/nikolay/projects/eden/.cache"
USB_DISK_DIR="/home/nikolay/projects/eden/dist"
USB_DISK_IMAGE="$USB_DISK_DIR/usb-boot.img"
CLOUD_IMAGE="$CACHE_DIR/debian-cloud.raw"

mkdir -p "$CACHE_DIR"

echo "=== USB Boot Priority Test Setup v2 ==="
if [ "$CONTROLLER_TEST" = "true" ]; then
    echo "Test mode: Controller API (VmConfig.boot_order)"
else
    echo "Test mode: LPS API (/api/v1/appbootinfo)"
fi
echo "Test file: $TEST_FILE"
echo ""

# Auto-detect EVE version if not provided
if [ -z "$EVE_TAG" ]; then
    echo "No EVE tag provided, auto-detecting latest local EVE build..."

    # Look for lfedge/eve images, extract the version tag
    LATEST_EVE=$(docker images --format '{{.Tag}}' lfedge/eve 2>/dev/null | \
        grep -E '.*-kvm-amd64$' | \
        sed 's/-kvm-amd64$//' | \
        sort -r | \
        head -1)

    if [ -n "$LATEST_EVE" ]; then
        EVE_TAG="$LATEST_EVE"
        echo "Auto-detected EVE version: $EVE_TAG"
    else
        echo "WARNING: Could not auto-detect EVE version from docker images"
        echo "Available lfedge/eve images:"
        docker images | grep "lfedge/eve" | head -10
        echo ""
        echo "Usage: $0 [--skip-usb] [EVE_TAG]"
        echo "  --skip-usb     Skip USB disk creation (use existing)"
        echo "  EVE_TAG        EVE version tag (auto-detected if not provided)"
        exit 1
    fi
else
    echo "Using provided EVE tag: $EVE_TAG"
fi

# Step 1: Build Eden
if [ "$SKIP_BUILD" = "false" ]; then
    echo ""
    echo "=== Step 1: Building Eden ==="
    if [ "$FULL_CLEAN" = "true" ]; then
        echo "Doing full clean..."
        make clean
    fi
    make build-tests
else
    echo ""
    echo "=== Step 1: Skipping build (--skip-build) ==="
    if [ ! -f "./eden" ] && [ ! -f "./dist/bin/eden" ]; then
        echo "ERROR: Eden binary not found. Run without --skip-build first."
        exit 1
    fi
fi

# Step 1b: Stop any running Eden instance
echo ""
echo "=== Step 1b: Stopping any running Eden instance ==="
./eden stop 2>/dev/null || true
./eden clean --current-context=false 2>/dev/null || true

# Step 2: Download a bootable cloud image for USB boot testing
# We need an image that boots via UEFI and has console output for verification
echo ""
echo "=== Step 2: Preparing USB boot disk (Debian cloud image) ==="
if [ "$SKIP_USB_DISK" = "false" ]; then
    mkdir -p "$USB_DISK_DIR"
    mkdir -p "$CACHE_DIR"

    # Use Debian cloud image - UEFI bootable with clear console identification
    DEBIAN_VERSION="12"
    DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-${DEBIAN_VERSION}-nocloud-amd64.raw"

    # Only download if not already in cache
    if [ ! -f "$CLOUD_IMAGE" ]; then
        echo "Downloading Debian cloud image (this may take a few minutes)..."
        echo "URL: $DEBIAN_URL"
        curl -L -o "$CLOUD_IMAGE" "$DEBIAN_URL"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to download Debian cloud image"
            echo "You can manually download from: $DEBIAN_URL"
            exit 1
        fi
    else
        echo "Using cached cloud image: $CLOUD_IMAGE"
    fi

    # Only create USB image if not already present
    if [ ! -f "$USB_DISK_IMAGE" ]; then
        echo "Creating USB disk image from cloud image..."
        cp "$CLOUD_IMAGE" "$USB_DISK_IMAGE"
        echo "USB disk image created: $USB_DISK_IMAGE"
    else
        echo "Using existing USB disk image: $USB_DISK_IMAGE"
    fi

    ls -lh "$USB_DISK_IMAGE"
else
    echo "Skipping USB disk preparation (--skip-usb)"
    if [ ! -f "$USB_DISK_IMAGE" ]; then
        echo "ERROR: USB disk image not found: $USB_DISK_IMAGE"
        echo "Run without --skip-usb first to create it"
        exit 1
    else
        echo "Using existing USB disk image: $USB_DISK_IMAGE"
        ls -lh "$USB_DISK_IMAGE"
    fi
fi

# Step 3: Configure Eden with USB disk
echo ""
echo "=== Step 3: Configuring Eden ==="
echo "  USB disk: $USB_DISK_IMAGE"
echo "  EVE tag: $EVE_TAG"
echo "  TPM: enabled"

# First create config with USB disks
./eden config add default --force --eve-usb-disks="$USB_DISK_IMAGE"

# Now we need to set EVE tag and TPM without wiping usb-disks
# Use yq if available, otherwise use Python for proper YAML editing
if command -v yq &> /dev/null; then
    echo "Using yq to update config..."
    yq -i '.eve.tag = "'"$EVE_TAG"'"' ~/.eden/contexts/default.yml
    yq -i '.eve.tpm = false' ~/.eden/contexts/default.yml
elif command -v python3 &> /dev/null; then
    echo "Using Python to update config..."
    python3 << PYEOF
import yaml
with open('$HOME/.eden/contexts/default.yml', 'r') as f:
    config = yaml.safe_load(f)
config['eve']['tag'] = '$EVE_TAG'
config['eve']['tpm'] = False
with open('$HOME/.eden/contexts/default.yml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
PYEOF
else
    echo "WARNING: Neither yq nor python3 available. Manually setting EVE tag..."
    # Fallback: use awk to target only the eve section's tag
    awk -v tag="$EVE_TAG" '
        /^eve:/ { in_eve=1 }
        /^[a-z]/ && !/^eve:/ { in_eve=0 }
        in_eve && /^  tag:/ && !tag_set { $0="  tag: '\''" tag "'\''"; tag_set=1 }
        in_eve && /^  tpm:/ { $0="  tpm: false" }
        { print }
    ' ~/.eden/contexts/default.yml > ~/.eden/contexts/default.yml.tmp && \
    mv ~/.eden/contexts/default.yml.tmp ~/.eden/contexts/default.yml
fi

# Verify config
echo ""
echo "Verifying configuration..."
echo "USB disks:"
grep -A2 "usb-disks" ~/.eden/contexts/default.yml || echo "WARNING: usb-disks not found in config"
echo ""
echo "EVE tag:"
grep "tag: '$EVE_TAG'" ~/.eden/contexts/default.yml | head -1 || echo "WARNING: EVE tag not set correctly"
echo ""
echo "TPM:"
grep "tpm:" ~/.eden/contexts/default.yml | head -1

# Step 4: Setup Eden
echo ""
echo "=== Step 4: Running Eden setup ==="
./eden setup

# Step 5: Configure port forwarding
echo ""
echo "=== Step 5: Configuring port forwarding ==="
# Ports needed:
# 2223/2224: SSH access
# 8027: local-manager SSH
# 8028-8031: test VMs SSH
./dist/bin/eden+ports.sh 2223:2223 2224:2224 8027:8027 8028:8028 8029:8029 8030:8030 8031:8031

# Step 6: Start Eden
echo ""
echo "=== Step 6: Starting Eden ==="
./eden start

# Step 7: Wait and onboard EVE
echo ""
echo "=== Step 7: Waiting for EVE to start ==="
sleep 30

echo "Onboarding EVE..."
# Try onboarding with retries
MAX_ONBOARD_RETRIES=3
ONBOARD_SUCCESS=false
for i in $(seq 1 $MAX_ONBOARD_RETRIES); do
    echo "Onboarding attempt $i of $MAX_ONBOARD_RETRIES..."
    if ./eden eve onboard; then
        ONBOARD_SUCCESS=true
        break
    else
        if [ $i -lt $MAX_ONBOARD_RETRIES ]; then
            echo "Onboarding failed, waiting 60s before retry..."
            # Check if EVE is actually running
            echo "Checking EVE status..."
            ./eden eve status || true
            sleep 60
        fi
    fi
done

if [ "$ONBOARD_SUCCESS" != "true" ]; then
    echo ""
    echo "=== EVE ONBOARDING FAILED ==="
    echo ""
    echo "EVE failed to register with Adam after multiple attempts."
    echo ""
    echo "Debugging steps:"
    echo "  1. Check EVE log: tail -100 /home/nikolay/projects/eden/dist/default-eve.log"
    echo "  2. Check EVE status: ./eden eve status"
    echo "  3. Try manual onboard: ./eden eve onboard"
    echo "  4. Check if EVE booted: ./eden eve ssh 'uptime'"
    echo ""
    echo "The test environment is still running. You can debug manually."
    exit 1
fi

# Step 8: Verify USB disk is visible in EVE
echo ""
echo "=== Step 8: Verifying USB disk setup ==="
echo "Checking USB devices in EVE..."
./eden eve ssh 'lsusb' || true
echo ""
echo "Checking block devices..."
./eden eve ssh 'lsblk' || true
echo ""
echo "Checking USB address (spec.sh -u)..."
./eden eve ssh 'spec.sh -u' 2>/dev/null | grep -A5 "USB" || true

echo ""
echo "=== Setup Complete ==="
echo ""
echo "USB disk image: $USB_DISK_IMAGE"
echo ""
echo "To verify EVE sees the USB disk:"
echo "  ./eden eve ssh 'lsblk; lsusb'"
echo ""
echo "To check USB address for passthrough:"
echo "  ./eden eve ssh 'spec.sh -u'"
echo ""

# Check if dry run
if [ "$DRY_RUN" = "true" ]; then
    echo "=== DRY RUN - Setup complete, not running tests ==="
    echo ""
    echo "To run tests manually:"
    echo "  ./eden test tests/eclient -v debug -e $TEST_FILE"
    echo ""
    exit 0
fi

# Run the test automatically
echo "=== Running USB Boot Priority Test v2 ==="
echo "Test file: $TEST_FILE"
echo ""

LOG_FILE="/tmp/usb-boot-test-$(date +%Y%m%d-%H%M%S).log"
echo "Log file: $LOG_FILE"
echo ""

# Use stdbuf to disable buffering for real-time output
stdbuf -oL -eL ./eden test tests/eclient -v debug -e "$TEST_FILE" 2>&1 | tee "$LOG_FILE"
TEST_EXIT=$?

echo ""
echo "=== TEST COMPLETE ==="
echo "Exit code: $TEST_EXIT"
echo "Log saved to: $LOG_FILE"

if [ $TEST_EXIT -ne 0 ]; then
    echo ""
    echo "Test FAILED. To debug:"
    echo ""
    echo "1. Check EVE logs for USB/boot/fw_cfg messages:"
    echo "   ./eden eve ssh 'logread | grep -iE \"usb|boot|fw_cfg|bootorder\" | tail -50'"
    echo ""
    echo "2. Check USB devices in EVE:"
    echo "   ./eden eve ssh 'lsblk; lsusb'"
    echo ""
    echo "3. Check VM QEMU config for fw_cfg:"
    echo "   ./eden eve ssh 'cat /run/domainmgr/xen/xen*.cfg | grep -A5 fw_cfg'"
    echo ""
    echo "4. Check OVMF debug log (if available):"
    echo "   ./eden eve ssh 'cat /run/hypervisor/kvm/*/ovmf-debug.log 2>/dev/null | tail -50'"
    echo ""
    echo "5. Check VM console logs for boot OS:"
    echo "   ./eden pod logs test-usb-boot-vm | grep -E 'Welcome|Debian|Ubuntu' | tail -20"
    echo ""
    echo "6. Review full log file:"
    echo "   less $LOG_FILE"
    echo ""
    echo "7. Check LPS API on local-manager:"
    echo "   ./eden sdn fwd eth0 8027 -- ssh -o StrictHostKeyChecking=no -i dist/tests/eclient/image/cert/id_rsa root@FWD_IP -p FWD_PORT 'cat /mnt/usbbootprio'"
    echo ""
    exit 1
else
    echo ""
    echo "Test PASSED!"
    echo ""
    if [ "$CONTROLLER_TEST" = "true" ]; then
        echo "All Controller API test cases verified:"
        echo "  TC1: Custom resolution + --boot-order=usb   -> Debian (USB)"
        echo "  TC2: Custom resolution + --boot-order=nousb -> Ubuntu (HDD)"
        echo "  TC3: Custom resolution + no --boot-order    -> Ubuntu (HDD)"
        echo "  TC4: No resolution + --boot-order=nousb     -> Ubuntu (HDD)"
    else
        echo "All test cases verified:"
        echo ""
        echo "Controller API tests (TC-CTRL-1 to TC-CTRL-4):"
        echo "  TC-CTRL-1: Custom resolution + boot_order=usb   -> Debian (USB)"
        echo "  TC-CTRL-2: Custom resolution + boot_order=nousb -> Ubuntu (HDD)"
        echo "  TC-CTRL-3: Custom resolution + no boot_order    -> Ubuntu (HDD)"
        echo "  TC-CTRL-4: No resolution + boot_order=nousb     -> Ubuntu (HDD)"
        echo ""
        echo "LPS tests (TC1 to TC17):"
        echo "  TC1-TC6: Boot order with resolution/fw_cfg combinations"
        echo "  TC7: Multi-VM per-VM boot control"
        echo "  TC8-TC17: LPS config parsing, HTTP status, reset, persistence"
    fi
fi

