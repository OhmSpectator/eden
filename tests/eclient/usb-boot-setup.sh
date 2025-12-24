#!/bin/bash

# USB Boot Priority Test Setup Script
# This script sets up the USB disk image required for USB boot priority testing.
# It downloads a Debian cloud image and configures Eden to attach it as a USB disk.
#
# This script should be called BEFORE eden setup/start, typically from workflow tests.
# Usage: ./usb-boot-setup.sh [CACHE_DIR]
#
# Environment variables:
#   EDEN_CONFIG - Eden config name (default: "default")
#   USB_BOOT_CACHE_DIR - Directory to cache downloaded images (default: /tmp/eden-usb-boot-cache)
#   EVE_TAG - EVE image tag to use (must have patched OVMF with fw_cfg boot order support)

set -e

EDEN_CONFIG="${EDEN_CONFIG:-default}"
CACHE_DIR="${1:-${USB_BOOT_CACHE_DIR:-/tmp/eden-usb-boot-cache}}"
DIR=$(dirname "$0")
# Add paths where eden binary might be located
EDEN_ROOT=$(cd "$DIR/../.." && pwd)
PATH="$EDEN_ROOT:$EDEN_ROOT/dist/bin:$PATH"

EDEN="${EDEN:-eden}"

# Ensure Eden config exists
CONFIG_FILE="$HOME/.eden/contexts/$EDEN_CONFIG.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating Eden config '$EDEN_CONFIG'..."
    $EDEN config add "$EDEN_CONFIG"
fi

# Configure EVE tag if specified (must have patched OVMF with fw_cfg support)
if [ -n "$EVE_TAG" ]; then
    echo "Setting EVE tag to: $EVE_TAG"
    $EDEN config set "$EDEN_CONFIG" --key eve.tag --value "$EVE_TAG"
fi

# Get Eden dist directory
dist=$($EDEN config get "$EDEN_CONFIG" --key eden.root)

USB_DISK_IMAGE="$dist/usb-boot.img"
CLOUD_IMAGE="$CACHE_DIR/debian-cloud.raw"

echo "=== USB Boot Priority Test Setup ==="
echo "Config: $EDEN_CONFIG"
echo "Cache dir: $CACHE_DIR"
echo "USB disk: $USB_DISK_IMAGE"

mkdir -p "$CACHE_DIR"
mkdir -p "$dist"

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
if [ ! -f "$USB_DISK_IMAGE" ]; then
    echo "Creating USB disk image from cloud image..."
    cp "$CLOUD_IMAGE" "$USB_DISK_IMAGE"
    echo "USB disk image created: $USB_DISK_IMAGE"
else
    echo "Using existing USB disk image: $USB_DISK_IMAGE"
fi

ls -lh "$USB_DISK_IMAGE"

# Update Eden config to include USB disk using eden config set
# This uses the proper Eden config API which preserves other settings
echo "Configuring USB disk in Eden config..."

# Check current USB disks setting
current_usb_disks=$($EDEN config get "$EDEN_CONFIG" --key eve.usb-disks 2>/dev/null || echo "")

if echo "$current_usb_disks" | grep -q "$USB_DISK_IMAGE"; then
    echo "USB disk already configured: $USB_DISK_IMAGE"
else
    # Set USB disks using eden config set with JSON array format
    echo "Adding USB disk to config using 'eden config set'..."
    $EDEN config set "$EDEN_CONFIG" --key eve.usb-disks --value "[\"$USB_DISK_IMAGE\"]"
    echo "USB disk configured: $USB_DISK_IMAGE"
fi

echo ""
echo "=== USB Boot Setup Complete ==="
echo "USB disk image: $USB_DISK_IMAGE"
echo ""
echo "Next steps:"
echo "  1. Configure port forwarding (if running manually, not via workflow):"
echo "     EDEN=./eden ./tests/eclient/eden+ports.sh 8027:8027 8028:8028 8029:8029 8030:8030 8031:8031"
echo "  2. Run: ./eden setup && ./eden start && ./eden eve onboard"
echo "  3. Run: ./eden test tests/eclient -v debug -e usb_boot_priority"
echo ""
echo "Note: If running via workflow (usb-boot.tests.txt), port forwarding is done automatically."

