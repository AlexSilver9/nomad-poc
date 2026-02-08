#!/usr/bin/bash
set -euo pipefail

# Drops and rebuilds the cluster

./terminate_instances.sh && ./delete_albs.sh --all && ./delete_target_group.sh --all && ./setup_cluster.sh