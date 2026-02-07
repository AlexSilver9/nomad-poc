#!/usr/bin/bash
set -euo pipefail

# Demonstrates a Isolated Canary Deployment with traffic routing via ALB.
#
# Canary deployments run new versions ALONGSIDE existing versions,
# allowing to test before promoting. Unlike rolling updates,
# old allocations keep running until promoted manually.
#
# This script updates the ingress gateway to include canary-update-service,
# runs the demo, then restores the original ingress gateway config.
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./canary_update.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs"
JOB_FILE="canary-update-service.hcl"
JOB_NAME="canary-update-service"
OLD_IMAGE="traefik/whoami:v1.10.0"
NEW_IMAGE="traefik/whoami:v1.11.0"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
wget -q -O "$JOB_FILE" "$GITHUB_RAW_BASE/$JOB_FILE"
wget -q -O canary-update-service-defaults.hcl "$GITHUB_RAW_BASE/canary-update-service-defaults.hcl"
wget -q -O canary-update-service-intentions.hcl "$GITHUB_RAW_BASE/canary-update-service-intentions.hcl"
wget -q -O canary-update-service-resolver.hcl "$GITHUB_RAW_BASE/canary-update-service-resolver.hcl"
wget -q -O ingress-gateway.hcl "$GITHUB_RAW_BASE/ingress-gateway.hcl"
wget -q -O ingress-gateway-with-canary-update.hcl "$GITHUB_RAW_BASE/ingress-gateway-with-canary-update.hcl"
echo "Downloaded job, Consul config, and ingress gateway files"

read -p "Press Enter to apply Consul configurations and update ingress gateway..."

# Step 2: Apply Consul configurations and update ingress gateway
echo "=== STEP 2: Apply Consul configurations ==="
consul config write canary-update-service-defaults.hcl
consul config write canary-update-service-intentions.hcl
consul config write canary-update-service-resolver.hcl
echo "Consul service-defaults, intentions, and resolver applied"

echo "=== Updating ingress gateway to include canary-update-service ==="
nomad job run ingress-gateway-with-canary-update.hcl
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
echo "To watch traffic routing during canary deployment, run in another terminal:"
echo ""
echo "  while true; do curl -sH 'Host: canary-update-service' http://<ALB_DNS>/ | grep -E '(Hostname|Name)'; sleep 0.5; done"
echo ""
echo "Currently all traffic goes to stable allocations only."
echo "=============================================="

read -p "Press Enter to update the image version (create canary)..."

# Step 5: Update image version
echo "=== STEP 5: Update image version ==="
sed -i "s|image = \"$OLD_IMAGE\"|image = \"$NEW_IMAGE\"|g" "$JOB_FILE"
echo "Updated image from $OLD_IMAGE to $NEW_IMAGE"

read -p "Press Enter to plan the deployment..."

# Step 6: Plan deployment
echo "=== STEP 6: Plan deployment ==="
nomad job plan "$JOB_FILE" || true

read -p "Press Enter to deploy the canary (watch Nomad UI)..."

# Step 7: Deploy canary
echo "=== STEP 7: Deploy canary allocation ==="
nomad job run "$JOB_FILE"
echo ""
echo "Canary deployed! Note:"
echo "  - 1 canary allocation with NEW version is now running"
echo "  - 2 existing allocations with OLD version are STILL running"
echo "  - Traffic goes ONLY to stable allocations until resolver is removed"
echo ""

read -p "Press Enter to see deployment status..."

# Step 8: Show deployment status
echo "=== STEP 8: Deployment status (awaiting promotion) ==="
nomad job status "$JOB_NAME"
echo ""
DEPLOYMENT_ID=$(nomad job status "$JOB_NAME" | grep -A1 "Latest Deployment" | tail -1 | awk '{print $1}')
echo "Deployment ID: $DEPLOYMENT_ID"
echo ""
nomad deployment status "$DEPLOYMENT_ID"

echo ""
echo "=============================================="
echo "The canary is running but receives NO traffic (resolver filter active)."
echo "Test the canary directly via its allocation IP address."
echo "Find canary allocation IP via:"
echo "  nomad alloc status <canary-alloc-id> | grep -A5 'Allocation Addresses'"
echo ""
echo "Options:"
echo "  - Promote: nomad deployment promote $DEPLOYMENT_ID"
echo "  - Fail:    nomad deployment fail $DEPLOYMENT_ID"
echo "=============================================="

read -p "Press Enter to remove the resolver filter to ENABLE traffic to canary ..."

# Step 9: Remove resolver to enable canary traffic
echo "=== STEP 9: Remove resolver filter (enable canary traffic) ==="
consul config delete -kind service-resolver -name "$JOB_NAME"
echo "Resolver removed - canary now receives traffic alongside stable allocations"
echo ""
echo "Watch the traffic in another terminal - you should now see"
echo "requests hitting both old and new (canary) allocations."

read -p "Press Enter to PROMOTE the canary deployment..."

# Step 10: Promote canary
echo "=== STEP 10: Promote canary deployment ==="
nomad deployment promote "$DEPLOYMENT_ID"
echo "Canary promoted! Old allocations will now be replaced with new version."

read -p "Press Enter to verify promotion completed..."

# Step 11: Verify promotion
echo "=== STEP 11: Verify all allocations are running new version ==="
nomad job status "$JOB_NAME"

read -p "Press Enter to stop and purge the job..."

# Step 12: Stop and purge job
echo "=== STEP 12: Stop and purge job ==="
nomad job stop -purge "$JOB_NAME"

# Step 13: Cleanup
echo "=== STEP 13: Cleanup ==="

echo "Removing Consul config entries..."
consul config delete -kind service-resolver -name "$JOB_NAME" || true
consul config delete -kind service-intentions -name "$JOB_NAME" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true

echo "Restoring original ingress gateway..."
nomad job run ingress-gateway.hcl

echo "Done"
