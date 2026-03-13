#!/bin/bash
# Script to build, tag, and push eclient image to Docker Hub

set -e

echo "=== Building and Publishing eclient to Docker Hub ==="
echo ""

# Ensure user is logged in to Docker Hub
echo "Checking Docker Hub login status..."
DOCKER_USER=$(docker info 2>/dev/null | grep "Username:" | awk '{print $2}')

if [ -z "$DOCKER_USER" ]; then
    echo "Not logged in to Docker Hub. Please login:"
    docker login

    # Get username after login
    DOCKER_USER=$(docker info 2>/dev/null | grep "Username:" | awk '{print $2}')

    if [ -z "$DOCKER_USER" ]; then
        echo "ERROR: Failed to get Docker Hub username after login"
        exit 1
    fi
fi

echo "Logged in as: $DOCKER_USER"

cd /home/nikolay/projects/eden/tests/eclient

echo ""
echo "Step 1: Building eclient Docker image..."

# Build the image
make build-docker

# Find the most recently built lfedge/eden-eclient image
LOCAL_IMAGE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^lfedge/eden-eclient:" | head -1)

if [ -z "$LOCAL_IMAGE" ]; then
    echo "ERROR: Could not find built eden-eclient image"
    echo "Available images:"
    docker images | grep eclient
    exit 1
fi

echo "Found local image: $LOCAL_IMAGE"

# Extract version from the built image
IMAGE_VERSION=$(echo "$LOCAL_IMAGE" | cut -d':' -f2)
echo "Image version: $IMAGE_VERSION"

# Tag with Docker Hub username (use custom version or the detected version)
TARGET_VERSION="${TARGET_VERSION:-$IMAGE_VERSION}"
DOCKER_TAG="${DOCKER_USER}/eden-eclient:${TARGET_VERSION}"
echo ""
echo "Step 2: Tagging image as $DOCKER_TAG..."
docker tag "$LOCAL_IMAGE" "$DOCKER_TAG"

echo ""
echo "Step 3: Pushing to Docker Hub..."
docker push "$DOCKER_TAG"

echo ""
echo "Step 4: Updating test to use your Docker Hub image..."
cd /home/nikolay/projects/eden/tests/eclient/testdata

# Update the test file
sed -i "s|{{define \"eclient_image\"}}.*{{end}}|{{define \"eclient_image\"}}docker://${DOCKER_TAG}{{end}}|" usb_boot_priority.txt

echo ""
echo "✅ SUCCESS!"
echo ""
echo "Image pushed to: $DOCKER_TAG"
echo "Test updated to use: docker://$DOCKER_TAG"
echo ""
echo "You can verify the image on Docker Hub:"
echo "  https://hub.docker.com/r/${DOCKER_USER}/eden-eclient"
echo ""
echo "Now run the test:"
echo "  cd /home/nikolay/projects/eden"
echo "  ./cleanup-usb-test.sh"
echo "  ./eden test tests/eclient -v debug -e usb_boot_priority"
echo ""
echo "TIP: To use a custom version tag next time, run:"
echo "  TARGET_VERSION=1.0.15 ./publish-eclient.sh"
echo ""

