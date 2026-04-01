#!/bin/bash
set -euo pipefail

# Opt-in monitoring setup for an existing Nomad cluster.
# Deploys Prometheus and Grafana as Nomad jobs.
#
# Prerequisites:
#   - Cluster is running (ACL enforced or not — both work)
#   - NOMAD_ADDR and NOMAD_TOKEN are set
#   - CONSUL_HTTP_ADDR is set (CONSUL_HTTP_TOKEN only needed when Consul ACL is enforced)
#   - SSH_KEY points to the EC2 keypair (default: ~/workspace/nomad/nomad-keypair.pem)
#
# Usage: ./setup_monitoring.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infrastructure"
ACL_DIR="$SCRIPT_DIR/../../acl"
SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR"

# Token output file (gitignored)
MONITORING_TOKENS_FILE="$ACL_DIR/monitoring-tokens.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    [[ -n "${NOMAD_ADDR:-}"       ]] || { log_error "NOMAD_ADDR is not set";         exit 1; }
    [[ -n "${NOMAD_TOKEN:-}"      ]] || { log_error "NOMAD_TOKEN is not set";        exit 1; }
    [[ -n "${CONSUL_HTTP_ADDR:-}" ]] || { log_error "CONSUL_HTTP_ADDR is not set";   exit 1; }
    [[ -f "$SSH_KEY"              ]] || { log_error "SSH key not found at $SSH_KEY"; exit 1; }
    # CONSUL_HTTP_TOKEN is optional — only required when Consul ACL is enforced

    command -v nomad  &>/dev/null || { log_error "nomad CLI required"; exit 1; }
    command -v consul &>/dev/null || { log_error "consul CLI required"; exit 1; }
    command -v aws    &>/dev/null || { log_error "aws-cli required";    exit 1; }
    command -v jq     &>/dev/null || { log_error "jq required";         exit 1; }

    log_success "Prerequisites OK"
}

# Prompt for Grafana admin password
prompt_grafana_password() {
    if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
        log_info "Using GRAFANA_ADMIN_PASSWORD from environment"
        return
    fi

    echo ""
    read -rsp "Enter Grafana admin password: " GRAFANA_ADMIN_PASSWORD
    echo ""
    [[ -n "$GRAFANA_ADMIN_PASSWORD" ]] || { log_error "Password cannot be empty"; exit 1; }
    export GRAFANA_ADMIN_PASSWORD
}

