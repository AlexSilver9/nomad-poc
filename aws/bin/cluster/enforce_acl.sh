#!/bin/bash
set -euo pipefail

# Switch Consul ACL from transition mode (default_policy = "allow") to
# enforcement mode (default_policy = "deny"). Run this in a maintenance window
# after bootstrap_acl.sh has been executed and all token consumers are configured.
#
# This is a one-way operation. After this, unauthenticated access to the
# Consul UI and API is blocked. Ensure all clients have valid tokens before running.
#
# Nomad ACL denies unauthenticated access by default — no change needed there.
#
# Requires: aws-cli, jq, SSH_KEY env var point to nomad-keypair.pem or SSH key at ~/workspace/nomad/nomad-keypair.pem
# Usage: ./enforce_acl.sh

SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq  &>/dev/null || { echo "Error: jq required"; exit 1; }
[[ -f "$SSH_KEY" ]]         || { echo "Error: SSH key not found at $SSH_KEY"; exit 1; }

ssh_exec() {
  local node="$1"; shift
  ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${node}" "$@"
}

echo "Fetching running EC2 instances..."
NODES=()
while IFS= read -r line; do
  NODES+=("$line")
done < <(aws ec2 describe-instances \
  | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName')

[[ ${#NODES[@]} -gt 0 ]] || { echo "Error: No running instances found"; exit 1; }

echo "Found ${#NODES[@]} nodes:"
printf '  %s\n' "${NODES[@]}"

echo ""
echo "WARNING: This will switch Consul to deny unauthenticated access on all nodes."
echo "Ensure all clients have valid tokens before proceeding."
echo ""
read -r -p "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

echo ""
echo "Switching Consul default_policy to 'deny' + rolling restart..."
for node in "${NODES[@]}"; do
  echo "  $node"
  ssh_exec "$node" \
    "sudo sed -i 's/default_policy\s*=\s*\"allow\"/default_policy           = \"deny\"/' /etc/consul.d/acl.hcl \
     && sudo systemctl restart consul"
  sleep 8

  # Verify the node is back and consul is running
  if ! ssh_exec "$node" "systemctl is-active --quiet consul"; then
    echo "Error: Consul failed to restart on $node"
    exit 1
  fi
done

echo ""
echo "Verifying Consul is active on all nodes..."
# consul members requires a token in deny mode, so check the systemd service instead.
for node in "${NODES[@]}"; do
  if ssh_exec "$node" "systemctl is-active --quiet consul"; then
    echo "  $node — ok"
  else
    echo "  Error: Consul is not active on $node"
    exit 1
  fi
done

echo ""
echo "Done. Consul ACL is now in enforcement mode."
echo "  Consul UI and API require a valid token."
echo "  Verify: open http://<node>:8500 — should prompt for a token."
