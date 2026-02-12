#!/usr/bin/bash
set -euo pipefail

# Re-evaluates all system jobs so Nomad schedules them on newly eligible nodes.
#
# Nomad does not automatically place system job allocations on nodes that become
# eligible again after a drain. This script triggers evaluation for all system
# jobs (e.g. ingress-gateway, traefik) to fix "degraded" status.
#
# Usage: ./eval_system_jobs.sh

echo "Re-evaluating system jobs..."
SYSTEM_JOBS=$(nomad job status -type=system -short | awk 'NR>1 && $1 != "" {print $1}')

if [[ -z "$SYSTEM_JOBS" ]]; then
    echo "No system jobs found"
    exit 0
fi

for job in $SYSTEM_JOBS; do
    echo "  nomad job eval $job"
    nomad job eval "$job"
done

echo "Done"
