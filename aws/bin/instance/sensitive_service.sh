#!/bin/bash
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

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
JOB_FILE="services/sensitive-service/job.nomad.hcl"
JOB_NAME="sensitive-service"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p services/sensitive-service infrastructure/api-gateway/routes
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O services/sensitive-service/defaults.consul.hcl "$GITHUB_RAW_BASE/services/sensitive-service/defaults.consul.hcl"
wget -q -O services/sensitive-service/intentions.consul.hcl "$GITHUB_RAW_BASE/services/sensitive-service/intentions.consul.hcl"
wget -q -O infrastructure/api-gateway/routes/sensitive-service.consul.hcl "$GITHUB_RAW_BASE/infrastructure/api-gateway/routes/sensitive-service.consul.hcl"
echo "Downloaded job, Consul config, and route files"

read -p "Press Enter to apply Consul configurations and add api-gateway route..."

# Step 2: Apply Consul configurations and add api-gateway route
echo "=== STEP 2: Apply Consul configurations ==="
consul config write services/sensitive-service/defaults.consul.hcl
consul config write services/sensitive-service/intentions.consul.hcl
echo "Consul service-defaults and intentions applied"

echo "=== Adding sensitive-service route to api-gateway ==="
consul config write infrastructure/api-gateway/routes/sensitive-service.consul.hcl
echo "Route added (Envoy reloads automatically)"

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

echo "Removing sensitive-service route from api-gateway..."
consul config delete -kind http-route -name "$JOB_NAME" || true

echo "Done"
