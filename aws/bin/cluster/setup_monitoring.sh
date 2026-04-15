#!/bin/bash
set -euo pipefail

# Opt-in monitoring setup for an existing Nomad cluster.
# Deploys Prometheus and Grafana as Nomad jobs.
#
# Idempotent: safe to re-run. Prometheus metrics data and Grafana dashboards persist on
# EFS across re-deploys. Grafana users also persist — tech users are not re-created if
# they already exist. The Grafana admin password is only set on first init; re-running
# with a different password has no effect (change it via the Grafana UI/API).
# Prometheus has no basic auth — access is enforced by Consul Connect intentions.
# Nomad's /v1/metrics endpoint is public and does not require an ACL token.
#
# Prerequisites:
#   - Cluster is running (ACL enforced or not — both work)
#   - SSH_KEY points to the EC2 keypair (default: ~/workspace/nomad/nomad-keypair.pem)
#   - NOMAD_TOKEN set if Nomad ACL is enforced
#   - CONSUL_HTTP_TOKEN set if Consul ACL is enforced
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

    [[ -f "$SSH_KEY" ]] || { log_error "SSH key not found at $SSH_KEY"; exit 1; }

    command -v aws &>/dev/null || { log_error "aws-cli required"; exit 1; }
    command -v jq  &>/dev/null || { log_error "jq required";      exit 1; }

    # Probe ACL state from the first node and require tokens if enforced.
    local nomad_status consul_status
    nomad_status=$(ssh_exec "$FIRST_NODE" \
        "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:4646/v1/jobs")
    # GET /v1/acl/tokens requires acl:read — always protected when Consul ACL is enabled.
    consul_status=$(ssh_exec "$FIRST_NODE" \
        "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://localhost:8500/v1/acl/tokens")

    if [[ "$nomad_status" == "403" ]]; then
        [[ -n "${NOMAD_TOKEN:-}" ]] || { log_error "Nomad ACL is enforced — NOMAD_TOKEN must be set"; exit 1; }
        # Verify the token is valid (not just non-empty)
        local nomad_verify
        nomad_verify=$(ssh_exec "$FIRST_NODE" \
            "curl -s -o /dev/null -w '%{http_code}' -H 'X-Nomad-Token: ${NOMAD_TOKEN}' http://localhost:4646/v1/jobs")
        [[ "$nomad_verify" == "200" ]] || { log_error "NOMAD_TOKEN is set but rejected by Nomad (HTTP $nomad_verify) — check the token SecretID"; exit 1; }
        log_info "Nomad ACL enforced — token verified"
    else
        log_info "Nomad ACL not enforced"
    fi

    if [[ "$consul_status" == "403" ]]; then
        [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { log_error "Consul ACL is enforced — CONSUL_HTTP_TOKEN must be set"; exit 1; }
        # Verify the token is valid (not just non-empty)
        local consul_verify
        consul_verify=$(ssh_exec "$FIRST_NODE" \
            "curl -s -o /dev/null -w '%{http_code}' -H 'X-Consul-Token: ${CONSUL_HTTP_TOKEN}' http://localhost:8500/v1/agent/self")
        [[ "$consul_verify" == "200" ]] || { log_error "CONSUL_HTTP_TOKEN is set but rejected by Consul (HTTP $consul_verify) — check the token SecretID"; exit 1; }
        log_info "Consul ACL enforced — token verified"
    else
        log_info "Consul ACL not enforced"
    fi

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
    [[ ${#value} -ge 8 ]] || { log_error "Password must be at least 8 characters (Grafana policy)"; exit 1; }
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
    local recovered=false
    for i in $(seq 1 15); do
        if ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad server members | { grep -q alive || true; }"; then
            log_success "Nomad cluster healthy"
            recovered=true
            break
        fi
        sleep 3
    done
    [[ "$recovered" == "true" ]] || log_warn "Nomad cluster may not be fully recovered — check 'nomad server members'"
}

#------------------------------------------------------------------------------
# STEP 2: Apply Consul config entries for Prometheus and Grafana
#------------------------------------------------------------------------------
apply_consul_config() {
    log_info "=== STEP 2: Applying Consul config entries ==="

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
        ssh_exec "$FIRST_NODE" "CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN:-} consul config write $file"
        log_info "Applied $file"
    done

    log_success "Consul config entries applied"

    # Restart api-gateway so Envoy picks up the new routes via xDS.
    # An alloc started before ACL bootstrap has no NWI token — Consul rejects its xDS stream
    # in enforce mode, so newly written config entries never reach it until it is restarted.
    log_info "Restarting api-gateway to pick up new routes..."
    ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job stop api-gateway || true"
    ssh_exec "$FIRST_NODE" "mkdir -p infrastructure/api-gateway && wget -qO infrastructure/api-gateway/job.nomad.hcl $GITHUB_RAW_BASE/infrastructure/api-gateway/job.nomad.hcl"
    ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job run infrastructure/api-gateway/job.nomad.hcl"
    log_success "api-gateway restarted"
}

#------------------------------------------------------------------------------
# STEP 3: Deploy Prometheus
#------------------------------------------------------------------------------
deploy_prometheus() {
    log_info "=== STEP 3: Deploying Prometheus ==="

    ssh_exec "$FIRST_NODE" "mkdir -p infrastructure/prometheus && wget -qO infrastructure/prometheus/job.nomad.hcl $GITHUB_RAW_BASE/infrastructure/prometheus/job.nomad.hcl"

    local consul_var=""
    [[ -n "${CONSUL_HTTP_TOKEN:-}" ]] && consul_var="-var=consul_token=$CONSUL_HTTP_TOKEN"

    ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job run $consul_var infrastructure/prometheus/job.nomad.hcl"
    log_success "Prometheus job submitted"

    # Wait for Prometheus to be running
    log_info "Waiting for Prometheus allocation to be running..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        local status
        status=$(ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job status prometheus | { grep -c running || true; }")
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

    ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job run -var-file=/tmp/grafana-vars.hcl infrastructure/grafana/job.nomad.hcl"
    ssh_exec "$FIRST_NODE" "rm -f /tmp/grafana-vars.hcl"

    log_success "Grafana job submitted"

    # Wait for the Nomad allocation to reach running state
    log_info "Waiting for Grafana allocation to be running..."
    local attempt=1
    while [[ $attempt -le 20 ]]; do
        local status
        status=$(ssh_exec "$FIRST_NODE" "NOMAD_TOKEN=${NOMAD_TOKEN:-} nomad job status grafana | { grep -c running || true; }")
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
        "curl -s -H 'X-Consul-Token: ${CONSUL_HTTP_TOKEN:-}' http://localhost:8500/v1/catalog/service/grafana | jq -r '.[0].ServicePort'" | tr -d '[:space:]')
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
# STEP 5: Create Grafana tech users via API
#------------------------------------------------------------------------------
create_grafana_users() {
    log_info "=== STEP 5: Creating Grafana tech users ==="

    # All passwords are base64-encoded to avoid shell expansion of $ over SSH.
    local admin_b64 tech_admin_b64 tech_editor_b64 tech_viewer_b64
    admin_b64=$(printf '%s'       "$GRAFANA_ADMIN_PASSWORD"       | base64)
    tech_admin_b64=$(printf '%s'  "$GRAFANA_TECH_ADMIN_PASSWORD"  | base64)
    tech_editor_b64=$(printf '%s' "$GRAFANA_TECH_EDITOR_PASSWORD" | base64)
    tech_viewer_b64=$(printf '%s' "$GRAFANA_TECH_VIEWER_PASSWORD" | base64)

    ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${FIRST_NODE}" python3 - <<PYEOF
import base64, urllib.request, urllib.error, json, sys

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
        body = e.read().decode()
        print('User %s: HTTP %d — %s' % (login, e.code, body), file=sys.stderr)
PYEOF
    [[ $? -eq 0 ]] || { log_error "Grafana user creation script failed"; exit 1; }
}

#------------------------------------------------------------------------------
# STEP 6: Save credentials
#------------------------------------------------------------------------------
save_credentials() {
    log_info "=== STEP 6: Saving credentials ==="

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

    discover_nodes
    check_prerequisites
    prompt_passwords
    configure_nodes
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
