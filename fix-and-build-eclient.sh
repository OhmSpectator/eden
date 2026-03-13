#!/bin/bash
# Fix and build eclient image with local eve-api

set -e

echo "=== Fixing eclient build with local eve-api ==="

# Step 1: Copy eve-api to build context
echo "Step 1: Copying eve-api/go to build context..."
cd /home/nikolay/projects/eden/tests/eclient/image
rm -rf eve-api-go
cp -r /home/nikolay/projects/eve-api/go eve-api-go
echo "✓ Copied $(find eve-api-go -name '*.pb.go' | wc -l) protobuf files"

# Step 2: Clean Go module cache
echo "Step 2: Cleaning Go module cache..."
cd pkg
go clean -modcache
echo "✓ Module cache cleaned"

# Step 3: Build Docker image
echo "Step 3: Building eclient Docker image..."
cd /home/nikolay/projects/eden/tests/eclient
make build-docker

if [ $? -eq 0 ]; then
    echo "✓✓✓ Docker image built successfully!"
else
    echo "✗ Docker build failed"
    exit 1
fi

echo "=== Build complete! Ready to run test ==="

