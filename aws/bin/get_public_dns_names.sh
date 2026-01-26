#!/usr/bin/bash

# Output PublicDnsName of all running EC2 instances, one per line.
# Requires: aws-cli, jq
# Usage: ./get_public_dns_names.sh

aws ec2 describe-instances | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName'
