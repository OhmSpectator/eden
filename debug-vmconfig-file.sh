#!/bin/bash
# Debug script to check vm-config file state

cd /home/nikolay/projects/eden

echo "=== Checking vm-config file on local-manager ==="
./eden sdn fwd eth0 2223 -- ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=no -i dist/tests/eclient/image/cert/id_rsa root@FWD_IP -p FWD_PORT "
echo '--- File exists:'
ls -la /mnt/vm-config 2>/dev/null || echo 'NOT FOUND'
echo ''
echo '--- File contents:'
cat /mnt/vm-config 2>/dev/null || echo 'EMPTY'
echo ''
echo '--- Modification time:'
stat -c '%y' /mnt/vm-config 2>/dev/null || echo 'N/A'
echo ''
echo '--- Current time:'
date
"

echo ""
echo "Done!"

