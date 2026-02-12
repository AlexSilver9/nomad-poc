#!/usr/bin/bash
set -euo pipefail

# Drops and rebuilds the cluster

./cluster/terminate_instances.sh && ./cluster/delete_albs.sh --all && ./cluster/delete_target_group.sh --all && ./cluster/setup_cluster.sh