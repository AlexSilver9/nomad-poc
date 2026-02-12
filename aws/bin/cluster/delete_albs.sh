#!/usr/bin/bash
set -euo pipefail

# Delete a specific ALB or all ALBs.
# Also deletes associated listeners.
# Requires: aws-cli, jq
# Usage: ./delete_alb.sh [alb-name]
#        ./delete_alb.sh --all

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

# Functin to delete an ALB
delete_alb() {
    local arn="$1"
    local name="$2"

    echo "Deleting ALB: ${name}"

    # Delete listeners first
    listeners=$(aws elbv2 describe-listeners --load-balancer-arn "${arn}" \
        | jq -r '.Listeners[].ListenerArn')

    for listener_arn in $listeners; do
        if [[ -n "$listener_arn" ]]; then
            echo "  Deleting listener: ${listener_arn}"
            aws elbv2 delete-listener --listener-arn "${listener_arn}"
        fi
    done

    # Delete the load balancer
    aws elbv2 delete-load-balancer --load-balancer-arn "${arn}"
    echo "  Deleted: ${name}"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <alb-name>"
    echo "       $0 --all"
    echo ""
    echo "Available load balancers:"
    aws elbv2 describe-load-balancers \
        | jq -r '.LoadBalancers[] | "  \(.LoadBalancerName) - \(.DNSName)"'
    exit 1
fi

if [[ "$1" == "--all" ]]; then
    echo "Deleting ALL Application Load Balancers..."
    albs=$(aws elbv2 describe-load-balancers \
        | jq -r '.LoadBalancers[] | select(.Type == "application") | "\(.LoadBalancerArn)|\(.LoadBalancerName)"')

    if [[ -z "$albs" ]]; then
        echo "No ALBs found"
        exit 0
    fi

    for alb in $albs; do
        arn=$(echo "$alb" | cut -d'|' -f1)
        name=$(echo "$alb" | cut -d'|' -f2)
        delete_alb "$arn" "$name"
    done
else
    ALB_NAME="$1"
    echo "Looking up ALB: ${ALB_NAME}"

    result=$(aws elbv2 describe-load-balancers --names "${ALB_NAME}" 2>/dev/null || true)

    if [[ -z "$result" ]] || [[ "$(echo "$result" | jq '.LoadBalancers | length')" == "0" ]]; then
        echo "Error: ALB '${ALB_NAME}' not found"
        exit 1
    fi

    arn=$(echo "$result" | jq -r '.LoadBalancers[0].LoadBalancerArn')
    delete_alb "$arn" "$ALB_NAME"
fi

echo ""
echo "Done"
