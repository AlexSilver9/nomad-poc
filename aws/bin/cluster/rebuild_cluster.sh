#!/usr/bin/bash
set -euo pipefail

# Drops and rebuilds the cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/terminate_instances.sh" && \
    "$SCRIPT_DIR/delete_efs.sh" --all && \
    "$SCRIPT_DIR/delete_albs.sh" --all && \
    "$SCRIPT_DIR/delete_target_group.sh" --all && \
    "$SCRIPT_DIR/setup_cluster.sh"