#!/usr/bin/bash
set -euo pipefail

# Revoke Nomad and Consul tokens for the given user.
# Delegates to revoke_nomad_user_tokens.sh and revoke_consul_user_tokens.sh.
#
# Prerequisites:
#   NOMAD_TOKEN       — Nomad management token (export before running)
#   CONSUL_HTTP_TOKEN — Consul management token (export before running)
#
# Usage:
#   export NOMAD_TOKEN=<management-token>
#   export CONSUL_HTTP_TOKEN=<management-token>
#   ./aws/bin/instance/revoke_user_tokens.sh <username>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -n "${NOMAD_TOKEN:-}" ]]       || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
[[ $# -eq 1 ]]                    || { echo "Usage: $0 <username>"; exit 1; }

"$SCRIPT_DIR/revoke_nomad_user_tokens.sh" "$1"
echo ""
"$SCRIPT_DIR/revoke_consul_user_tokens.sh" "$1"
