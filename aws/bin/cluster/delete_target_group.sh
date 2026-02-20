#!/bin/bash
set -euo pipefail

# Delete a specific target group or all target groups.
# Requires: aws-cli, jq
# Usage: ./delete_target_group.sh [target-group-name]
#        ./delete_target_group.sh --all

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

# Function to delete target group
delete_target_group() {
    local arn="$1"
    local name="$2"
    echo "Deleting target group: ${name} (${arn})"
    aws elbv2 delete-target-group --target-group-arn "${arn}"
    echo "  Deleted: ${name}"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <target-group-name>"
    echo "       $0 --all"
    echo ""
    echo "Available target groups:"
    aws elbv2 describe-target-groups \
        | jq -r '.TargetGroups[] | "  \(.TargetGroupName) - \(.TargetGroupArn)"'
    exit 1
fi

if [[ "$1" == "--all" ]]; then
    echo "Deleting ALL target groups..."
    target_groups=$(aws elbv2 describe-target-groups \
        | jq -r '.TargetGroups[] | "\(.TargetGroupArn)|\(.TargetGroupName)"')

    if [[ -z "$target_groups" ]]; then
        echo "No target groups found"
        exit 0
    fi

    for tg in $target_groups; do
        arn=$(echo "$tg" | cut -d'|' -f1)
        name=$(echo "$tg" | cut -d'|' -f2)
        delete_target_group "$arn" "$name"
    done
else
    TARGET_GROUP_NAME="$1"
    echo "Looking up target group: ${TARGET_GROUP_NAME}"

    result=$(aws elbv2 describe-target-groups --names "${TARGET_GROUP_NAME}" 2>/dev/null || true)

    if [[ -z "$result" ]] || [[ "$(echo "$result" | jq '.TargetGroups | length')" == "0" ]]; then
        echo "Error: Target group '${TARGET_GROUP_NAME}' not found"
        exit 1
    fi

    arn=$(echo "$result" | jq -r '.TargetGroups[0].TargetGroupArn')
    delete_target_group "$arn" "$TARGET_GROUP_NAME"
fi

echo ""
echo "Done"
