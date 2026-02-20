#!/bin/bash
set -euo pipefail

# Bootstrap Consul and Nomad ACLs on an existing running cluster (Day-2 operation).
# Run this AFTER the cluster is healthy (consul members + nomad server members all alive).
#
# This script:
#   Phase 0 - Writes ACL config files to all nodes and does a rolling restart
#   Phase 1 - Bootstraps Consul ACL, creates policies + tokens, applies agent tokens
#   Phase 2 - Writes Nomad's Consul token to all nodes, restarts Nomad
#   Phase 3 - Bootstraps Nomad ACL, creates policies + tokens
#
# After this script, Consul and Nomad UIs still allow unauthenticated access
# (Consul default_policy = "allow"). Switch to "deny" in a planned maintenance
# window once all token consumers are configured.
#
# Usage: ./bootstrap_acl.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL_DIR="$SCRIPT_DIR/../../acl"
SH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR"
REMOTE_HOME="/home/$SSH_USER"
GITHUB_RAW="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main"
CONSUL_POLICIES_URL="$GITHUB_RAW/aws/acl/consul/policies"
NOMAD_POLICIES_URL="$GITHUB_RAW/aws/acl/nomad/policies"

# Output file for tokens (gitignored)
TOKEN_OUTPUT="$ACL_DIR/bootstrap-output.txt"

# Check dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq  &>/dev/null || { echo "Error: jq required"; exit 1; }
[[ -f "$SSH_KEY" ]]         || { echo "Error: SSH key not found at $SSH_KEY"; exit 1; }

# Helper: run a command on a remote node
ssh_exec() {
  local node="$1"; shift
  ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${node}" "$@"
}

# Bootstrap Consul ACL exactly once; handle "already done" and "ACL disabled" cases.
# Prints the management token, or "<already-bootstrapped>" if already done.
consul_bootstrap() {
  local node="$1"
  local output
  output=$(ssh_exec "$node" "consul acl bootstrap 2>&1" || true)

  if echo "$output" | grep -qi "ACL support disabled"; then
    echo "Error: Consul ACL is not enabled — Phase 0 may have failed." >&2
    exit 1
  elif echo "$output" | grep -qi "ACL bootstrap no longer allowed"; then
    echo "  Consul ACL already bootstrapped — skipping." >&2
    echo "<already-bootstrapped>"
    return
  fi

  local token
  token=$(echo "$output" | grep "SecretID:" | awk '{print $2}')
  if [[ -z "$token" ]]; then
    echo "Error: consul acl bootstrap returned unexpected output:" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "$token"
}

# Bootstrap Nomad ACL exactly once; handle "already done" and "ACL disabled" cases.
nomad_bootstrap() {
  local node="$1"
  local output
  output=$(ssh_exec "$node" "nomad acl bootstrap 2>&1" || true)

  if echo "$output" | grep -qi "ACL support disabled"; then
    echo "Error: Nomad ACL is not enabled — Phase 0 may have failed." >&2
    exit 1
  elif echo "$output" | grep -qi "bootstrap already done\|no longer allowed"; then
    echo "  Nomad ACL already bootstrapped — skipping." >&2
    echo "<already-bootstrapped>"
    return
  fi

  local token
  token=$(echo "$output" | grep "Secret ID" | awk '{print $4}')
  if [[ -z "$token" ]]; then
    echo "Error: nomad acl bootstrap returned unexpected output:" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "$token"
}

# ─────────────────────────────────────────────────────────────
echo "Fetching running EC2 instances..."
NODES=()
while IFS= read -r line; do
  NODES+=("$line")
