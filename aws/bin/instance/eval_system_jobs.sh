#!/usr/bin/bash
set -euo pipefail

# Re-evaluates all system jobs so Nomad schedules them on newly eligible nodes.
#
# Nomad does not automatically place system job allocations on nodes that become
# eligible again after a drain. This script triggers evaluation for all system
# jobs (e.g. ingress-gateway, traefik) to fix "degraded" status if required.
#
# Usage: ./eval_system_jobs.sh

echo "Re-evaluating system jobs..."
NOMAD_ADDR="${NOMAD_ADDR:-http://127.0.0.1:4646}"
SYSTEM_JOBS=$(curl -s "${NOMAD_ADDR}/v1/jobs?type=system" | jq -r '.[].ID')

if [[ -z "$SYSTEM_JOBS" ]]; then
    echo "No system jobs found"
    exit 0
fi

for job in $SYSTEM_JOBS; do
    echo "  nomad job eval $job"
    nomad job eval "$job"
done

echo "Done"
