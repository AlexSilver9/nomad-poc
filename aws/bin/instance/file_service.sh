#!/bin/bash
set -euo pipefail

# Deploys the file-service (nginx serving static files from EFS).
#
# The file-service uses Consul Connect with an api-gateway
# to serve files from the EFS-backed host volume.
#
# Requires: EFS mounted on host, api-gateway running.
#
# Usage: ./file_service.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
JOB_FILE="services/file-service/job.nomad.hcl"
JOB_NAME="file-service"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p services/file-service infrastructure/api-gateway/routes
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O services/file-service/defaults.consul.hcl "$GITHUB_RAW_BASE/services/file-service/defaults.consul.hcl"
wget -q -O services/file-service/intentions.consul.hcl "$GITHUB_RAW_BASE/services/file-service/intentions.consul.hcl"
wget -q -O infrastructure/api-gateway/routes/file-service.consul.hcl "$GITHUB_RAW_BASE/infrastructure/api-gateway/routes/file-service.consul.hcl"
echo "Downloaded job, Consul config, and route files"

read -p "Press Enter to apply Consul configurations and add api-gateway route..."

# Step 2: Apply Consul configurations and add api-gateway route
echo "=== STEP 2: Apply Consul configurations ==="
consul config write services/file-service/defaults.consul.hcl
consul config write services/file-service/intentions.consul.hcl
echo "Consul service-defaults and intentions applied"

echo "=== Adding file-service route to api-gateway ==="
consul config write infrastructure/api-gateway/routes/file-service.consul.hcl
echo "Route added (Envoy reloads automatically)"

read -p "Press Enter to deploy file-service..."

# Step 3: Deploy file-service
echo "=== STEP 3: Deploy file-service ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify allocations (check Nomad UI: Jobs > $JOB_NAME)..."

# Step 4: Verify allocations
echo "=== STEP 4: Verify allocations are running ==="
nomad job status "$JOB_NAME"

echo ""
echo "=============================================="
echo "File-service is running. Test with:"
echo ""
echo "  curl -H 'Host: file-service' http://<ALB_DNS>/"
echo ""
echo "To upload files to EFS, write to /mnt/efs on any node."
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

echo "Removing file-service route from api-gateway..."
consul config delete -kind http-route -name "$JOB_NAME" || true

echo "Done"
