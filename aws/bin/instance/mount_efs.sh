#!/bin/bash
set -euo pipefail

# Mount an EFS file system on this EC2 instance.
# Installs amazon-efs-utils if needed, creates mount point, and mounts EFS.
# Adds an fstab entry so the mount persists across reboots.
#
# Usage: ./mount_efs.sh <file-system-id>
#   Example: ./mount_efs.sh fs-0abc123def456

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <file-system-id>"
    exit 1
fi

FS_ID="$1"
MOUNT_POINT="/mnt/efs"

# Install EFS utils if not present
if ! command -v mount.efs &>/dev/null; then
    echo "Installing amazon-efs-utils..."
    sudo yum install -y amazon-efs-utils > /dev/null
fi

# Check if already mounted
if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "EFS already mounted at $MOUNT_POINT"
    exit 0
fi

# Create mount point and mount (retry until DNS resolves)
sudo mkdir -p "$MOUNT_POINT"
echo "Mounting $FS_ID at $MOUNT_POINT..."
MAX_ATTEMPTS=24
ATTEMPT=1
while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
    if sudo mount -t efs "$FS_ID":/ "$MOUNT_POINT" 2>/dev/null; then
        break
    fi
    echo "  Mount attempt $ATTEMPT/$MAX_ATTEMPTS failed (DNS may not be ready), retrying in 5s..."
    sleep 5
    ((ATTEMPT++))
done

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Error: Failed to mount $FS_ID after $MAX_ATTEMPTS attempts"
    exit 1
fi

# Add fstab entry for persistence across reboots
if ! grep -q "$FS_ID" /etc/fstab; then
    echo "$FS_ID:/ $MOUNT_POINT efs defaults,_netdev 0 0" | sudo tee -a /etc/fstab > /dev/null
fi

echo "EFS $FS_ID mounted at $MOUNT_POINT"
