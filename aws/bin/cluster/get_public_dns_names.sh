#!/bin/bash
set -euo pipefail

# Output PublicDnsName of all running EC2 instances, one per line.
# Requires: aws-cli, jq
# Usage: ./get_public_dns_names.sh

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName'
