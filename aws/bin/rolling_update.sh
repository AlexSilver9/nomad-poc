#!/usr/bin/bash
set -euo pipefail

# Demonstrates a Rolling Update with traffic routing via ALB.
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./rolling_update.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs"
JOB_FILE="rolling-update-service.hcl"
JOB_NAME="rolling-update-service"
OLD_IMAGE="traefik/whoami:v1.10.0"
NEW_IMAGE="traefik/whoami:v1.11.0"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O rolling-update-service-defaults.hcl "$GITHUB_RAW_BASE/rolling-update-service-defaults.hcl"
wget -q -O rolling-update-service-intentions.hcl "$GITHUB_RAW_BASE/rolling-update-service-intentions.hcl"
echo "Downloaded job and Consul config files"

read -p "Press Enter to apply Consul configurations..."

# Step 2: Apply Consul configurations
echo "=== STEP 2: Apply Consul configurations ==="
consul config write rolling-update-service-defaults.hcl
consul config write rolling-update-service-intentions.hcl
echo "Consul service-defaults and intentions applied"

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

# Cleanup Consul config entries
echo "=== Cleanup: Remove Consul config entries ==="
consul config delete -kind service-intentions -name "$JOB_NAME" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true

echo "Done"
