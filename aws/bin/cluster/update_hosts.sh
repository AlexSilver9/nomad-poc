#!/bin/bash
set -euo pipefail

# Update /etc/hosts with the current ALB IP for all cluster hostnames.
# Run this after each cluster setup or ALB recreation.
#
# Discovers the ALB DNS name from AWS and resolves it to an IP.
# Replaces any existing cluster entries in /etc/hosts (idempotent).
#
# Requires: aws-cli, dig
# Usage: ./update_hosts.sh

HOSTS_FILE="/etc/hosts"
MARKER="# nomad-poc cluster"

HOSTNAMES=(
    "web-service.example.com"
    "business-service.example.com"
    "file-service.example.com"
    "rolling-update-service.example.com"
    "canary-update-service.example.com"
    "sensitive-service.example.com"
    "grafana.example.com"
    "prometheus.example.com"
)

command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v dig &>/dev/null || { echo "Error: dig required"; exit 1; }

echo "Fetching ALB DNS name from AWS..."
ALB_DNS=$(aws elbv2 describe-load-balancers \
    | jq -r '.LoadBalancers[] | select(.State.Code == "active") | .DNSName' \
    | head -1)

[[ -n "$ALB_DNS" ]] || { echo "Error: no active ALB found"; exit 1; }
echo "ALB: $ALB_DNS"

echo "Resolving to IP..."
ALB_IP=$(dig +short "$ALB_DNS" | grep -E '^[0-9]+\.' | head -1)
[[ -n "$ALB_IP" ]] || { echo "Error: could not resolve $ALB_DNS"; exit 1; }
echo "IP:  $ALB_IP"

# Build the new entries block
NEW_ENTRIES="$MARKER"$'\n'
for host in "${HOSTNAMES[@]}"; do
    NEW_ENTRIES+="$ALB_IP $host"$'\n'
done
NEW_ENTRIES+="$MARKER end"

# Remove existing cluster entries from /etc/hosts and append new ones
TMPFILE=$(mktemp)
sed "/^${MARKER}/,/^${MARKER} end/d" "$HOSTS_FILE" > "$TMPFILE"
echo "" >> "$TMPFILE"
echo "$NEW_ENTRIES" >> "$TMPFILE"

echo "Updating $HOSTS_FILE (requires sudo)..."
sudo cp "$TMPFILE" "$HOSTS_FILE"
rm "$TMPFILE"

echo ""
echo "Updated /etc/hosts:"
grep -A $((${#HOSTNAMES[@]} + 1)) "^$MARKER" "$HOSTS_FILE"
