#!/usr/bin/bash
set -euo pipefail

# Add client-only nodes to an existing Nomad cluster.
# Creates EC2 instances, installs Consul + Nomad (client mode), registers with ALB.
# Requires: aws-cli, jq, SSH key at ~/workspace/nomad/nomad-keypair.pem
# Usage: ./add_client_nodes.sh [count]  (default: 1)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/workspace/nomad/nomad-keypair.pem}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
TARGET_GROUP_NAME="nomad-target-group"
TARGET_PORT=8081
GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws"

COUNT="${1:-1}"

# Check dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }
[[ -f "$SSH_KEY" ]] || { echo "Error: SSH key not found at $SSH_KEY"; exit 1; }

# Get existing server nodes
echo "Getting existing cluster nodes..."
SERVER_NODES=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=nomad1,nomad2,nomad3" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].PublicDnsName' --output text | tr '\t' ' ')

if [[ -z "$SERVER_NODES" ]]; then
    echo "Error: No existing nomad server nodes found (nomad1, nomad2, nomad3)"
    exit 1
fi
echo "Server nodes: $SERVER_NODES"

# Determine next client number
EXISTING_CLIENTS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=nomad-client*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].Tags[?Key==`Name`].Value' --output text | wc -w || echo "0")
START_NUM=$((EXISTING_CLIENTS + 1))
echo "Creating $COUNT client node(s) starting from nomad-client$START_NUM..."

# Create instances
INSTANCE_IDS=()
for i in $(seq "$START_NUM" $((START_NUM + COUNT - 1))); do
    name="nomad-client$i"
    echo "Creating $name..."

    result=$(aws ec2 run-instances \
        --image-id 'ami-0191d47ba10441f0b' \
        --instance-type 't3.micro' \
        --key-name 'nomad-keypair' \
        --network-interfaces '{"SubnetId":"subnet-3ee53954","AssociatePublicIpAddress":true,"DeviceIndex":0,"Groups":["sg-07fee22cbcdad4c58","sg-09aa7199da65ed0e3","sg-0beaa6c98d73ebd3b","sg-08e51d2a581377e0b","sg-77476f14"]}' \
        --credit-specification '{"CpuCredits":"unlimited"}' \
        --tag-specifications '{"ResourceType":"instance","Tags":[{"Key":"Name","Value":"'"$name"'"},{"Key":"Role","Value":"nomad-client"}]}' \
        --metadata-options '{"HttpEndpoint":"enabled","HttpPutResponseHopLimit":2,"HttpTokens":"required"}' \
        --private-dns-name-options '{"HostnameType":"ip-name","EnableResourceNameDnsARecord":false,"EnableResourceNameDnsAAAARecord":false}' \
        --count '1')

    echo "$result" >> /tmp/aws_create_instances.log
    instance_id=$(echo "$result" | jq -r '.Instances[0].InstanceId')
    INSTANCE_IDS+=("$instance_id")
    echo "Created $name: $instance_id"
done

echo "Waiting for instances to be running..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}"

# Get DNS names
CLIENT_DNS=()
for instance_id in "${INSTANCE_IDS[@]}"; do
    dns=$(aws ec2 describe-instances --instance-ids "$instance_id" \
        | jq -r '.Reservations[0].Instances[0].PublicDnsName')
    CLIENT_DNS+=("$dns")
    echo "Instance $instance_id: $dns"
done

# Wait for SSH
echo "Waiting for SSH..."
for dns in "${CLIENT_DNS[@]}"; do
    while ! ssh $SSH_OPTS -i "$SSH_KEY" ec2-user@"$dns" "echo ok" &>/dev/null; do
        echo -n "."
        sleep 5
    done
    echo " $dns ready"
done

# Install Consul + Nomad (client-only) on each node
echo "Installing Consul and Nomad on client nodes..."
for dns in "${CLIENT_DNS[@]}"; do
    echo "Installing on $dns..."
    ssh $SSH_OPTS -i "$SSH_KEY" ec2-user@"$dns" \
        "curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_consul_client.sh | bash -s -- $SERVER_NODES" &
done
wait

for dns in "${CLIENT_DNS[@]}"; do
    echo "Installing Nomad on $dns..."
    ssh $SSH_OPTS -i "$SSH_KEY" ec2-user@"$dns" \
        "curl --proto '=https' --tlsv1.2 -sSf $GITHUB_RAW_BASE/bin/instance/setup_nomad_client.sh | ADD_USER_TO_DOCKER=yes bash -s -- $SERVER_NODES" &
done
wait

# Register with target group
echo "Registering instances with target group..."
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")

if [[ -n "$TARGET_GROUP_ARN" && "$TARGET_GROUP_ARN" != "None" ]]; then
    targets=""
    for instance_id in "${INSTANCE_IDS[@]}"; do
        targets+="Id=${instance_id},Port=${TARGET_PORT} "
    done
    aws elbv2 register-targets --target-group-arn "$TARGET_GROUP_ARN" --targets $targets
    echo "Registered ${#INSTANCE_IDS[@]} instances with target group"
else
    echo "Warning: Target group $TARGET_GROUP_NAME not found, skipping registration"
fi

echo ""
echo "=============================================="
echo "  Done. Created $COUNT client node(s)"
echo "=============================================="
echo ""
echo "SSH to server nodes:"
for node in $SERVER_NODES; do
    echo "  ssh -o StrictHostKeyChecking=accept-new -i $SSH_KEY ec2-user@$node"
done
echo ""
echo "SSH to client nodes:"
for i in "${!CLIENT_DNS[@]}"; do
    echo "  ssh -o StrictHostKeyChecking=accept-new -i $SSH_KEY ec2-user@${CLIENT_DNS[$i]}"
done
echo ""
ALB_DNS=$(aws elbv2 describe-load-balancers --names nomad-alb --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")
if [[ -n "$ALB_DNS" && "$ALB_DNS" != "None" ]]; then
    echo "ALB DNS: $ALB_DNS"
    echo ""
fi
FIRST_SERVER=$(echo "$SERVER_NODES" | awk '{print $1}')
echo "UIs:"
echo "  Nomad:  http://$FIRST_SERVER:4646"
echo "  Consul: http://$FIRST_SERVER:8500"
echo ""
echo "Verify commands:"
echo "  nomad node status                    # Show all nodes (run from any server)"
echo "  consul members                       # Show Consul cluster members"
echo "  nomad node status -self              # Run on client node to check self"
echo "  journalctl -u nomad.service -f       # Follow Nomad logs on client node"
echo "  journalctl -u consul.service -f      # Follow Consul logs on client node"
