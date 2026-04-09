#!/bin/bash
set -euo pipefail

# Opt-in monitoring setup for an existing Nomad cluster.
# Deploys Prometheus and Grafana as Nomad jobs.
#
# Idempotent: safe to re-run. Prometheus metrics data and Grafana dashboards persist on
# EFS across re-deploys. Grafana users also persist — tech users are not re-created if
# they already exist. The Grafana admin password is only set on first init; re-running
# with a different password has no effect (change it via the Grafana UI/API).
# Prometheus has no basic auth configured — access is enforced by Consul Connect intentions.
#
# Prerequisites:
#   - Cluster is running (ACL enforced or not — both work)
#   - NOMAD_ADDR is set (NOMAD_TOKEN only needed when Nomad ACL is enforced)
#   - CONSUL_HTTP_ADDR is set (CONSUL_HTTP_TOKEN only needed when Consul ACL is enforced)
#   - SSH_KEY points to the EC2 keypair (default: ~/workspace/nomad/nomad-keypair.pem)
#
# Usage: ./setup_monitoring.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACL_DIR="$SCRIPT_DIR/../../acl"
SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"

# Credentials output file (gitignored)
MONITORING_TOKENS_FILE="$ACL_DIR/monitoring-credentials.txt"

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

ssh_exec() {
    local node="$1"; shift
    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${node}" "$@"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    [[ -n "${NOMAD_ADDR:-}"       ]] || { log_error "NOMAD_ADDR is not set (e.g. export NOMAD_ADDR=http://ec2-1-2-3-4.eu-central-1.compute.amazonaws.com:4646)";       exit 1; }
    [[ -n "${CONSUL_HTTP_ADDR:-}" ]] || { log_error "CONSUL_HTTP_ADDR is not set (e.g. export CONSUL_HTTP_ADDR=http://ec2-1-2-3-4.eu-central-1.compute.amazonaws.com:8500)"; exit 1; }
    [[ -f "$SSH_KEY"              ]] || { log_error "SSH key not found at $SSH_KEY"; exit 1; }
    # NOMAD_TOKEN and CONSUL_HTTP_TOKEN are optional — only required when ACL is enforced

    command -v aws &>/dev/null || { log_error "aws-cli required"; exit 1; }
    command -v jq  &>/dev/null || { log_error "jq required";      exit 1; }

    log_success "Prerequisites OK"
}

# Prompt for a password, accepting it from env or interactively
prompt_password() {
    local var_name="$1"
    local prompt_text="$2"

    if [[ -n "${!var_name:-}" ]]; then
        log_info "Using $var_name from environment"
        return
    fi

    echo ""
    read -rsp "$prompt_text: " value
    echo ""
    [[ -n "$value" ]] || { log_error "Password cannot be empty"; exit 1; }
    export "$var_name"="$value"
}

# Prompt for all passwords
prompt_passwords() {
    log_info "=== Passwords ==="
    prompt_password GRAFANA_ADMIN_PASSWORD       "Enter Grafana admin password"
    prompt_password GRAFANA_TECH_ADMIN_PASSWORD  "Enter Grafana tech-admin password  (Admin role)"
    prompt_password GRAFANA_TECH_EDITOR_PASSWORD "Enter Grafana tech-editor password (Editor role)"
    prompt_password GRAFANA_TECH_VIEWER_PASSWORD "Enter Grafana tech-viewer password (Viewer role)"
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
    FIRST_NODE="${NODES[0]}"
}

#------------------------------------------------------------------------------
# STEP 1: Run setup_nomad_monitoring.sh on every node (rolling)
#------------------------------------------------------------------------------
configure_nodes() {
    log_info "=== STEP 1: Configuring nodes (telemetry + host volumes) ==="

    for node in "${NODES[@]}"; do
        log_info "Configuring $node..."
        ssh_exec "$node" "curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_nomad_monitoring.sh | bash"
        log_success "$node configured"
    done

    # Wait for Nomad leader to be elected after rolling restarts
    log_info "Waiting for Nomad cluster to recover..."
    for i in $(seq 1 15); do
        if ssh_exec "$FIRST_NODE" "nomad server members | { grep -q alive || true; }"; then
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

    # Probe the metrics endpoint from the node — 403 means ACL is enforcing deny.
    # Run via SSH so the probe always works regardless of whether port 4646 is
    # open to the local machine in the security group.
    local http_status
    http_status=$(ssh_exec "$FIRST_NODE" \
        "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:4646/v1/metrics?format=prometheus")

    if [[ "$http_status" == "403" ]]; then
        log_info "ACL is enforced (got 403) — creating metrics-scraper token"

        # Download policy file from GitHub and apply
        ssh_exec "$FIRST_NODE" "mkdir -p acl/nomad/policies && wget -qO acl/nomad/policies/metrics-scraper.policy.hcl $GITHUB_RAW_BASE/acl/nomad/policies/metrics-scraper.policy.hcl"
        ssh_exec "$FIRST_NODE" "nomad acl policy apply \
            -description 'Read-only policy for Prometheus metrics scraping' \
            metrics-scraper \
            acl/nomad/policies/metrics-scraper.policy.hcl"
        log_success "Policy 'metrics-scraper' applied"

        # Create token
        local token_output
        token_output=$(ssh_exec "$FIRST_NODE" "nomad acl token create \
            -name=prometheus-metrics-scraper \
            -policy=metrics-scraper \
            -type=client")

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
# STEP 3: Apply Consul config entries for Prometheus and Grafana
#------------------------------------------------------------------------------
apply_consul_config() {
    log_info "=== STEP 3: Applying Consul config entries ==="

    # Order matters: service-defaults must be applied before routes.
    local files=(
        "infrastructure/prometheus/defaults.consul.hcl"
        "infrastructure/grafana/defaults.consul.hcl"
        "infrastructure/prometheus/intentions.consul.hcl"
        "infrastructure/grafana/intentions.consul.hcl"
        "infrastructure/prometheus/route.consul.hcl"
        "infrastructure/grafana/route.consul.hcl"
    )

    for file in "${files[@]}"; do
        local dir
        dir=$(dirname "$file")
        ssh_exec "$FIRST_NODE" "mkdir -p $dir && wget -qO $file $GITHUB_RAW_BASE/$file"
        ssh_exec "$FIRST_NODE" "consul config write $file"
        log_info "Applied $file"
    done

    log_success "Consul config entries applied"
}

#------------------------------------------------------------------------------
# STEP 4: Deploy Prometheus
#------------------------------------------------------------------------------
deploy_prometheus() {
    log_info "=== STEP 4: Deploying Prometheus ==="

    ssh_exec "$FIRST_NODE" "mkdir -p infrastructure/prometheus && wget -qO infrastructure/prometheus/job.nomad.hcl $GITHUB_RAW_BASE/infrastructure/prometheus/job.nomad.hcl"

    local token_vars=""
    [[ -n "$NOMAD_SCRAPE_TOKEN"    ]] && token_vars="$token_vars -var=nomad_scrape_token=$NOMAD_SCRAPE_TOKEN"
    [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] && token_vars="$token_vars -var=consul_token=$CONSUL_HTTP_TOKEN"

    ssh_exec "$FIRST_NODE" "nomad job run $token_vars infrastructure/prometheus/job.nomad.hcl"
    log_success "Prometheus job submitted"

    # Wait for Prometheus to be running
    log_info "Waiting for Prometheus allocation to be running..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        local status
        status=$(ssh_exec "$FIRST_NODE" "nomad job status prometheus | { grep -c running || true; }")
        if [[ "$status" -gt 0 ]]; then
            log_success "Prometheus running"
            break
        fi
        sleep 5
        ((attempt++))
    done
}

#------------------------------------------------------------------------------
# STEP 5: Deploy Grafana
#------------------------------------------------------------------------------
deploy_grafana() {
    log_info "=== STEP 5: Deploying Grafana ==="

    # Grafana reaches Prometheus via its Connect sidecar upstream (localhost:9091).

    ssh_exec "$FIRST_NODE" "mkdir -p infrastructure/grafana && wget -qO infrastructure/grafana/job.nomad.hcl $GITHUB_RAW_BASE/infrastructure/grafana/job.nomad.hcl"

    # Passwords are base64-encoded to avoid shell expansion of $ in password strings.
    local admin_b64 tech_admin_b64 tech_editor_b64 tech_viewer_b64
    admin_b64=$(printf '%s'       "$GRAFANA_ADMIN_PASSWORD"        | base64)
    tech_admin_b64=$(printf '%s'  "$GRAFANA_TECH_ADMIN_PASSWORD"   | base64)
    tech_editor_b64=$(printf '%s' "$GRAFANA_TECH_EDITOR_PASSWORD"  | base64)
    tech_viewer_b64=$(printf '%s' "$GRAFANA_TECH_VIEWER_PASSWORD"  | base64)

    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${FIRST_NODE}" python3 <<PYEOF
import base64
vals = {
    'admin_password':               base64.b64decode('${admin_b64}').decode(),
    'grafana_tech_admin_password':  base64.b64decode('${tech_admin_b64}').decode(),
    'grafana_tech_editor_password': base64.b64decode('${tech_editor_b64}').decode(),
    'grafana_tech_viewer_password': base64.b64decode('${tech_viewer_b64}').decode(),
}
with open('/tmp/grafana-vars.hcl', 'w') as f:
    for k, v in vals.items():
        f.write('%s = "%s"\n' % (k, v))
PYEOF

    ssh_exec "$FIRST_NODE" "nomad job run -var-file=/tmp/grafana-vars.hcl infrastructure/grafana/job.nomad.hcl"

    log_success "Grafana job submitted"

    # Wait for the Nomad allocation to reach running state
    log_info "Waiting for Grafana allocation to be running..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        local status
        status=$(ssh_exec "$FIRST_NODE" "nomad job status grafana | { grep -c running || true; }")
        if [[ "$status" -gt 0 ]]; then
            log_success "Grafana running"
            break
        fi
        sleep 5
        ((attempt++))
    done

    # In bridge mode the container port (3000) maps to a dynamic host port.
    # Discover the actual port from Consul so we can reach the HTTP API.
    log_info "Discovering Grafana host port via Consul..."
    local grafana_port
    grafana_port=$(ssh_exec "$FIRST_NODE" \
        "curl -s http://localhost:8500/v1/catalog/service/grafana | jq -r '.[0].ServicePort'")
    [[ -n "$grafana_port" && "$grafana_port" != "null" ]] \
        || { log_error "Could not discover Grafana port from Consul"; exit 1; }
    export GRAFANA_PORT="$grafana_port"
    log_info "Grafana reachable on port $GRAFANA_PORT"

    # Wait for Grafana HTTP to respond before user creation
    log_info "Waiting for Grafana to accept HTTP requests..."
    attempt=1
    while [[ $attempt -le 20 ]]; do
        local http_status
        http_status=$(ssh_exec "$FIRST_NODE" \
            "curl -s -o /dev/null -w '%{http_code}' http://localhost:${GRAFANA_PORT}/api/health")
        if [[ "$http_status" == "200" ]]; then
            log_success "Grafana HTTP ready"
            break
        fi
        sleep 5
        ((attempt++))
    done
}

#------------------------------------------------------------------------------
# STEP 6: Create Grafana tech users via API
#------------------------------------------------------------------------------
create_grafana_users() {
    log_info "=== STEP 6: Creating Grafana tech users ==="

    # All passwords are base64-encoded to avoid shell expansion of $ over SSH.
    local admin_b64 tech_admin_b64 tech_editor_b64 tech_viewer_b64
    admin_b64=$(printf '%s'       "$GRAFANA_ADMIN_PASSWORD"       | base64)
    tech_admin_b64=$(printf '%s'  "$GRAFANA_TECH_ADMIN_PASSWORD"  | base64)
    tech_editor_b64=$(printf '%s' "$GRAFANA_TECH_EDITOR_PASSWORD" | base64)
    tech_viewer_b64=$(printf '%s' "$GRAFANA_TECH_VIEWER_PASSWORD" | base64)

    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${FIRST_NODE}" python3 <<PYEOF
import base64, urllib.request, urllib.error, json

admin_pw = base64.b64decode('${admin_b64}').decode()
port     = ${GRAFANA_PORT}
users = [
    ('tech-admin',  'Tech Admin',  'Admin',  base64.b64decode('${tech_admin_b64}').decode()),
    ('tech-editor', 'Tech Editor', 'Editor', base64.b64decode('${tech_editor_b64}').decode()),
    ('tech-viewer', 'Tech Viewer', 'Viewer', base64.b64decode('${tech_viewer_b64}').decode()),
]

import base64 as _b64
auth = _b64.b64encode(('admin:' + admin_pw).encode()).decode()

for login, name, role, pw in users:
    payload = json.dumps({'login': login, 'name': name, 'password': pw, 'role': role}).encode()
    req = urllib.request.Request(
        'http://localhost:%d/api/admin/users' % port,
        data=payload,
        headers={'Content-Type': 'application/json', 'Authorization': 'Basic ' + auth},
        method='POST',
    )
    try:
        urllib.request.urlopen(req)
        print('Created user: %s' % login)
    except urllib.error.HTTPError as e:
        print('User %s: HTTP %d (may already exist)' % (login, e.code))
PYEOF
}

#------------------------------------------------------------------------------
# STEP 7: Save credentials
#------------------------------------------------------------------------------
save_credentials() {
    log_info "=== STEP 7: Saving credentials ==="

    mkdir -p "$ACL_DIR"
    # Use 'EOF' (quoted) to prevent shell expansion — passwords may contain $, !, backticks.
    # Write each variable with printf to safely handle special characters.
    cat > "$MONITORING_TOKENS_FILE" <<'EOF'
# Monitoring credentials — generated by setup_monitoring.sh
# DO NOT COMMIT — this file is gitignored

# Grafana users
# admin        (Grafana Admin)
# tech-admin   (Admin role)
# tech-editor  (Editor role)
# tech-viewer  (Viewer role)
EOF
    printf 'GRAFANA_ADMIN_PASSWORD=%s\n'        "$GRAFANA_ADMIN_PASSWORD"        >> "$MONITORING_TOKENS_FILE"
    printf 'GRAFANA_TECH_ADMIN_PASSWORD=%s\n'   "$GRAFANA_TECH_ADMIN_PASSWORD"   >> "$MONITORING_TOKENS_FILE"
    printf 'GRAFANA_TECH_EDITOR_PASSWORD=%s\n'  "$GRAFANA_TECH_EDITOR_PASSWORD"  >> "$MONITORING_TOKENS_FILE"
    printf 'GRAFANA_TECH_VIEWER_PASSWORD=%s\n'  "$GRAFANA_TECH_VIEWER_PASSWORD"  >> "$MONITORING_TOKENS_FILE"

    if [[ -n "$NOMAD_SCRAPE_TOKEN" ]]; then
        printf '\n# Nomad ACL\nNOMAD_SCRAPE_TOKEN=%s\n' "$NOMAD_SCRAPE_TOKEN" >> "$MONITORING_TOKENS_FILE"
    fi

    log_success "Credentials saved to $MONITORING_TOKENS_FILE"
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
    prompt_passwords
    discover_nodes
    configure_nodes
    create_nomad_token
    apply_consul_config
    deploy_prometheus
    deploy_grafana
    create_grafana_users
    save_credentials

    echo ""
    echo "=============================================="
    log_success "Monitoring setup complete!"
    echo "=============================================="
    echo ""
    echo "Access via API Gateway (hostname-based routing):"
    echo "  Grafana:    http://<alb-or-ingress>  -H 'Host: grafana.example.com'"
    echo "  Prometheus: http://<alb-or-ingress>  -H 'Host: prometheus.example.com'"
    echo ""
    echo "  Grafana users: admin, tech-admin (Admin), tech-editor (Editor), tech-viewer (Viewer)"
    echo "  Prometheus: no auth (access enforced by Consul Connect intentions)"
    echo ""
    echo "Check status (SSH to a node first):"
    echo "  nomad job status prometheus"
    echo "  nomad job status grafana"
    echo "  consul catalog services | grep -E 'prometheus|grafana'"
    echo "  # Prometheus port (bridge mode — dynamic): curl -s http://localhost:8500/v1/catalog/service/prometheus | jq '.[0].ServicePort'"
    echo "  curl -s -u admin:<password> http://localhost:<port>/api/v1/targets | jq '.data.activeTargets[].health'"
}

main "$@"
