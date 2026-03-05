#!/usr/bin/bash
set -euo pipefail

# Revokes all Consul tokens for the given username.
#
# Prerequisites:
#   CONSUL_HTTP_TOKEN — Consul management token (export before running)
#
# Usage:
#   export CONSUL_HTTP_TOKEN=<management-token>
#   ./aws/bin/instance/revoke_consul_user_tokens.sh <username>

command -v consul &>/dev/null || { echo "Error: consul CLI required"; exit 1; }
command -v jq     &>/dev/null || { echo "Error: jq required"; exit 1; }

[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
[[ $# -eq 1 ]]                    || { echo "Usage: $0 <username>"; exit 1; }

USERNAME="$1"

echo "=== Revoking Consul user tokens ==="
echo ""

accessors=$(consul acl token list -format=json 2>/dev/null \
  | jq -r --arg d "$USERNAME" '.[] | select(.Description == $d) | .AccessorID')

if [[ -z "$accessors" ]]; then
  echo "  $USERNAME — no token found, skipping"
else
  while IFS= read -r accessor; do
    consul acl token delete -id "$accessor" > /dev/null
    echo "  $USERNAME — token $accessor deleted"
  done <<< "$accessors"
fi

echo ""
echo "Done."
