#!/usr/bin/bash
set -euo pipefail

# Full cluster setup script for AWS Nomad cluster with Consul service mesh.
# Creates EC2 instances, installs Consul + Nomad, configures services, and creates ALB.
# Requires: aws-cli, jq, SSH key at ~/workspace/nomad/nomad-keypair.pem
# Usage: ./setup_cluster.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cluster"
SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
TARGET_GROUP_NAME="nomad-target-group"
ALB_NAME="nomad-alb"

# GitHub raw URL for setup scripts
GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    command -v aws &>/dev/null || { log_error "aws-cli required"; exit 1; }
    command -v jq &>/dev/null || { log_error "jq required"; exit 1; }
    command -v ssh &>/dev/null || { log_error "ssh required"; exit 1; }
    [[ -f "$SSH_KEY" ]] || { log_error "SSH key not found at $SSH_KEY"; exit 1; }
    log_success "All dependencies available"
}

# Wait for SSH to be available on an instance
wait_for_ssh() {
    local host="$1"
    local max_attempts=30
    local attempt=1

    log_info "Waiting for SSH on $host..."
    while [[ $attempt -le $max_attempts ]]; do
        if ssh $SSH_OPTS -i "$SSH_KEY" ec2-user@"$host" "echo ok" &>/dev/null; then
            log_success "SSH available on $host"
            return 0
        fi
        echo -n "."
        sleep 5
        ((attempt++))
    done
    log_error "SSH timeout for $host"
    return 1
}

# Run command on remote host
ssh_run() {
    local host="$1"
    shift
    ssh $SSH_OPTS -i "$SSH_KEY" ec2-user@"$host" "$@"
}

# Copy file to remote host
scp_to() {
    local file="$1"
    local host="$2"
    local dest="${3:-.}"
    scp $SSH_OPTS -i "$SSH_KEY" "$file" ec2-user@"$host":"$dest"
}

