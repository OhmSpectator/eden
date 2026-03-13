#!/bin/bash
# Run USB boot priority test and extract debug logs

set -e

echo "========================================"
echo "USB Boot Priority Test with Debug Logs"
echo "========================================"
echo ""

cd /home/nikolay/projects/eden

# Clean up previous test
echo "1. Cleaning up previous test environment..."
./cleanup-usb-test.sh

echo ""
echo "2. Running test (this will take ~3-5 minutes)..."
timeout 600 ./eden test tests/eclient -v debug -e usb_boot_priority 2>&1 | tee /tmp/usb-boot-debug-test.log

# Extract result - check for the final test result line, not intermediate PASS
if grep -q "^PASS$" /tmp/usb-boot-debug-test.log && ! grep -q "^FAIL$" /tmp/usb-boot-debug-test.log; then
    echo ""
    echo "✅ TEST PASSED!"
    echo ""
    echo "Extracting debug logs to verify the flow..."
    ./extract-usb-logs.sh | tee /tmp/usb-debug-extracted.log
    echo ""
    echo "Debug logs saved to: /tmp/usb-debug-extracted.log"
else
    echo ""
    echo "❌ TEST FAILED"
    echo ""
    echo "3. Extracting EVE debug logs to diagnose the issue..."
    echo ""

    # Wait a moment for logs to flush
    sleep 2

    # Extract USB boot related logs from EVE
    echo "=== USB Boot Priority Debug Logs from EVE ==="
    ./extract-usb-logs.sh 2>/dev/null | tee /tmp/usb-debug-extracted.log

    echo ""
    echo "=== Summary of what we're looking for ==="
    echo ""
    echo "Expected flow:"
    echo "  1. [localcommand] Received VM config from LPS with X VMs"
    echo "  2. [localcommand] VM <uuid> (<name>) USB boot priority: true"
    echo "  3. [localcommand] Processing VM config..."
    echo "  4. [localcommand] Publishing VmConfigList to zedagent..."
    echo "  5. [zedagent] handleVmConfigListCreate: Received VmConfigList..."
    echo "  6. [zedagent] updateAppInstanceUsbBoot: START..."
    echo "  7. [zedagent] updateAppInstanceUsbBoot: Found AppInstanceConfig OR not found"
    echo ""
    echo "If you see 'AppInstanceConfig not found' - that's the TIMING BUG!"
    echo "Config arrives before AppInstanceConfig is created."
    echo ""
    echo "Debug logs saved to: /tmp/usb-debug-extracted.log"
    echo "Full test log saved to: /tmp/usb-boot-debug-test.log"
    echo ""
    echo "To see more EVE logs, run:"
    echo "  cd /home/nikolay/projects/eden && ./eden log eve --format json | grep -i vmconfig"
fi

echo ""
echo "========================================"
echo "Test Complete"
echo "========================================"

