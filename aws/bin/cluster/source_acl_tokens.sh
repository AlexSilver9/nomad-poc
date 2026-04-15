#!/bin/bash

# Prompt for Consul and Nomad tokens and export them to the current shell.
# Must be sourced so variables are set in the calling shell:
#
#   source ./aws/bin/cluster/source_acl_tokens.sh
#   . ./aws/bin/cluster/source_acl_tokens.sh
#
# Tokens are read with echo suppressed and never passed as command arguments,
# so they do not appear in shell history and output.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: this script must be sourced, not executed:" >&2
    echo "  source ${0}" >&2
    exit 1
fi

read -rsp "Consul token: " CONSUL_HTTP_TOKEN && echo && export CONSUL_HTTP_TOKEN
read -rsp "Nomad token: "  NOMAD_TOKEN       && echo && export NOMAD_TOKEN

echo "Exported CONSUL_HTTP_TOKEN and NOMAD_TOKEN."
