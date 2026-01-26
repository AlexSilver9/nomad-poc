#!/bin/bash

# Terminate ALL EC2 instances in the account. Use with caution!
# Requires: aws-cli, jq
# Usage: ./aws_terminate_instances.sh

for instance in $(aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name != "terminated") | .InstanceId'); do
    echo "Terminating instance id $instance..."
    aws ec2 terminate-instances --instance-ids $instance
done

echo "Done"