# Discover running cluster nodes via AWS
discover_nodes() {
    log_info "Discovering cluster nodes..."
    NODES=()
    while IFS= read -r line; do
        NODES+=("$line")
    done < <(aws ec2 describe-instances \
        | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PublicDnsName')

    [[ ${#NODES[@]} -gt 0 ]] || { log_error "No running EC2 instances found"; exit 1; }

    log_success "Found ${#NODES[@]} node(s):"
    printf '  %s\n' "${NODES[@]}"
    export NODES
}

ssh_exec() {
    local node="$1"; shift
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${node}" "$@"
}

#------------------------------------------------------------------------------
# STEP 1: Run setup_nomad_monitoring.sh on every node (rolling)
#------------------------------------------------------------------------------
configure_nodes() {
    log_info "=== STEP 1: Configuring nodes (telemetry + host volumes) ==="

    local GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"

    for node in "${NODES[@]}"; do
        log_info "Configuring $node..."
        ssh_exec "$node" "curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_nomad_monitoring.sh | bash"
        log_success "$node configured"
    done

    # Wait for Nomad leader to be elected after rolling restarts
    log_info "Waiting for Nomad cluster to recover..."
    local first_node="${NODES[0]}"
    for i in $(seq 1 15); do
        if ssh_exec "$first_node" "nomad server members 2>/dev/null | grep -q alive"; then
            log_success "Nomad cluster healthy"
            break
        fi
        sleep 3
    done
}

#------------------------------------------------------------------------------
# STEP 2: Detect ACL mode and create metrics-scraper token if needed
#------------------------------------------------------------------------------
create_nomad_token() {
    log_info "=== STEP 2: Detecting ACL mode ==="

    # Probe the metrics endpoint — 403 means ACL is enforcing deny
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" "$NOMAD_ADDR/v1/metrics?format=prometheus")

    if [[ "$http_status" == "403" ]]; then
        log_info "ACL is enforced (got 403) — creating metrics-scraper token"

        # Create policy
        nomad acl policy apply \
            -description "Read-only policy for Prometheus metrics scraping" \
            metrics-scraper \
            "$ACL_DIR/nomad/policies/metrics-scraper.policy.hcl"
        log_success "Policy 'metrics-scraper' applied"

        # Create token
        local token_output
        token_output=$(nomad acl token create \
            -name="prometheus-metrics-scraper" \
            -policy=metrics-scraper \
            -type=client)

        NOMAD_SCRAPE_TOKEN=$(echo "$token_output" | grep "^Secret ID" | awk '{print $4}')
        [[ -n "$NOMAD_SCRAPE_TOKEN" ]] || { log_error "Failed to extract Nomad scrape token"; exit 1; }

        log_success "Nomad scrape token created"
    else
        log_info "ACL is not enforced (got $http_status) — deploying without token"
        NOMAD_SCRAPE_TOKEN=""
    fi

    export NOMAD_SCRAPE_TOKEN
}

#------------------------------------------------------------------------------
# STEP 3: Deploy Prometheus
#------------------------------------------------------------------------------
deploy_prometheus() {
    log_info "=== STEP 3: Deploying Prometheus ==="

    local token_vars=()
    [[ -n "$NOMAD_SCRAPE_TOKEN"    ]] && token_vars+=(-var="nomad_scrape_token=$NOMAD_SCRAPE_TOKEN")
    [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] && token_vars+=(-var="consul_token=$CONSUL_HTTP_TOKEN")

    nomad job run "${token_vars[@]}" "$INFRA_DIR/prometheus/job.nomad.hcl"

    log_success "Prometheus job submitted"

    # Wait for prometheus to be running
    log_info "Waiting for Prometheus allocation to be running..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        local status
        status=$(nomad job status prometheus 2>/dev/null | grep -c "running" || echo "0")
        if [[ "$status" -gt 0 ]]; then
            log_success "Prometheus running"
            break
        fi
        sleep 5
        ((attempt++))
    done
}

#------------------------------------------------------------------------------
# STEP 4: Deploy Grafana
#------------------------------------------------------------------------------
deploy_grafana() {
    log_info "=== STEP 4: Deploying Grafana ==="

    # Resolve the node where Prometheus was allocated so Grafana can reach it.
    # Prometheus uses host network on port 9090, so we need the node's IP.
    local prometheus_node_ip
    prometheus_node_ip=$(nomad job status -json prometheus \
        | jq -r '[.Allocations[] | select(.ClientStatus == "running")][0].NodeID' \
        | xargs nomad node status -json \
        | jq -r '.Attributes["unique.network.ip-address"]')

    if [[ -z "$prometheus_node_ip" || "$prometheus_node_ip" == "null" ]]; then
        log_warn "Could not resolve Prometheus node IP — using first node IP as fallback"
        prometheus_node_ip=$(aws ec2 describe-instances \
            | jq -r '.Reservations[].Instances[] | select(.State.Name == "running") | .PrivateIpAddress' \
            | head -1)
    fi

    local prometheus_addr="http://${prometheus_node_ip}:9090"
    log_info "Prometheus address for Grafana datasource: $prometheus_addr"

    nomad job run \
        -var="admin_password=$GRAFANA_ADMIN_PASSWORD" \
        -var="prometheus_addr=$prometheus_addr" \
        "$INFRA_DIR/grafana/job.nomad.hcl"

    log_success "Grafana job submitted"
}

#------------------------------------------------------------------------------
# STEP 5: Save token info (only when ACL tokens were created)
#------------------------------------------------------------------------------
save_tokens() {
    if [[ -z "$NOMAD_SCRAPE_TOKEN" ]]; then
        log_info "=== STEP 5: No tokens to save (ACL not enforced) ==="
        return
    fi

    log_info "=== STEP 5: Saving token info ==="

    mkdir -p "$ACL_DIR"
    cat > "$MONITORING_TOKENS_FILE" <<EOF
# Monitoring tokens — generated by setup_monitoring.sh
# DO NOT COMMIT — this file is gitignored

NOMAD_SCRAPE_TOKEN=$NOMAD_SCRAPE_TOKEN
EOF

    log_success "Tokens saved to $MONITORING_TOKENS_FILE"
}

#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  Nomad Cluster Monitoring Setup"
    echo "=============================================="
    echo ""

    check_prerequisites
    prompt_grafana_password
    discover_nodes
    configure_nodes
    create_nomad_token
    deploy_prometheus
    deploy_grafana
    save_tokens

    echo ""
    echo "=============================================="
    log_success "Monitoring setup complete!"
    echo "=============================================="
    echo ""
    echo "Grafana:"
    for node in "${NODES[@]}"; do
        echo "  http://${node}:3000  (login: admin / <password you entered>)"
    done
    echo ""
    echo "Prometheus:"
    for node in "${NODES[@]}"; do
        echo "  http://${node}:9090"
    done
    echo ""
    echo "Next: import dashboard 10902 in Grafana"
    echo "  Grafana → Dashboards → Import → ID 10902"
    echo ""
    echo "Check status:"
    echo "  nomad job status prometheus"
    echo "  nomad job status grafana"
    echo "  curl -s http://<node-ip>:9090/api/v1/targets | jq '.data.activeTargets[].health'"
}

main "$@"
