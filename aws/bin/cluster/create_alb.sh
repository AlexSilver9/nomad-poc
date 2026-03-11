#!/bin/bash
set -euo pipefail

# Create an AWS Application Load Balancer (ALB) for the Nomad ingress gateway.
# Listens on HTTP:80, forwards to a single target group (nginx HTTP:8081).
# Used for basic POC testing without a domain or ACM certificate.
#
# For production (HTTPS end-to-end), use create_alb_https.sh instead.
#
# Requires: aws-cli, jq
# Usage: ./create_alb.sh <target-group-arn> [alb-name]

# Check executable dependencies
command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

# Check required arguments
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <target-group-arn> [alb-name]"
    echo ""
    echo "Example:"
    echo "  $0 arn:aws:elasticloadbalancing:eu-central-1:123456789:targetgroup/nomad-target-group/abc123"
    echo ""
    echo "To get target group ARN:"
    echo "  aws elbv2 describe-target-groups --names nomad-target-group --query 'TargetGroups[0].TargetGroupArn' --output text"
    exit 1
fi

# Configuration
TARGET_GROUP_ARN="$1"
ALB_NAME="${2:-nomad-alb}"

# Subnets (need at least 2 in different AZs for ALB), these should be public subnets in the VPC
SUBNETS="subnet-3ee53954 subnet-5eafa423"

# Security groups (default, SSH, HTTPS, HTTP, NOMAD-CONSUL)
SECURITY_GROUPS="sg-77476f14 sg-07fee22cbcdad4c58 sg-0beaa6c98d73ebd3b sg-09aa7199da65ed0e3 sg-08e51d2a581377e0b"

echo "Creating Application Load Balancer: ${ALB_NAME}"

# Create ALB
result=$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets ${SUBNETS} \
    --security-groups ${SECURITY_GROUPS} \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4)

ALB_ARN=$(echo "$result" | jq -r '.LoadBalancers[0].LoadBalancerArn')
ALB_DNS=$(echo "$result" | jq -r '.LoadBalancers[0].DNSName')

echo "Created ALB: ${ALB_ARN}"
echo "DNS Name:    ${ALB_DNS}"

# Create listener on port 80
echo "Creating http listener on default port 80..."
listener_result=$(aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TARGET_GROUP_ARN}")

LISTENER_ARN=$(echo "$listener_result" | jq -r '.Listeners[0].ListenerArn')
echo "Created listener: ${LISTENER_ARN}"

echo ""
echo "Done"
echo ""
echo "ALB DNS Name: ${ALB_DNS}"
echo "ALB ARN:      ${ALB_ARN}"
echo "Listener ARN: ${LISTENER_ARN}"
echo ""
echo "Test (after targets are healthy):"
echo "  curl http://${ALB_DNS}/"
echo "  curl -H 'Host: web-service.example.com' http://${ALB_DNS}/"
echo "  curl -H 'Host: business-service.example.com' http://${ALB_DNS}/"
echo ""
echo "Check ALB status:"
echo "  aws elbv2 describe-load-balancers --names ${ALB_NAME}"
echo ""
echo "Check target health:"
echo "  aws elbv2 describe-target-health --target-group-arn ${TARGET_GROUP_ARN}"
