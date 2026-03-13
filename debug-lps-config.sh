#!/bin/bash
# Debug script to check EVE's LPS configuration

cd /home/nikolay/projects/eden

echo "=== Checking EVE Device Configuration ==="
./eden controller edge-node get-config | grep -i "profile\|local_profile" | head -20

echo ""
echo "=== Checking local-manager IP ==="
./eden pod ps | grep local-manager

echo ""
echo "=== Checking if EVE can see LPS address ==="
./eden eve ssh "grep -i 'lps\|vmconfig\|local.*profile' /persist/status/zedagent/*.log 2>/dev/null | tail -20" || echo "No logs found"

echo ""
echo "=== Checking pillar logs for vmconfig ==="
./eden eve ssh "grep -i 'vmconfig\|getVmConfig' /persist/newlog/devUpload/*.gz 2>/dev/null | zcat | tail -30" || echo "No logs found"

echo ""
echo "Done!"

