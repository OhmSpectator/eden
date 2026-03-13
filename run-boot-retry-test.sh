#!/bin/bash

# Boot Retry globalConfig Test Runner
# This script sets up a clean environment and runs the boot retry test.
#
# The test verifies that maybeRetryBoot passes globalConfig correctly,
# so device-wide settings like memory.vmm.limit.MiB are applied during
# automatic boot retries after VM boot failures.
#
# PREREQUISITES:
# - EVE image with the maybeRetryBoot fix (globalConfig passed correctly)
# - EVE with KVM support
#
# Usage:
#   ./run-boot-retry-test.sh [EVE_TAG]
#   ./run-boot-retry-test.sh --skip-setup [EVE_TAG]
#
# Options:
#   --skip-setup   Skip clean/setup, only run the test
#   EVE_TAG        EVE version tag (auto-detected if not provided)

set -e

SKIP_SETUP=false
EVE_TAG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [EVE_TAG]"
            echo ""
            echo "Options:"
            echo "  --skip-setup   Skip clean/setup, only run the test"
            echo "  --help, -h     Show this help"
            echo ""
            echo "  EVE_TAG        EVE version tag (auto-detected if not provided)"
            exit 0
            ;;
        *)
            EVE_TAG="$1"
            shift
            ;;
    esac
done

echo "=== Boot Retry globalConfig Test Runner ==="
echo ""

# Auto-detect EVE version if not provided
if [ -z "$EVE_TAG" ]; then
    echo "No EVE tag provided, auto-detecting latest local EVE build..."

    LATEST_EVE=$(docker images --format '{{.Tag}}' lfedge/eve 2>/dev/null | \
        grep -E '.*-kvm-amd64$' | \
        sed 's/-kvm-amd64$//' | \
        sort -r | \
        head -1)

    if [ -n "$LATEST_EVE" ]; then
        EVE_TAG="$LATEST_EVE"
        echo "Auto-detected EVE version: $EVE_TAG"
    else
        echo "WARNING: Could not auto-detect EVE version"
        echo "Available lfedge/eve images:"
        docker images | grep "lfedge/eve" | head -10
        echo ""
        echo "Usage: $0 [EVE_TAG]"
        exit 1
    fi
else
    echo "Using provided EVE tag: $EVE_TAG"
fi

if [ "$SKIP_SETUP" = "false" ]; then
    # Clean environment
    echo ""
    echo "=== Step 1: Cleaning environment ==="
    echo "Stopping Eden..."
    ./eden stop 2>/dev/null || true

    echo "Cleaning Eden context (preserving config)..."
    ./eden clean --current-context=false 2>/dev/null || true

    # Build Eden
    echo ""
    echo "=== Step 2: Building Eden ==="
    make build-tests

    # Configure Eden
    echo ""
    echo "=== Step 3: Configuring Eden ==="
    ./eden config add default --force
    ./eden config set default --key eve.tag --value "$EVE_TAG"
    ./eden config set default --key eve.tpm --value false

    # Setup Eden
    echo ""
    echo "=== Step 4: Running Eden setup ==="
    ./eden setup

    # Start Eden
    echo ""
    echo "=== Step 5: Starting Eden ==="
    ./eden start

    # Onboard EVE
    echo ""
    echo "=== Step 6: Waiting for EVE to start and onboarding ==="
    sleep 30

    echo "Onboarding EVE..."
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
                ./eden eve status || true
                sleep 60
            fi
        fi
    done

    if [ "$ONBOARD_SUCCESS" != "true" ]; then
        echo ""
        echo "=== EVE ONBOARDING FAILED ==="
        echo ""
        echo "Debugging steps:"
        echo "  1. Check EVE log: tail -100 ./dist/default-eve.log"
        echo "  2. Check EVE status: ./eden eve status"
        echo "  3. Try manual onboard: ./eden eve onboard"
        echo ""
        exit 1
    fi

    # Wait for EVE to fully initialize (zedagent must be ready)
    echo ""
    echo "=== Step 7: Waiting for EVE to fully initialize ==="
    echo "Waiting for zedagent ConfigItemValueMap to be available..."
    MAX_INIT_WAIT=60
    for i in $(seq 1 $MAX_INIT_WAIT); do
        if ./eden eve ssh 'test -d /persist/status/zedagent/ConfigItemValueMap' 2>/dev/null; then
            echo "EVE zedagent is ready!"
            break
        fi
        if [ $i -eq $MAX_INIT_WAIT ]; then
            echo "WARNING: zedagent not fully initialized after ${MAX_INIT_WAIT}s, continuing anyway..."
        fi
        echo "Waiting for zedagent... ($i/${MAX_INIT_WAIT})"
        sleep 5
    done

    echo ""
    echo "=== Setup Complete ==="
else
    echo ""
    echo "=== Skipping setup (--skip-setup) ==="
fi

# Run the test
echo ""
echo "=== Running Boot Retry globalConfig Test ==="
echo ""

LOG_FILE="/tmp/boot-retry-test-$(date +%Y%m%d-%H%M%S).log"
echo "Log file: $LOG_FILE"
echo ""

stdbuf -oL -eL ./eden test tests/eclient -v debug -t 20m -e boot_retry_globalconfig 2>&1 | tee "$LOG_FILE"
TEST_EXIT=$?

echo ""
echo "=== TEST COMPLETE ==="
echo "Exit code: $TEST_EXIT"
echo "Log saved to: $LOG_FILE"

if [ $TEST_EXIT -ne 0 ]; then
    echo ""
    echo "Test FAILED. To debug:"
    echo ""
    echo "1. Check EVE status:"
    echo "   ./eden status"
    echo ""
    echo "2. Check domainmgr logs for maybeRetryBoot:"
    echo "   ./eden eve ssh 'logread | grep -iE \"maybeRetryBoot|BootFailed|retry\" | tail -50'"
    echo ""
    echo "3. Check VMM memory limit in global config:"
    echo "   ./eden eve ssh 'cat /persist/status/zedagent/ConfigItemValueMap/global.json | grep memory.vmm'"
    echo ""
    echo "4. Check cgroup memory limits:"
    echo "   ./eden eve ssh 'find /sys/fs/cgroup/memory/eve-user-apps -name \"memory.limit_in_bytes\" -exec cat {} \\;'"
    echo ""
    echo "5. Review full log file:"
    echo "   less $LOG_FILE"
    echo ""
    exit 1
else
    echo ""
    echo "Test PASSED!"
    echo ""
    echo "All test cases verified:"
    echo "  TC1: Deploy VM and verify VMM memory limit from globalConfig"
    echo "  TC2: Cause boot failure by making KVM state dir immutable"
    echo "  TC3: Wait for maybeRetryBoot and verify VMM memory limit preserved"
    echo ""
    echo "The test confirmed that maybeRetryBoot passes globalConfig correctly,"
    echo "so memory.vmm.limit.MiB is applied during automatic boot retries."
fi

