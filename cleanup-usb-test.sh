#!/bin/bash
# Cleanup script for USB boot priority test

echo "Cleaning up test environment..."

# Stop any running test
pkill -f "eden.network.test" || true
pkill -f "eden.reboot.test" || true

# Delete test VMs
./eden pod delete test-usb-boot-vm 2>/dev/null || true
./eden pod delete test-vm-2 2>/dev/null || true
./eden pod delete local-manager 2>/dev/null || true

# Delete network
./eden network delete n1 2>/dev/null || true

# Wait for cleanup
sleep 10

# Check status
echo "Current status:"
./eden pod ps
./eden network ls

echo ""
echo "Ready to run test again!"
echo "Run: ./eden test tests/eclient -v debug -e usb_boot_priority"

