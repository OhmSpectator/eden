#!/bin/bash
# Quick fix script to resolve Docker build issue and run test
# Run this tomorrow to continue where we left off

set -e

echo "=== USB Boot Priority Test - Continue Script ==="
echo ""

echo "Step 1: Copying eve-api to Docker build context..."
mkdir -p /home/nikolay/projects/eden/tests/eclient/image/eve-api-go
cp -r /home/nikolay/projects/eve-api/go/* /home/nikolay/projects/eden/tests/eclient/image/eve-api-go/
echo "✓ eve-api copied"
echo ""

echo "Step 2: Updating go.mod replace directive..."
cd /home/nikolay/projects/eden/tests/eclient/image/pkg
sed -i 's|replace github.com/lf-edge/eve-api/go => /home/nikolay/projects/eve-api/go|replace github.com/lf-edge/eve-api/go => ../eve-api-go|' go.mod
echo "✓ go.mod updated"
echo ""

echo "Step 3: Building eclient Docker image..."
cd /home/nikolay/projects/eden/tests/eclient
make build-docker
if [ $? -eq 0 ]; then
    echo "✓ Docker image built successfully"
else
    echo "✗ Docker build failed - check error above"
    exit 1
fi
echo ""

echo "Step 4: Cleaning up test environment..."
cd /home/nikolay/projects/eden
./cleanup-usb-test.sh
echo "✓ Environment cleaned"
echo ""

echo "Step 5: Running USB boot priority test..."
echo "This will take 10-15 minutes..."
./eden test tests/eclient -v debug -e usb_boot_priority 2>&1 | tee /tmp/usb-boot-test-continue.log
echo ""

if grep -q "PASS" /tmp/usb-boot-test-continue.log; then
    echo "✓✓✓ TEST PASSED! ✓✓✓"
    echo ""
    echo "Verifying hypervisor config..."
    ./eden eve ssh "ls -la /run/domainmgr/xen/"
    echo ""
    echo "Check for fw_cfg sections:"
    ./eden eve ssh "cat /run/domainmgr/xen/xen*.cfg 2>/dev/null | grep -A5 fw_cfg || echo 'No fw_cfg found (expected if USB boot disabled)'"
else
    echo "✗ Test failed or incomplete"
    echo "Check log: /tmp/usb-boot-test-continue.log"
    echo ""
    echo "Recent errors:"
    grep -i "error\|fail" /tmp/usb-boot-test-continue.log | tail -10
fi

echo ""
echo "=== Complete! ==="

