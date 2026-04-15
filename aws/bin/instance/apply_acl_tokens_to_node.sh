#!/bin/bash
set -euo pipefail

# Onboard a new node to an existing ACL-enabled cluster.
# Run this script ON the new node AFTER setup_consul_aws_ami.sh and setup_nomad_aws_ami.sh.
# PREREQUISITE: bootstrap_acl.sh must have been executed on the cluster before running this.
#
# This script:
# 1. Writes /etc/consul.d/acl.hcl with ACL enabled
# 2. Restarts Consul so it joins the cluster ACL-aware
# 3. Applies the Consul agent token to this node (persisted via enable_token_persistence)
# 4. Writes /etc/nomad.d/acl.hcl with ACL enabled
# 5. Writes /etc/nomad.d/consul-token.hcl with Nomad's Consul token
# 6. Restarts Nomad
#
# You will be prompted for token values. Get them from the password manager.
#
# Usage: ./apply_acl_tokens_to_node.sh

echo "========================================="
echo "Node ACL Onboarding"
echo "========================================="
echo ""
echo "You will be prompted for token values from the password manager:"
echo "  1. Consul agent token"
echo "  2. Nomad Consul token (Nomad's Consul integration token)"
echo "  3. Consul management token (only if enforce mode is detected)"
echo ""

read -r -s -p "Enter Consul agent token: " CONSUL_AGENT_TOKEN
echo ""
[[ -n "$CONSUL_AGENT_TOKEN" ]] || { echo "Error: Consul agent token cannot be empty"; exit 1; }

read -r -s -p "Enter Nomad Consul token: " NOMAD_CONSUL_TOKEN
echo ""
[[ -n "$NOMAD_CONSUL_TOKEN" ]] || { echo "Error: Nomad Consul token cannot be empty"; exit 1; }

echo ""
echo "Detecting cluster ACL enforcement mode..."
# Probe the local Consul API without a token.
# allow mode → 200, deny mode → 403.
http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8500/v1/catalog/nodes)
if [[ "$http_code" == "403" ]]; then
  CONSUL_DEFAULT_POLICY="deny"
else
  CONSUL_DEFAULT_POLICY="allow"
fi
echo "  Detected default_policy = $CONSUL_DEFAULT_POLICY"

CONSUL_MGMT_TOKEN=""
if [[ "$CONSUL_DEFAULT_POLICY" == "deny" ]]; then
  echo ""
  read -r -s -p "Cluster is in enforce mode. Enter Consul management token: " CONSUL_MGMT_TOKEN
  echo ""
  [[ -n "$CONSUL_MGMT_TOKEN" ]] || { echo "Error: Consul management token cannot be empty"; exit 1; }
fi

echo ""
echo "Writing /etc/consul.d/acl.hcl..."
sudo tee /etc/consul.d/acl.hcl > /dev/null <<HCLEOF
# ACL configuration — written by apply_acl_tokens_to_node.sh
acl {
  enabled                  = true
  default_policy           = "$CONSUL_DEFAULT_POLICY"
  enable_token_persistence = true
}
HCLEOF
sudo chown consul:consul /etc/consul.d/acl.hcl

echo "Restarting Consul..."
sudo systemctl restart consul

echo "Waiting for Consul to rejoin cluster..."
for i in {1..12}; do
  # /v1/status/leader does not require ACL authorization — avoids 403 errors during
  # the brief window after restart while the agent replicates ACL state from the leader.
  leader=$(curl -s http://127.0.0.1:8500/v1/status/leader | tr -d '"[:space:]')
  if [[ -n "$leader" ]]; then
    echo "  Consul is up (leader: $leader)."
    break
  fi
  [[ "$i" -eq 12 ]] && { echo "Error: Consul did not come back after restart"; exit 1; }
  sleep 5
done

echo "Applying Consul agent token..."
for i in $(seq 1 12); do
  if CONSUL_HTTP_TOKEN="$CONSUL_MGMT_TOKEN" consul acl set-agent-token agent "$CONSUL_AGENT_TOKEN"; then
    break
  fi
  [[ "$i" -eq 12 ]] && { echo "Error: failed to apply Consul agent token after 12 attempts"; exit 1; }
  echo "  ACL not ready yet, retrying... ($i/12)"
  sleep 5
done

echo "Writing /etc/nomad.d/acl.hcl..."
sudo tee /etc/nomad.d/acl.hcl > /dev/null <<'HCLEOF'
# ACL configuration — written by apply_acl_tokens_to_node.sh
acl {
  enabled = true
}
HCLEOF

# grpc_address: node IP + port 8502 (plain gRPC).
# Node IP: Nomad creates a unix socket proxy to this address for Envoy sidecars.
#   The socket is accessed from inside bridge network namespaces where 127.0.0.1
#   is the container's own loopback — the node IP routes through the bridge to host.
# Port 8502: Nomad's unix socket proxy is a plain TCP proxy (no TLS). Port 8503
#   requires TLS; Consul terminates plain connections to it immediately.

NODE_IP="$(/sbin/ip route get 1 | awk '{print $7; exit}')"

echo "Writing /etc/nomad.d/consul.hcl..."
sudo tee /etc/nomad.d/consul.hcl > /dev/null <<HCLEOF
# Nomad-Consul integration — written by apply_acl_tokens_to_node.sh.
# Single file avoids HCL merge issues across multiple consul{} blocks.
consul {
  address      = "127.0.0.1:8500"
  grpc_address = "${NODE_IP}:8502"
  token        = "$NOMAD_CONSUL_TOKEN"

  service_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }
}
HCLEOF
# Remove legacy file if it exists from old installs
sudo rm -f /etc/nomad.d/consul-token.hcl

echo "Restarting Nomad..."
sudo systemctl restart nomad

echo ""
echo "========================================="
echo "Onboarding complete."
echo "========================================="
echo ""
echo "Verify:"
echo "  consul info | grep -A5 'acl'"
echo "  consul members"
echo "  nomad server members"
echo ""
