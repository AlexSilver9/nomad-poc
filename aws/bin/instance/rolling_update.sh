#!/bin/bash
set -euo pipefail

# Demonstrates a Rolling Update with traffic routing via ALB.
#
# This script updates the ingress gateway to include rolling-update-service,
# runs the demo, then restores the original ingress gateway config.
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./rolling_update.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws"
JOB_FILE="services/rolling-update-service/job.nomad.hcl"
JOB_NAME="rolling-update-service"
OLD_IMAGE="traefik/whoami:v1.10.0"
NEW_IMAGE="traefik/whoami:v1.11.0"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p services/rolling-update-service infrastructure/ingress-gateway
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O services/rolling-update-service/defaults.consul.hcl "$GITHUB_RAW_BASE/services/rolling-update-service/defaults.consul.hcl"
wget -q -O services/rolling-update-service/intentions.consul.hcl "$GITHUB_RAW_BASE/services/rolling-update-service/intentions.consul.hcl"
wget -q -O infrastructure/ingress-gateway/job.nomad.hcl "$GITHUB_RAW_BASE/infrastructure/ingress-gateway/job.nomad.hcl"
wget -q -O infrastructure/ingress-gateway/with-rolling-update.nomad.hcl "$GITHUB_RAW_BASE/infrastructure/ingress-gateway/with-rolling-update.nomad.hcl"
echo "Downloaded job, Consul config, and ingress gateway files"

read -p "Press Enter to apply Consul configurations and update ingress gateway..."

# Step 2: Apply Consul configurations and update ingress gateway
echo "=== STEP 2: Apply Consul configurations ==="
consul config write services/rolling-update-service/defaults.consul.hcl
consul config write services/rolling-update-service/intentions.consul.hcl
echo "Consul service-defaults and intentions applied"

echo "=== Updating ingress gateway to include rolling-update-service ==="
nomad job run infrastructure/ingress-gateway/with-rolling-update.nomad.hcl
echo "Ingress gateway updated (waiting for Envoy to reload...)"
sleep 5

read -p "Press Enter to run the initial deployment..."

# Step 3: Run initial deployment
echo "=== STEP 3: Run initial deployment with $OLD_IMAGE ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify allocations (check Nomad UI: Jobs > $JOB_NAME)..."

# Step 4: Verify allocations
echo "=== STEP 4: Verify allocations are running ==="
nomad job status "$JOB_NAME"

echo ""
echo "=============================================="
echo "To watch traffic routing during rolling update, run in another terminal:"
echo ""
echo "  while true; do curl -sH 'Host: rolling-update-service' http://<ALB_DNS>/ | grep -E '(Hostname|Name)'; sleep 0.5; done"
echo ""
echo "=============================================="

read -p "Press Enter to update the image version..."

# Step 5: Update image version
echo "=== STEP 5: Update image version ==="
sed -i "s|image = \"$OLD_IMAGE\"|image = \"$NEW_IMAGE\"|g" "$JOB_FILE"
echo "Updated image from $OLD_IMAGE to $NEW_IMAGE"

read -p "Press Enter to plan the deployment..."

# Step 6: Plan deployment
echo "=== STEP 6: Plan deployment ==="
nomad job plan "$JOB_FILE" || true

read -p "Press Enter to run the rolling update (watch Nomad UI)..."

# Step 7: Run rolling update
echo "=== STEP 7: Run rolling update deployment ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify the rolling update completed..."

# Step 8: Verify rolling update
echo "=== STEP 8: Verify allocations are running ==="
nomad job status "$JOB_NAME"

read -p "Press Enter to stop and purge the job..."

# Step 9: Stop and purge job
echo "=== STEP 9: Stop and purge job ==="
nomad job stop -purge "$JOB_NAME"

# Step 10: Cleanup
echo "=== STEP 10: Cleanup ==="

echo "Removing Consul config entries..."
consul config delete -kind service-intentions -name "$JOB_NAME" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true

echo "Restoring original ingress gateway..."
nomad job run infrastructure/ingress-gateway/job.nomad.hcl

echo "Done"