done < <(aws ec2 describe-instances \
  | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName')

[[ ${#NODES[@]} -gt 0 ]] || { echo "Error: No running instances found"; exit 1; }

echo "Found ${#NODES[@]} nodes:"
printf '  %s\n' "${NODES[@]}"
BOOTSTRAP_NODE="${NODES[0]}"

# ─────────────────────────────────────────────────────────────
echo ""
echo "Phase 0: Writing ACL config files to all nodes"
echo "──────────────────────────────────────────────"

for node in "${NODES[@]}"; do
  echo "  $node — writing /etc/consul.d/acl.hcl"
  ssh_exec "$node" "sudo tee /etc/consul.d/acl.hcl > /dev/null && sudo chown consul:consul /etc/consul.d/acl.hcl" <<'HCLEOF'
# ACL configuration — written by bootstrap_acl.sh
# default_policy = "allow" preserves existing traffic during transition.
# Switch to "deny" in a maintenance window once all tokens are distributed.
acl {
  enabled                  = true
  default_policy           = "allow"
  enable_token_persistence = true
}
HCLEOF
done

echo "  Rolling restart Consul (one node at a time, waiting for rejoin before next)..."
for node in "${NODES[@]}"; do
  echo "    Restarting $node..."
  ssh_exec "$node" "sudo systemctl restart consul"
  for i in {1..12}; do
    alive=$(ssh_exec "$BOOTSTRAP_NODE" "consul members 2>/dev/null | { grep -c alive || true; }" || echo 0)
    if [[ "$alive" -ge "${#NODES[@]}" ]]; then
      echo "    Rejoined ($alive/${#NODES[@]} alive)."
      break
    fi
    [[ "$i" -eq 12 ]] && { echo "Error: $node did not rejoin Consul cluster after restart"; exit 1; }
    sleep 5
  done
done

for node in "${NODES[@]}"; do
  echo "  $node — writing /etc/nomad.d/acl.hcl"
  ssh_exec "$node" "sudo tee /etc/nomad.d/acl.hcl > /dev/null" <<'HCLEOF'
# ACL configuration — written by bootstrap_acl.sh
acl {
  enabled = true
}
HCLEOF
done

# ─────────────────────────────────────────────────────────────
echo ""
echo "Phase 1: Bootstrap Consul ACL"
echo "──────────────────────────────────────────────"

CONSUL_MGMT_TOKEN=$(consul_bootstrap "$BOOTSTRAP_NODE")
CONSUL_NOMAD_TOKEN=""  # set inside the block below; checked before Phase 2

if [[ "$CONSUL_MGMT_TOKEN" != "<already-bootstrapped>" ]]; then
  echo "  Consul management token captured."

  echo "  Applying Consul policies..."
  ssh_exec "$BOOTSTRAP_NODE" "
    wget -qO ${REMOTE_HOME}/agent.policy.hcl '${CONSUL_POLICIES_URL}/agent.policy.hcl'
    CONSUL_HTTP_TOKEN='$CONSUL_MGMT_TOKEN' consul acl policy create \
      -name agent -description 'Consul agent token policy' -rules - < ${REMOTE_HOME}/agent.policy.hcl

    wget -qO ${REMOTE_HOME}/nomad-server.policy.hcl '${CONSUL_POLICIES_URL}/nomad-server.policy.hcl'
    CONSUL_HTTP_TOKEN='$CONSUL_MGMT_TOKEN' consul acl policy create \
      -name nomad-server -description 'Nomad Consul integration policy' -rules - < ${REMOTE_HOME}/nomad-server.policy.hcl
  "

  echo "  Creating Consul tokens..."
  CONSUL_AGENT_TOKEN=$(ssh_exec "$BOOTSTRAP_NODE" \
    "CONSUL_HTTP_TOKEN=$CONSUL_MGMT_TOKEN consul acl token create \
      -policy-name=agent -description='Consul agent token (all nodes)' -format=json" \
    | jq -r '.SecretID')

  CONSUL_NOMAD_TOKEN=$(ssh_exec "$BOOTSTRAP_NODE" \
    "CONSUL_HTTP_TOKEN=$CONSUL_MGMT_TOKEN consul acl token create \
      -policy-name=nomad-server -description='Nomad Consul integration token' -format=json" \
    | jq -r '.SecretID')

  echo "  Applying Consul agent token to all nodes..."
  for node in "${NODES[@]}"; do
    echo "    $node"
    ssh_exec "$node" \
      "CONSUL_HTTP_TOKEN=$CONSUL_MGMT_TOKEN consul acl set-agent-token agent $CONSUL_AGENT_TOKEN"
  done

  {
    echo "=== CONSUL TOKENS ==="
    echo "Management Token : $CONSUL_MGMT_TOKEN"
    echo "Agent Token      : $CONSUL_AGENT_TOKEN"
    echo "Nomad Token      : $CONSUL_NOMAD_TOKEN"
  } > "$TOKEN_OUTPUT"
fi

# ─────────────────────────────────────────────────────────────
echo ""
echo "Phase 2: Write Nomad Consul token + restart Nomad"
echo "──────────────────────────────────────────────"

if [[ -z "$CONSUL_NOMAD_TOKEN" ]]; then
  echo "  Consul ACL was already bootstrapped in a previous run."
  echo "  Cannot write Nomad Consul token without knowing it."
  echo "  Write it manually: sudo tee /etc/nomad.d/consul-token.hcl on each node."
  echo "  Then restart Nomad: sudo systemctl restart nomad"
  echo ""
else

for node in "${NODES[@]}"; do
  echo "  $node — writing /etc/nomad.d/consul-token.hcl"
  ssh_exec "$node" "sudo tee /etc/nomad.d/consul-token.hcl > /dev/null" <<HCLEOF
# Consul token for Nomad's Consul integration — written by bootstrap_acl.sh
consul {
  token = "$CONSUL_NOMAD_TOKEN"
}
HCLEOF
done

echo "  Rolling restart Nomad (one node at a time)..."
for node in "${NODES[@]}"; do
  echo "    Restarting $node..."
  ssh_exec "$node" "sudo systemctl restart nomad"
  sleep 8
done

echo "  Waiting for Nomad to be active on all nodes..."
for i in {1..12}; do
  alive=0
  for node in "${NODES[@]}"; do
    ssh_exec "$node" "systemctl is-active --quiet nomad" 2>/dev/null && ((alive++)) || true
  done
  if [[ "$alive" -ge "${#NODES[@]}" ]]; then
    echo "  All $alive nodes active."
    break
  fi
  [[ "$i" -eq 12 ]] && { echo "Error: Nomad did not stabilise after restart"; exit 1; }
  echo "  Waiting... ($alive/${#NODES[@]} active)"
  sleep 5
done

fi  # end CONSUL_NOMAD_TOKEN guard

# ─────────────────────────────────────────────────────────────
echo ""
echo "Phase 3: Bootstrap Nomad ACL"
echo "──────────────────────────────────────────────"

NOMAD_MGMT_TOKEN=$(nomad_bootstrap "$BOOTSTRAP_NODE")

if [[ "$NOMAD_MGMT_TOKEN" != "<already-bootstrapped>" ]]; then
  echo "  Nomad management token captured."

  echo "  Applying Nomad policies..."
  ssh_exec "$BOOTSTRAP_NODE" "
    wget -qO ${REMOTE_HOME}/deployer.policy.hcl '${NOMAD_POLICIES_URL}/deployer.policy.hcl'
    NOMAD_TOKEN='$NOMAD_MGMT_TOKEN' nomad acl policy apply \
      -description='Job deployment policy' deployer ${REMOTE_HOME}/deployer.policy.hcl

    wget -qO ${REMOTE_HOME}/readonly.policy.hcl '${NOMAD_POLICIES_URL}/readonly.policy.hcl'
    NOMAD_TOKEN='$NOMAD_MGMT_TOKEN' nomad acl policy apply \
      -description='Read-only monitoring policy' readonly ${REMOTE_HOME}/readonly.policy.hcl
  "

  echo "  Creating Nomad tokens..."
  NOMAD_DEPLOYER_TOKEN=$(ssh_exec "$BOOTSTRAP_NODE" \
    "NOMAD_TOKEN=$NOMAD_MGMT_TOKEN nomad acl token create \
      -name=deployer -policy=deployer -type=client -json" \
    | jq -r '.SecretID')

  NOMAD_READONLY_TOKEN=$(ssh_exec "$BOOTSTRAP_NODE" \
    "NOMAD_TOKEN=$NOMAD_MGMT_TOKEN nomad acl token create \
      -name=readonly -policy=readonly -type=client -json" \
    | jq -r '.SecretID')

  {
    echo ""
    echo "=== NOMAD TOKENS ==="
    echo "Management Token : $NOMAD_MGMT_TOKEN"
    echo "Deployer Token   : $NOMAD_DEPLOYER_TOKEN"
    echo "Read-only Token  : $NOMAD_READONLY_TOKEN"
  } >> "$TOKEN_OUTPUT"
fi

# ─────────────────────────────────────────────────────────────
echo ""
echo "Bootstrap complete."
echo ""
echo "Token summary written to: $TOKEN_OUTPUT"
echo "IMPORTANT: Securely store these tokens before deleting the output file!"
echo ""
echo "  Management tokens  → product owner → password manager"
echo "  Deployer token     → CI/CD systems, deployment engineers"
echo "  Read-only token    → monitoring systems"
echo ""
echo "Next steps:"
echo "  Verify Consul UI:  http://<node>:8500  (no token required yet)"
echo "  Verify Nomad UI:   http://<node>:4646  (no token required yet)"
echo "  [MAINTENANCE WINDOW] Switch Consul to deny: ./aws/bin/cluster/enforce_acl.sh"
