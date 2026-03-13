#!/bin/bash
set -euo pipefail

# Demonstrates end-to-end HTTPS routing by hostname without an ALB.
#
# This script:
#   1. Applies Consul service-defaults (TCP protocol) and intentions for https-service
#   2. Adds the TCPRoute to the api-gateway (TCP listener on port 8082 is always present)
#   3. Switches nginx-rewrite to the HTTPS variant (port 8443, self-signed cert)
#   4. Deploys https-service (nginx serving HTTPS with a self-signed cert)
#
# After this script completes, test routing directly on any node:
#
#   curl -vk -H 'Host: https-service.example.com' https://<node-ip>:8443/
#   curl -vk -H 'Host: web-service.example.com'   https://<node-ip>:8443/
#
# Traffic flow:
#   client → nginx:8443 (TLS termination) → envoy_http:8080 (plain HTTP services)
#                                          → envoy_tcp:8082  (https-service, TLS passthrough)
#
# To restore the plain HTTP setup:
#   nomad job stop -purge https-service
#   consul config delete -kind tcp-route         -name https-service
#   consul config delete -kind service-intentions -name https-service
#   consul config delete -kind service-defaults   -name https-service
#   nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
#
# Usage: ./https_service.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p services/https-service infrastructure/api-gateway/routes infrastructure/nginx-rewrite
wget -q -O services/https-service/job.nomad.hcl              "$GITHUB_RAW_BASE/services/https-service/job.nomad.hcl"
wget -q -O services/https-service/defaults.consul.hcl        "$GITHUB_RAW_BASE/services/https-service/defaults.consul.hcl"
wget -q -O services/https-service/intentions.consul.hcl      "$GITHUB_RAW_BASE/services/https-service/intentions.consul.hcl"
wget -q -O infrastructure/api-gateway/routes/https-service.consul.hcl \
    "$GITHUB_RAW_BASE/infrastructure/api-gateway/routes/https-service.consul.hcl"
wget -q -O infrastructure/nginx-rewrite/with-https-termination.nomad.hcl \
    "$GITHUB_RAW_BASE/infrastructure/nginx-rewrite/with-https-termination.nomad.hcl"
echo "Downloaded all required files"

read -p "Press Enter to apply Consul configurations..."

# Step 2: Apply Consul configurations
echo "=== STEP 2: Apply Consul configurations ==="
consul config write services/https-service/defaults.consul.hcl
consul config write services/https-service/intentions.consul.hcl
echo "Consul service-defaults (TCP) and intentions applied"

read -p "Press Enter to add https-service TCPRoute to api-gateway..."

# Step 3: Add TCPRoute to api-gateway
# Note: the TCP listener on port 8082 is always present in the api-gateway config.
# Adding the route activates routing to https-service on that listener.
echo "=== STEP 3: Add https-service TCPRoute ==="
consul config write infrastructure/api-gateway/routes/https-service.consul.hcl
echo "TCPRoute added (Envoy reloads automatically)"

read -p "Press Enter to stop traefik-rewrite and switch nginx to HTTPS (port 8443)..."

# Step 4: Stop traefik (conflicts on port 8081/8443), then deploy nginx HTTPS
echo "=== STEP 4: Stop traefik-rewrite ==="
nomad job stop traefik-rewrite 2>/dev/null && echo "traefik-rewrite stopped" || echo "traefik-rewrite not running, skipping"

echo "=== STEP 4b: Deploy nginx with HTTPS termination ==="
nomad job run infrastructure/nginx-rewrite/with-https-termination.nomad.hcl
echo "nginx-rewrite updated (waiting for cert generation and reload...)"
sleep 5

read -p "Press Enter to deploy https-service..."

# Step 5: Deploy https-service
echo "=== STEP 5: Deploy https-service ==="
nomad job run services/https-service/job.nomad.hcl
echo "https-service deployed"

read -p "Press Enter to verify all jobs are running..."

# Step 6: Verify
echo "=== STEP 6: Verify all jobs ==="
nomad status

echo ""
echo "=============================================="
echo "HTTPS routing by hostname is ready."
echo ""
echo "Get a node IP:"
echo "  nomad node status"
echo ""
echo "Test https-service (TCP passthrough via Envoy port 8082):"
echo "  curl -vk -H 'Host: https-service.example.com' https://<node-ip>:8443/"
echo ""
echo "Test plain HTTP services (via Envoy HTTP listener port 8080):"
echo "  curl -vk -H 'Host: web-service.example.com'      https://<node-ip>:8443/"
echo "  curl -vk -H 'Host: business-service.example.com' https://<node-ip>:8443/"
echo "  curl -vk -H 'Host: business-service.example.com' https://<node-ip>:8443/download/mytoken123"
echo ""
echo "To restore the plain HTTP setup:"
echo "  nomad job stop -purge https-service"
echo "  consul config delete -kind tcp-route          -name https-service"
echo "  consul config delete -kind service-intentions -name https-service"
echo "  consul config delete -kind service-defaults   -name https-service"
echo "  nomad job run infrastructure/nginx-rewrite/job.nomad.hcl"
echo "=============================================="
