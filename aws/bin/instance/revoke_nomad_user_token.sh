#!/usr/bin/bash
set -euo pipefail

# Revoke Nomad token for the given user.
#
# Prerequisites:
#   NOMAD_TOKEN — Nomad management token (export before running)
#
# Usage:
#   export NOMAD_TOKEN=<management-token>
#   ./aws/bin/instance/revoke_nomad_user_tokens.sh <username>

command -v nomad &>/dev/null || { echo "Error: nomad CLI required"; exit 1; }
command -v jq    &>/dev/null || { echo "Error: jq required"; exit 1; }

[[ -n "${NOMAD_TOKEN:-}" ]] || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ $# -eq 1 ]]              || { echo "Usage: $0 <username>"; exit 1; }

USERNAME="$1"

echo "=== Revoking Nomad user tokens ==="
echo ""

accessors=$(nomad acl token list -json 2>/dev/null \
  | jq -r --arg n "$USERNAME" '.[] | select(.Name == $n) | .AccessorID')

if [[ -z "$accessors" ]]; then
  echo "  $USERNAME — no token found, skipping"
else
  while IFS= read -r accessor; do
    nomad acl token delete "$accessor" > /dev/null
    echo "  $USERNAME — token $accessor deleted"
  done <<< "$accessors"
fi

echo ""
echo "Done."
