#!/usr/bin/bash
set -euo pipefail

# Create Nomad roles, Consul roles, and personal user tokens.
# Run this on a node AFTER bootstrap_acl.sh has completed successfully.
#
# Run directly on a cluster node (requires nomad and consul CLIs).
#
# Reads users and their role assignments from acl/users.json.
# Tokens are appended to acl/user-tokens-output.txt (gitignored).
# Transfer the output file to the password manager, then delete it.
#
# Prerequisites:
#   NOMAD_TOKEN       — Nomad management token (export before running)
#   CONSUL_HTTP_TOKEN — Consul management token (export before running)
#
# Usage:
#   export NOMAD_TOKEN=<management-token>
#   export CONSUL_HTTP_TOKEN=<management-token>
#   ./aws/bin/instance/create_user_tokens.sh

ACL_DIR="$HOME/acl"
USERS_JSON="$ACL_DIR/users.json"
TOKEN_OUTPUT="$ACL_DIR/user-tokens-output.txt"

# Check dependencies
command -v nomad  &>/dev/null || { echo "Error: nomad CLI required"; exit 1; }
command -v consul &>/dev/null || { echo "Error: consul CLI required"; exit 1; }
command -v jq     &>/dev/null || { echo "Error: jq required"; exit 1; }

[[ -n "${NOMAD_TOKEN:-}" ]]       || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
[[ -f "$USERS_JSON" ]]            || { echo "Error: $USERS_JSON not found"; exit 1; }

echo "=== Nomad / Consul role and user token provisioning ==="
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Create Nomad roles (idempotent)
# ---------------------------------------------------------------------------
echo "--- Phase 1: Nomad roles ---"

create_nomad_role() {
  local name="$1" policy="$2" description="$3"
  if nomad acl role list -json 2>/dev/null | jq -e --arg n "$name" '.[] | select(.Name == $n)' > /dev/null 2>&1; then
    echo "  nomad role '$name' already exists — skipping"
  else
    nomad acl role create -name="$name" -policy="$policy" -description="$description" > /dev/null
    echo "  nomad role '$name' created"
  fi
}

create_nomad_role "nomad-deployer"      "deployer"      "Submit and manage jobs, exec into allocations"
create_nomad_role "nomad-readonly"      "readonly"      "Read-only access to jobs, logs, and nodes"
create_nomad_role "nomad-node-operator" "node-operator" "Drain and re-enable nodes"

echo ""

# ---------------------------------------------------------------------------
# Phase 2: Create Consul roles (idempotent)
# ---------------------------------------------------------------------------
echo "--- Phase 2: Consul roles ---"

create_consul_role() {
  local name="$1" policy="$2" description="$3"
  if consul acl role list -format=json 2>/dev/null | jq -e --arg n "$name" '.[] | select(.Name == $n)' > /dev/null 2>&1; then
    echo "  consul role '$name' already exists — skipping"
  else
    consul acl role create -name="$name" -policy-name="$policy" -description="$description" > /dev/null
    echo "  consul role '$name' created"
  fi
}

create_consul_role "consul-readonly"  "operator-readonly"  "Read nodes, services, agents, and KV store"
create_consul_role "consul-readwrite" "operator-readwrite" "Write nodes, services, agents, and KV store"

echo ""

# ---------------------------------------------------------------------------
# Phase 3: Create personal user tokens
# ---------------------------------------------------------------------------
echo "--- Phase 3: User tokens ---"

# Append a separator to the output file
{
  echo ""
  echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
} >> "$TOKEN_OUTPUT"

jq -c '.[]' "$USERS_JSON" | while IFS= read -r user; do
  username=$(jq -r '.username' <<< "$user")
  echo "  user: $username"

  # --- Nomad token ---
  existing_nomad_accessor=$(nomad acl token list -json 2>/dev/null \
    | jq -r --arg n "$username" '.[] | select(.Name == $n) | .AccessorID')
  if [[ -n "$existing_nomad_accessor" ]]; then
    echo "    nomad token for '$username' already exists — skipping"
    nomad_secret=$(curl -s -H "X-Nomad-Token: $NOMAD_TOKEN" \
      "http://localhost:4646/v1/acl/token/$existing_nomad_accessor" | jq -r '.SecretID')
  else
    nomad_role_flags=$(jq -r '.nomad_roles[] | "-role-name=\(.)"' <<< "$user" | tr '\n' ' ')
    nomad_secret=$(nomad acl token create \
      -name="$username" \
      -type=client \
      $nomad_role_flags \
      -json | jq -r '.SecretID')
    echo "    nomad token created"
  fi

  # --- Consul token ---
  existing_consul=$(consul acl token list -format=json 2>/dev/null \
    | jq -r --arg d "$username" '.[] | select(.Description == $d) | .SecretID')
  if [[ -n "$existing_consul" ]]; then
    echo "    consul token for '$username' already exists — skipping"
    consul_secret="$existing_consul"
  else
    consul_role_flags=$(jq -r '.consul_roles[] | "-role-name=\(.)"' <<< "$user" | tr '\n' ' ')
    consul_secret=$(consul acl token create \
      -description="$username" \
      $consul_role_flags \
      -format=json | jq -r '.SecretID')
    echo "    consul token created"
  fi

  # Append to output file
  {
    echo "[$username]"
    echo "  nomad_roles:  $(jq -r '.nomad_roles | join(", ")' <<< "$user")"
    echo "  nomad_token:  $nomad_secret"
    echo "  consul_roles: $(jq -r '.consul_roles | join(", ")' <<< "$user")"
    echo "  consul_token: $consul_secret"
    echo ""
  } >> "$TOKEN_OUTPUT"

done

echo ""
echo "Done. Tokens written to: $TOKEN_OUTPUT"
echo "Transfer tokens to the password manager, then delete the output file."
