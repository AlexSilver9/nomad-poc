#!/usr/bin/bash
set -euo pipefail

# List all EC2 instances with their IPs and network info.
# Requires: aws-cli, jq
# Usage: ./aws_describe_instances.sh

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name != "terminated") |
    "InstanceId:       \(.InstanceId)",
    "  Name:             \((.Tags // [] | map(select(.Key == "Name")) | first // {}).Value // "N/A")",
    "  State:            \(.State.Name)",
    "  PublicDnsName:    \(.PublicDnsName // "N/A")",
    "  PublicIpAddress:  \(.PublicIpAddress // "N/A")",
    "  PrivateDnsName:   \(.PrivateDnsName // "N/A")",
    "  PrivateIpAddress: \(.PrivateIpAddress // "N/A")",
    "  VpcId:            \(.VpcId // "N/A")",
    ""
  '
