#!/bin/bash
set -euo pipefail

# Apply a Nomad ACL metrics-scraper token to a running Prometheus deployment.
# Run this after enabling Nomad ACL on a cluster that already has monitoring set up.
#
# What it does:
#   1. Creates the metrics-scraper ACL policy and token on the cluster
#   2. Redeploys Prometheus with the token (no data loss — EFS volume persists)
#   3. Appends the token to monitoring-credentials.txt
#
# Prerequisites:
#   - Monitoring is already deployed (setup_monitoring.sh was run)
#   - Nomad ACL is enforced
#   - NOMAD_TOKEN is set (management token)
#   - SSH_KEY points to the EC2 keypair (default: ~/workspace/nomad/nomad-keypair.pem)
#
# Usage: ./setup_monitoring_acl.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL_DIR="$SCRIPT_DIR/../../acl"
SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
MONITORING_TOKENS_FILE="$ACL_DIR/monitoring-credentials.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

ssh_exec() {
    local node="$1"; shift
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${node}" "$@"
}

check_prerequisites() {
    [[ -f "$SSH_KEY" ]] || { log_error "SSH key not found at $SSH_KEY"; exit 1; }
    command -v aws &>/dev/null || { log_error "aws-cli required"; exit 1; }
    command -v jq  &>/dev/null || { log_error "jq required"; exit 1; }

    local http_status
    http_status=$(ssh_exec "$FIRST_NODE" \
        "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:4646/v1/metrics?format=prometheus")
    [[ "$http_status" == "403" ]] || {
        log_error "Nomad ACL does not appear to be enforced (got $http_status, expected 403)"
        log_error "Only run this script after ACL enforcement is enabled"
        exit 1
    }
}

discover_first_node() {
    log_info "Discovering cluster nodes..."
    FIRST_NODE=$(aws ec2 describe-instances \
        | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName' \
        | head -1)
    [[ -n "$FIRST_NODE" ]] || { log_error "No running EC2 instances found"; exit 1; }
    log_info "Using node: $FIRST_NODE"
}

create_scrape_token() {
    log_info "Applying metrics-scraper ACL policy..."
    ssh_exec "$FIRST_NODE" "mkdir -p acl/nomad/policies && wget -qO acl/nomad/policies/metrics-scraper.policy.hcl $GITHUB_RAW_BASE/acl/nomad/policies/metrics-scraper.policy.hcl"
    ssh_exec "$FIRST_NODE" "nomad acl policy apply \
        -description 'Read-only policy for Prometheus metrics scraping' \
        metrics-scraper \
        acl/nomad/policies/metrics-scraper.policy.hcl"
    log_success "Policy applied"

    log_info "Creating metrics-scraper token..."
    local token_output
    token_output=$(ssh_exec "$FIRST_NODE" "nomad acl token create \
        -name=prometheus-metrics-scraper \
        -policy=metrics-scraper \
        -type=client")

    NOMAD_SCRAPE_TOKEN=$(echo "$token_output" | grep "^Secret ID" | awk '{print $4}')
    [[ -n "$NOMAD_SCRAPE_TOKEN" ]] || { log_error "Failed to extract scrape token"; exit 1; }
    log_success "Token created"
}

redeploy_prometheus() {
    log_info "Redeploying Prometheus with scrape token..."
    ssh_exec "$FIRST_NODE" "mkdir -p infrastructure/prometheus && wget -qO infrastructure/prometheus/job.nomad.hcl $GITHUB_RAW_BASE/infrastructure/prometheus/job.nomad.hcl"

    local consul_var=""
    [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] && consul_var="-var=consul_token=$CONSUL_HTTP_TOKEN"

    ssh_exec "$FIRST_NODE" "nomad job run \
        -var=nomad_scrape_token=$NOMAD_SCRAPE_TOKEN \
        $consul_var \
        infrastructure/prometheus/job.nomad.hcl"
    log_success "Prometheus redeployed"
}

save_token() {
    if [[ -f "$MONITORING_TOKENS_FILE" ]]; then
        printf '\n# Nomad ACL (added by setup_monitoring_acl.sh)\nNOMAD_SCRAPE_TOKEN=%s\n' \
            "$NOMAD_SCRAPE_TOKEN" >> "$MONITORING_TOKENS_FILE"
    else
        mkdir -p "$ACL_DIR"
        printf '# Nomad ACL scrape token\nNOMAD_SCRAPE_TOKEN=%s\n' \
            "$NOMAD_SCRAPE_TOKEN" > "$MONITORING_TOKENS_FILE"
    fi
    log_success "Token saved to $MONITORING_TOKENS_FILE"
}

main() {
    echo "=============================================="
    echo "  Monitoring ACL Setup"
    echo "=============================================="
    echo ""

    discover_first_node
    check_prerequisites
    create_scrape_token
    redeploy_prometheus
    save_token

    echo ""
    log_success "Done — Prometheus is now scraping with ACL token"
}

main "$@"
