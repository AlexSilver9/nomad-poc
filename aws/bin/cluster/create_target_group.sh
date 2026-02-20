#!/bin/bash
set -euo pipefail

# Create an EC2 target group for the Nomad ingress gateway.
# Registers all running EC2 instances as targets on port 443.
# Requires: aws-cli, jq
# Usage: ./create_target_group.sh [target-group-name]

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

# Configuration
TARGET_GROUP_NAME="${1:-nomad-target-group}"
TARGET_PORT=8081
VPC_ID="vpc-ec926686"

echo "Creating target group: ${TARGET_GROUP_NAME}"

# Create target group
result=$(aws elbv2 create-target-group \
    --name "${TARGET_GROUP_NAME}" \
    --protocol HTTP \
    --port ${TARGET_PORT} \
    --vpc-id "${VPC_ID}" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path "/" \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3)

TARGET_GROUP_ARN=$(echo "$result" | jq -r '.TargetGroups[0].TargetGroupArn')
echo "Created target group: ${TARGET_GROUP_ARN}"

# Get all running instance IDs
echo "Registering running instances..."
instance_ids=$(aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .InstanceId')

if [[ -z "$instance_ids" ]]; then
    echo "No running instances found to register"
else
    # Build targets array
    targets=""
    for id in $instance_ids; do
        targets+="Id=${id},Port=${TARGET_PORT} "
        echo "  Registering: ${id}:${TARGET_PORT}"
    done

    # Register targets
    aws elbv2 register-targets \
        --target-group-arn "${TARGET_GROUP_ARN}" \
        --targets $targets

    echo "Registered $(echo "$instance_ids" | wc -w) instances"
fi

echo ""
echo "Done"
echo "Target Group ARN: ${TARGET_GROUP_ARN}"
echo "Target Group Name: ${TARGET_GROUP_NAME}"
echo ""
echo "Check target health: aws elbv2 describe-target-health --target-group-arn ${TARGET_GROUP_ARN}"