#------------------------------------------------------------------------------
# STEP 1: Create EC2 instances
#------------------------------------------------------------------------------
create_instances() {
    log_info "=== STEP 1: Creating EC2 instances ==="

    # Check if instances already exist
    existing=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=nomad1,nomad2,nomad3" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text)

    if [[ -n "$existing" ]]; then
        log_warn "Existing nomad instances found: $existing"
        read -p "Continue with existing instances? (y/N): " answer
        if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
            log_info "Aborting. Use terminate_instances.sh to clean up first."
            exit 1
        fi
    else
        log_info "Creating 3 EC2 instances..."
        "$SCRIPT_DIR/create_instances.sh"
    fi

    # Get public DNS names
    log_info "Fetching instance DNS names..."
    mapfile -t NODES < <("$SCRIPT_DIR/get_public_dns_names.sh")

    if [[ ${#NODES[@]} -ne 3 ]]; then
        log_error "Expected 3 instances, found ${#NODES[@]}"
        exit 1
    fi

    log_success "Instances created:"
    printf '  %s\n' "${NODES[@]}"

    # Export for later use
    export NODES
}

#------------------------------------------------------------------------------
# STEP 2: Wait for instances to be ready
#------------------------------------------------------------------------------
wait_for_instances() {
    log_info "=== STEP 2: Waiting for instances to be ready ==="

    for node in "${NODES[@]}"; do
        wait_for_ssh "$node"
    done

    log_success "All instances are accessible via SSH"
}

#------------------------------------------------------------------------------
# STEP 3: Install Consul on all nodes
#------------------------------------------------------------------------------
install_consul() {
    log_info "=== STEP 3: Installing Consul on all nodes (parallel) ==="

    # Build node arguments for setup script
    local node_args="${NODES[*]}"
    local pids=()

    for node in "${NODES[@]}"; do
        log_info "Starting Consul install on $node..."
        ssh_run "$node" "curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_consul_aws_ami.sh | bash -s -- $node_args" &
        pids+=($!)
    done

    # Wait for all parallel installs to complete
    local failed=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            log_success "Consul installed on ${NODES[$i]}"
        else
            log_error "Consul install failed on ${NODES[$i]}"
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed node(s) failed Consul installation"
        exit 1
    fi

    # Verify cluster formation with retry loop
    log_info "Waiting for Consul cluster to form..."
    local first_node="${NODES[0]}"
    local members
    local attempt=1
    local max_attempts=5  # 5 attempts * 2 seconds = 10 seconds

    while [[ $attempt -le $max_attempts ]]; do
        members=$(ssh_run "$first_node" "consul members" 2>/dev/null || true)
        if echo "$members" | grep -q "alive"; then
            log_success "Consul cluster formed:"
            echo "$members"
            return 0
        fi
        log_info "Attempt $attempt/$max_attempts: Waiting for Consul cluster..."
        sleep 2
        ((attempt++))
    done

    log_warn "Consul cluster may not be fully formed yet. Check manually with: consul members"
}

#------------------------------------------------------------------------------
# STEP 4: Install Nomad on all nodes
#------------------------------------------------------------------------------
install_nomad() {
    log_info "=== STEP 4: Installing Nomad on all nodes (parallel) ==="

    # Build node arguments for setup script
    local node_args="${NODES[*]}"
    local pids=()

    for node in "${NODES[@]}"; do
        log_info "Starting Nomad install on $node..."
        # Using ADD_USER_TO_DOCKER=yes for non-interactive mode
        ssh_run "$node" "export ADD_USER_TO_DOCKER=yes && curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_nomad_aws_ami.sh | bash -s -- $node_args" &
        pids+=($!)
    done

    # Wait for all parallel installs to complete
    local failed=0
    for i in "${!pids[@]}"; do
        if wait "${pids[$i]}"; then
            log_success "Nomad installed on ${NODES[$i]}"
        else
            log_error "Nomad install failed on ${NODES[$i]}"
            ((failed++))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        log_error "$failed node(s) failed Nomad installation"
        exit 1
    fi

    # Verify cluster formation with retry loop
    log_info "Waiting for Nomad cluster to form..."
    local first_node="${NODES[0]}"
    local members
    local attempt=1
    local max_attempts=5  # 5 attempts * 2 seconds = 10 seconds

    while [[ $attempt -le $max_attempts ]]; do
        members=$(ssh_run "$first_node" "nomad server members" 2>/dev/null || true)
        if echo "$members" | grep -q "alive"; then
            log_success "Nomad cluster formed:"
            echo "$members"
            return 0
        fi
        log_info "Attempt $attempt/$max_attempts: Waiting for Nomad cluster..."
        sleep 2
        ((attempt++))
    done

    log_warn "Nomad cluster may not be fully formed yet. Check manually with: nomad server members"
}

#------------------------------------------------------------------------------
# STEP 5: Configure Consul (service-defaults, router, ingress, intentions)
#------------------------------------------------------------------------------
configure_consul() {
    log_info "=== STEP 5: Configuring Consul service mesh ==="

    local first_node="${NODES[0]}"

    # Download Consul config files to first node from GitHub
    # Note: ingress-gateway routing is defined in the Nomad job,
    # not in a separate Consul config entry, to avoid conflicts
    log_info "Downloading Consul config files to $first_node..."
    local consul_files=(
        "services/web-service/defaults.consul.hcl"
        "services/business-service/defaults.consul.hcl"
        "services/business-service-api/defaults.consul.hcl"
        "services/business-service/router.consul.hcl"
        "services/web-service/intentions.consul.hcl"
    )
    for file in "${consul_files[@]}"; do
        local dir=$(dirname "$file")
        local basename=$(basename "$file")
        ssh_run "$first_node" "mkdir -p $dir && wget -q -O $file $GITHUB_RAW_BASE/$file"
    done

    # Apply Consul configurations
    log_info "Applying Consul config entries..."
    for file in "${consul_files[@]}"; do
        log_info "Writing $file..."
        if ! ssh_run "$first_node" "consul config write $file"; then
            log_error "Failed to write $file"
            exit 1
        fi
    done

    log_success "Consul configurations applied"

    # Verify
    log_info "Verifying Consul configurations..."
    ssh_run "$first_node" "consul config read -kind service-defaults -name web-service" || log_warn "web-service defaults not found"
    ssh_run "$first_node" "consul config read -kind service-defaults -name business-service" || log_warn "business-service defaults not found"
    log_success "Consul service configurations verified"
    # Note: ingress-gateway config is created when the Nomad job runs (Step 6)
}

#------------------------------------------------------------------------------
# STEP 6: Run Nomad jobs
#------------------------------------------------------------------------------
run_nomad_jobs() {
    log_info "=== STEP 6: Running Nomad jobs ==="

    local first_node="${NODES[0]}"

    # Nomad job files (order matters: traefik first, then ingress, then services)
    local nomad_jobs=(
        "infrastructure/traefik-rewrite/job.nomad.hcl"
        "infrastructure/ingress-gateway/job.nomad.hcl"
        "services/web-service/job.nomad.hcl"
        "services/business-service/job.nomad.hcl"
    )

    # Download Nomad job files from GitHub
    log_info "Downloading Nomad job files to $first_node..."
    for file in "${nomad_jobs[@]}"; do
        local dir=$(dirname "$file")
        ssh_run "$first_node" "mkdir -p $dir && wget -q -O $file $GITHUB_RAW_BASE/$file"
    done

    # Run jobs in order
    log_info "Running Nomad jobs..."
    for file in "${nomad_jobs[@]}"; do
        local name=$(basename $(dirname "$file"))
        log_info "Starting $name..."
        ssh_run "$first_node" "nomad job run $file"
        sleep 5
    done

    # Verify jobs
    log_info "Checking job status..."
    ssh_run "$first_node" "nomad status"

    # Verify ingress gateway config was created by Nomad job
    log_info "Verifying ingress-gateway configuration..."
    local ingress_config
    ingress_config=$(ssh_run "$first_node" "consul config read -kind ingress-gateway -name ingress-gateway" 2>/dev/null || echo "")
    if [[ -z "$ingress_config" ]]; then
        log_error "ingress-gateway config not found after running Nomad job"
        exit 1
    fi
    if ! echo "$ingress_config" | grep -q "business-service"; then
        log_error "ingress-gateway config is missing business-service!"
        log_error "Config content:"
        echo "$ingress_config"
        exit 1
    fi
    log_success "ingress-gateway config verified (includes business-service)"

    log_success "Nomad jobs started"
}

#------------------------------------------------------------------------------
# STEP 7: Test internal routing
#------------------------------------------------------------------------------
test_internal_routing() {
    log_info "=== STEP 7: Testing internal routing ==="

    local first_node="${NODES[0]}"

    log_info "Waiting for services to be ready..."
    sleep 15

    log_info "Testing web-service (default route)..."
    local result
    result=$(ssh_run "$first_node" "curl -s http://localhost:8081/" 2>/dev/null || echo "FAILED")
    if echo "$result" | grep -q "hello world"; then
        log_success "Web service: OK - $result"
    else
        log_warn "Web service test failed: $result"
    fi

    log_info "Testing business-service (Host header)..."
    result=$(ssh_run "$first_node" "curl -sH 'Host: business-service' http://localhost:8081/ | grep -o 'Name: business-service' || echo 'NOT FOUND'" 2>/dev/null)
    if echo "$result" | grep -q "business-service"; then
        log_success "Business service: OK"
    else
        log_warn "Business service test: $result"
    fi

    log_info "Testing legacy API route..."
    result=$(ssh_run "$first_node" "curl -sH 'Host: business-service' http://localhost:8081/legacy-business-service/test | grep -o 'Name: business-service-api' || echo 'NOT FOUND'" 2>/dev/null)
    if echo "$result" | grep -q "business-service-api"; then
        log_success "Legacy API route: OK"
    else
        log_warn "Legacy API route test: $result"
    fi

    log_info "Testing URL rewrite (download)..."
    result=$(ssh_run "$first_node" "curl -L -sH 'Host: business-service' http://localhost:8081/download/testtoken123 | grep -o 'token=testtoken123' || echo 'NOT FOUND'" 2>/dev/null)
    if echo "$result" | grep -q "token=testtoken123"; then
        log_success "URL rewrite: OK"
    else
        log_warn "URL rewrite test: $result"
    fi
}

#------------------------------------------------------------------------------
# STEP 8: Create AWS Load Balancer
#------------------------------------------------------------------------------
create_load_balancer() {
    log_info "=== STEP 8: Creating AWS Load Balancer ==="

    # Check if target group exists
    local existing_tg
    existing_tg=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" 2>/dev/null | jq -r '.TargetGroups[0].TargetGroupArn' || echo "")

    if [[ -n "$existing_tg" && "$existing_tg" != "null" ]]; then
        log_warn "Target group $TARGET_GROUP_NAME already exists"
        TARGET_GROUP_ARN="$existing_tg"
    else
        log_info "Creating target group..."
        "$SCRIPT_DIR/create_target_group.sh" "$TARGET_GROUP_NAME"
        TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)
    fi

    # Check if ALB exists
    local existing_alb
    existing_alb=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" 2>/dev/null | jq -r '.LoadBalancers[0].LoadBalancerArn' || echo "")

    if [[ -n "$existing_alb" && "$existing_alb" != "null" ]]; then
        log_warn "ALB $ALB_NAME already exists"
        ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
    else
        log_info "Creating Application Load Balancer..."
        "$SCRIPT_DIR/create_alb.sh" "$TARGET_GROUP_ARN" "$ALB_NAME"
        ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
    fi

    log_success "ALB DNS: $ALB_DNS"
    export ALB_DNS
}

#------------------------------------------------------------------------------
# STEP 9: Wait for targets and test ALB
#------------------------------------------------------------------------------
wait_and_test_alb() {
    log_info "=== STEP 9: Waiting for targets to be healthy ==="

    TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text)

    local max_attempts=75
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        local health
        health=$(aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" \
            --query 'TargetHealthDescriptions[*].TargetHealth.State' --output text)

        if echo "$health" | grep -q "healthy"; then
            log_success "At least one target is healthy"
            break
        fi

        log_info "Attempt $attempt/$max_attempts: Waiting for targets... ($health)"
        sleep 4
        ((attempt++))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        log_warn "Timeout waiting for healthy targets"
    fi

    # Test ALB
    log_info "Testing ALB endpoints..."
    ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)

    log_info "Testing default route..."
    local result
    result=$(curl -s "http://$ALB_DNS/" 2>/dev/null || echo "FAILED")
    if echo "$result" | grep -q "hello world"; then
        log_success "ALB default route: OK"
    else
        log_warn "ALB default route: $result"
    fi

    log_info "Testing business-service via ALB..."
    result=$(curl -sH "Host: business-service" "http://$ALB_DNS/" | grep -o "Name: business-service" || echo "NOT FOUND")
    if echo "$result" | grep -q "business-service"; then
        log_success "ALB business-service: OK"
    else
        log_warn "ALB business-service: $result"
    fi
}

#------------------------------------------------------------------------------
# STEP 10: Download demo files (not run automatically)
#------------------------------------------------------------------------------
download_demo_files() {
    log_info "=== STEP 10: Downloading demo files ==="

    local first_node="${NODES[0]}"

    # Shell scripts for manual testing
    local scripts=(
        rolling_update.sh
        canary_update.sh
        sensitive_service.sh
        node_drain.sh
    )
    log_info "Downloading shell scripts to $first_node..."
    for file in "${scripts[@]}"; do
        ssh_run "$first_node" "wget -q -O $file $GITHUB_RAW_BASE/bin/instance/$file && chmod +x $file"
    done

    log_success "Demo files downloaded"
}

#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  AWS Nomad Cluster Setup"
    echo "=============================================="
    echo ""

    check_dependencies
    create_instances
    wait_for_instances
    install_consul
    install_nomad
    configure_consul
    run_nomad_jobs
    test_internal_routing
    create_load_balancer
    wait_and_test_alb
    download_demo_files

    echo ""
    echo "=============================================="
    log_success "Cluster setup complete!"
    echo "=============================================="
    echo ""
    echo "Instance DNS names:"
    printf '  %s\n' "${NODES[@]}"
    echo ""
    echo "ALB DNS: $ALB_DNS"
    echo ""
    echo "Test commands:"
    echo "  curl http://$ALB_DNS/"
    echo "  curl -sH 'Host: business-service' http://$ALB_DNS/ | grep Name"
    echo "  curl -L -sH 'Host: business-service' http://$ALB_DNS/download/mytoken123 | grep -E '(Name|GET)'"
    echo ""
    echo "SSH to nodes:"
    for i in "${!NODES[@]}"; do
        echo "  Node #$((i+1)): ssh -o StrictHostKeyChecking=accept-new -i $SSH_KEY ec2-user@${NODES[$i]}"
    done
    echo ""
    echo "UIs:"
    echo "  Nomad:  http://${NODES[0]}:4646"
    echo "  Consul: http://${NODES[0]}:8500"
}

main "$@"
