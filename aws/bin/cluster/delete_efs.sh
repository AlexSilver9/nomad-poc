#!/usr/bin/bash
set -euo pipefail

# Delete a specific EFS file system or all EFS file systems.
# Also deletes associated mount targets.
# Requires: aws-cli, jq
# Usage: ./delete_efs.sh [efs-name]
#        ./delete_efs.sh --all

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

# Function to delete an EFS file system
delete_efs() {
    local fs_id="$1"
    local name="$2"

    echo "Deleting EFS: ${name} (${fs_id})"

    # Delete mount targets first
    mount_targets=$(aws efs describe-mount-targets --file-system-id "${fs_id}" \
        | jq -r '.MountTargets[].MountTargetId')

    for mt_id in $mount_targets; do
        if [[ -n "$mt_id" ]]; then
            echo "  Deleting mount target: ${mt_id}"
            aws efs delete-mount-target --mount-target-id "${mt_id}"
        fi
    done

    # Wait for mount targets to be deleted
    if [[ -n "$mount_targets" ]]; then
        echo "  Waiting for mount targets to be deleted..."
        while true; do
            remaining=$(aws efs describe-mount-targets --file-system-id "${fs_id}" \
                | jq '.MountTargets | length')
            if [[ "$remaining" == "0" ]]; then
                break
            fi
            sleep 2
        done
    fi

    # Delete the file system
    aws efs delete-file-system --file-system-id "${fs_id}"
    echo "  Deleted: ${name}"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <efs-name>"
    echo "       $0 --all"
    echo ""
    echo "Available file systems:"
    aws efs describe-file-systems \
        | jq -r '.FileSystems[] | "  \(.Name // "(unnamed)") - \(.FileSystemId)"'
    exit 1
fi

if [[ "$1" == "--all" ]]; then
    echo "Deleting ALL EFS file systems..."
    file_systems=$(aws efs describe-file-systems \
        | jq -r '.FileSystems[] | "\(.FileSystemId)|\(.Name // "(unnamed)")"')

    if [[ -z "$file_systems" ]]; then
        echo "No EFS file systems found"
        exit 0
    fi

    for fs in $file_systems; do
        fs_id=$(echo "$fs" | cut -d'|' -f1)
        name=$(echo "$fs" | cut -d'|' -f2)
        delete_efs "$fs_id" "$name"
    done
else
    EFS_NAME="$1"
    echo "Looking up EFS: ${EFS_NAME}"

    fs_id=$(aws efs describe-file-systems \
        --query "FileSystems[?Name=='${EFS_NAME}'].FileSystemId" \
        --output text)

    if [[ -z "$fs_id" || "$fs_id" == "None" ]]; then
        echo "Error: EFS '${EFS_NAME}' not found"
        exit 1
    fi

    delete_efs "$fs_id" "$EFS_NAME"
fi

echo ""
echo "Done"
