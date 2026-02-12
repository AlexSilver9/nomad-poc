#!/usr/bin/bash
set -euo pipefail

# Create an EFS file system for the Nomad cluster.
# Creates the file system and a mount target in eu-central-1a.
#
# Usage: ./create_efs.sh

command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

EFS_NAME="nomad-efs"
SUBNET_ID="subnet-3ee53954"
SECURITY_GROUP="sg-77476f14"

# Check if EFS with this name already exists
EXISTING=$(aws efs describe-file-systems \
    --query "FileSystems[?Name=='$EFS_NAME'].FileSystemId" \
    --output text)

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
    echo "EFS '$EFS_NAME' already exists: $EXISTING"
    exit 0
fi

echo "Creating EFS file system '$EFS_NAME'..."
RESULT=$(aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode elastic \
    --no-encrypted \
    --no-backup \
    --tags "Key=Name,Value=$EFS_NAME")

FS_ID=$(echo "$RESULT" | jq -r '.FileSystemId')
echo "Created file system: $FS_ID"

echo "Waiting for file system to become available..."
aws efs describe-file-systems --file-system-id "$FS_ID" \
    --query 'FileSystems[0].LifeCycleState' --output text

while true; do
    STATE=$(aws efs describe-file-systems --file-system-id "$FS_ID" \
        --query 'FileSystems[0].LifeCycleState' --output text)
    if [[ "$STATE" == "available" ]]; then
        break
    fi
    echo "  State: $STATE, waiting..."
    sleep 2
done
echo "File system is available"

# Disable lifecycle policies (no transitions to IA/Archive)
aws efs put-lifecycle-configuration \
    --file-system-id "$FS_ID" \
    --lifecycle-policies '[]' > /dev/null

echo "Creating mount target in $SUBNET_ID..."
aws efs create-mount-target \
    --file-system-id "$FS_ID" \
    --subnet-id "$SUBNET_ID" \
    --security-groups "$SECURITY_GROUP" > /dev/null

echo "Waiting for mount target to become available..."
while true; do
    MT_STATE=$(aws efs describe-mount-targets --file-system-id "$FS_ID" \
        --query 'MountTargets[0].LifeCycleState' --output text)
    if [[ "$MT_STATE" == "available" ]]; then
        break
    fi
    echo "  Mount target state: $MT_STATE, waiting..."
    sleep 5
done
echo "Mount target is available"

echo ""
echo "EFS file system created:"
echo "  Name:            $EFS_NAME"
echo "  File System ID:  $FS_ID"
echo "  Subnet:          $SUBNET_ID"
echo "  Security Group:  $SECURITY_GROUP"
echo ""
echo "Mount on EC2 instances with:"
echo "  sudo yum install -y amazon-efs-utils"
echo "  sudo mkdir -p /mnt/efs"
echo "  sudo mount -t efs $FS_ID:/ /mnt/efs"
echo ""
echo "Done"
