#!/usr/bin/bash
set -euo pipefail

# Demonstrates running a service on an isolated node pool via ALB.
#
# This script deploys sensitive-service to the sensitive-node-pool,
# configures ingress gateway routing, then cleans up.
#
# Requires: isolated nodes created via add_isolated_nodes.sh
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./sensitive_service.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs"
JOB_FILE="sensitive-service.hcl"
JOB_NAME="sensitive-service"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O sensitive-service-defaults.hcl "$GITHUB_RAW_BASE/sensitive-service-defaults.hcl"
wget -q -O sensitive-service-intentions.hcl "$GITHUB_RAW_BASE/sensitive-service-intentions.hcl"
wget -q -O ingress-gateway.hcl "$GITHUB_RAW_BASE/ingress-gateway.hcl"
wget -q -O ingress-gateway-with-sensitive-service.hcl "$GITHUB_RAW_BASE/ingress-gateway-with-sensitive-service.hcl"
echo "Downloaded job, Consul config, and ingress gateway files"

read -p "Press Enter to apply Consul configurations and update ingress gateway..."

# Step 2: Apply Consul configurations and update ingress gateway
echo "=== STEP 2: Apply Consul configurations ==="
consul config write sensitive-service-defaults.hcl
consul config write sensitive-service-intentions.hcl
echo "Consul service-defaults and intentions applied"

echo "=== Updating ingress gateway to include sensitive-service ==="
nomad job run ingress-gateway-with-sensitive-service.hcl
echo "Ingress gateway updated (waiting for Envoy to reload...)"
sleep 5

read -p "Press Enter to deploy sensitive-service to the isolated node pool..."

# Step 3: Deploy sensitive-service
echo "=== STEP 3: Deploy sensitive-service to node pool 'sensitive-node-pool' ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify the allocation landed on the correct node pool..."

# Step 4: Verify allocation and node pool
echo "=== STEP 4: Verify allocation ==="
nomad job status "$JOB_NAME"

echo ""
echo "=============================================="
echo "Verify the allocation is on the sensitive node pool:"
echo ""
ALLOC_ID=$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' "$JOB_NAME" 2>/dev/null || echo "")
if [[ -n "$ALLOC_ID" ]]; then
    NODE_ID=$(nomad alloc status -t '{{.NodeID}}' "$ALLOC_ID" 2>/dev/null || echo "")
    if [[ -n "$NODE_ID" ]]; then
        echo "  Alloc:     $ALLOC_ID"
        echo "  Node:      $NODE_ID"
        echo "  Node Pool: $(nomad node status -t '{{.NodePool}}' "$NODE_ID" 2>/dev/null || echo "unknown")"
    fi
fi
echo ""
echo "To test via ALB:"
echo "  curl -sH 'Host: sensitive-service' http://<ALB_DNS>/"
echo ""
echo "To watch traffic:"
echo "  while true; do curl -sH 'Host: sensitive-service' http://<ALB_DNS>/ | grep -E '(Hostname|Name)'; sleep 0.5; done"
echo "=============================================="

read -p "Press Enter to stop and purge the job..."

# Step 5: Stop and purge job
echo "=== STEP 5: Stop and purge job ==="
nomad job stop -purge "$JOB_NAME"

# Step 6: Cleanup
echo "=== STEP 6: Cleanup ==="

echo "Removing Consul config entries..."
consul config delete -kind service-intentions -name "$JOB_NAME" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true

echo "Restoring original ingress gateway..."
nomad job run ingress-gateway.hcl

echo "Done"
