#!/bin/bash

# USB Boot Priority Test Setup Script
# This script sets up the USB disk image required for USB boot priority testing.
# It downloads a Debian cloud image and configures Eden to attach it as a USB disk.
#
# This script can be used in two ways:
# 1. GH Workflow: Called AFTER eden config add, just adds USB disk to existing config
# 2. Manual use: Called BEFORE eden setup, creates config with USB disk
#
# Usage: ./usb-boot-setup.sh [CACHE_DIR]
#
# Environment variables:
#   EDEN_CONFIG - Eden config name (default: "default")
#   USB_BOOT_CACHE_DIR - Directory to cache downloaded images (default: /tmp/eden-usb-boot-cache)
#   EVE_TAG - EVE image tag to use (must have patched OVMF with fw_cfg boot order support)
#   EDEN - Path to eden binary (default: ./eden or eden in PATH)

set -e

EDEN_CONFIG="${EDEN_CONFIG:-default}"
CACHE_DIR="${1:-${USB_BOOT_CACHE_DIR:-/tmp/eden-usb-boot-cache}}"
DIR=$(dirname "$0")
EDEN_ROOT=$(cd "$DIR/../.." && pwd)
PATH="$EDEN_ROOT:$EDEN_ROOT/dist/bin:$PATH"

EDEN="${EDEN:-eden}"

# Determine dist directory
DIST_DIR="$EDEN_ROOT/dist"
USB_DISK_IMAGE="$DIST_DIR/usb-boot.img"
CLOUD_IMAGE="$CACHE_DIR/debian-cloud.raw"
CONFIG_FILE="$HOME/.eden/contexts/$EDEN_CONFIG.yml"

echo "=== USB Boot Priority Test Setup ==="
echo "Config: $EDEN_CONFIG"
echo "Cache dir: $CACHE_DIR"
echo "USB disk: $USB_DISK_IMAGE"

mkdir -p "$CACHE_DIR"
mkdir -p "$DIST_DIR"

# Download Debian cloud image if not cached
DEBIAN_VERSION="12"
DEBIAN_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-${DEBIAN_VERSION}-nocloud-amd64.raw"

if [ ! -f "$CLOUD_IMAGE" ]; then
    echo "Downloading Debian cloud image..."
    echo "URL: $DEBIAN_URL"
    curl -L -o "$CLOUD_IMAGE" "$DEBIAN_URL"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to download Debian cloud image"
        echo "You can manually download from: $DEBIAN_URL"
        exit 1
    fi
    echo "Downloaded: $CLOUD_IMAGE"
else
    echo "Using cached cloud image: $CLOUD_IMAGE"
fi

# Copy to USB disk location
echo "Creating USB disk image from cloud image..."
cp "$CLOUD_IMAGE" "$USB_DISK_IMAGE"
echo "USB disk image created: $USB_DISK_IMAGE"
ls -lh "$USB_DISK_IMAGE"

# Configure Eden with USB disk
echo ""
if [ -f "$CONFIG_FILE" ]; then
    # Config exists (GH workflow mode) - add USB disk to existing config
    echo "Existing config found, adding USB disk..."
    $EDEN config set "$EDEN_CONFIG" --key eve.usb-disks --value "[\"$USB_DISK_IMAGE\"]"

    if [ -n "$EVE_TAG" ]; then
        echo "Setting EVE tag to: $EVE_TAG"
        $EDEN config set "$EDEN_CONFIG" --key eve.tag --value "$EVE_TAG"
        $EDEN config set "$EDEN_CONFIG" --key eve.tpm --value "false"
    fi
else
    # Config doesn't exist (manual mode) - create new config with USB disk and EVE tag
    echo "Creating new Eden config with USB disk..."

    $EDEN config add "$EDEN_CONFIG" --force --eve-usb-disks="$USB_DISK_IMAGE"

    if [ -n "$EVE_TAG" ]; then
        echo "Setting EVE tag to: $EVE_TAG"
        $EDEN config set "$EDEN_CONFIG" --key eve.tag --value "$EVE_TAG"
        $EDEN config set "$EDEN_CONFIG" --key eve.tpm --value "false"
    fi
fi

echo "USB disk configured: $USB_DISK_IMAGE"

echo ""
echo "=== USB Boot Setup Complete ==="
echo "USB disk image: $USB_DISK_IMAGE"
echo ""
echo "Next steps (for manual testing):"
echo "  1. Run: ./eden setup"
echo "  2. Configure port forwarding:"
echo "     ./dist/bin/eden+ports.sh 8027:8027 8028:8028 8029:8029 8030:8030 8031:8031"
echo "  3. Run: ./eden start"
echo "  4. Onboard: ./eden eve onboard"
echo "  5. Run test: ./eden test tests/eclient -v debug -e usb_boot_priority"
echo ""
echo "Note: For GH workflow, these steps are handled automatically."
