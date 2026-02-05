#!/usr/bin/bash
set -euo pipefail

# Demonstrates a Rolling Update.
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./rolling_update.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs"
JOB_FILE="rolling-update-service.hcl"
JOB_NAME="rolling-update-service"
OLD_IMAGE="traefik/whoami:v1.10.0"
NEW_IMAGE="traefik/whoami:v1.11.0"

# Step 1: Download job file from GitHub
echo "=== STEP 1: Download job file ==="
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
echo "Downloaded $JOB_FILE"

read -p "Press Enter to run the initial deployment..."

# Step 2: Run initial deployment
echo "=== STEP 2: Run initial deployment with $OLD_IMAGE ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify allocations (check Nomad UI: Jobs > $JOB_NAME)..."

# Step 3: Verify allocations
echo "=== STEP 3: Verify allocations are running ==="
nomad job status "$JOB_NAME"

read -p "Press Enter to update the image version..."

# Step 4: Update image version
echo "=== STEP 4: Update image version ==="
sed -i "s|image = \"$OLD_IMAGE\"|image = \"$NEW_IMAGE\"|g" "$JOB_FILE"
echo "Updated image from $OLD_IMAGE to $NEW_IMAGE"

read -p "Press Enter to plan the deployment..."

# Step 5: Plan deployment
echo "=== STEP 5: Plan deployment ==="
nomad job plan "$JOB_FILE" || true

read -p "Press Enter to run the rolling update (watch Nomad UI)..."

# Step 6: Run rolling update
echo "=== STEP 6: Run rolling update deployment ==="
nomad job run "$JOB_FILE"

read -p "Press Enter to verify the rolling update completed..."

# Step 7: Verify rolling update
echo "=== STEP 7: Verify allocations are running ==="
nomad job status "$JOB_NAME"

read -p "Press Enter to stop and purge the job..."

# Step 8: Stop and purge job
echo "=== STEP 8: Stop and purge job ==="
nomad job stop -purge "$JOB_NAME"

echo "Done"
