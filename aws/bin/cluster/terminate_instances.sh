#!/bin/bash
set -euo pipefail

# Terminate ALL EC2 instances in the account. Use with caution!
# Requires: aws-cli, jq
# Usage: ./aws_terminate_instances.sh

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

for instance in $(aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name != "terminated") | .InstanceId'); do
    echo "Terminating instance id $instance..."
    aws ec2 terminate-instances --instance-ids $instance
done

echo "Done"
