#!/bin/bash
# Extract USB boot priority related logs from EVE using SSH + logread

cd /home/nikolay/projects/eden

echo "=== Extracting USB Boot Priority Debug Logs ==="
echo ""

# Use SSH + logread since eden log is broken
./eden eve ssh "logread | grep -iE 'vmconfig|VmConfigList|USBBoot|usb_boot|updateAppInstanceUsbBoot|handleVmConfig' | tail -100"

echo ""
echo "=== End of Logs ==="

