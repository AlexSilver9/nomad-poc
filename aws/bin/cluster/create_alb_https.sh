#!/bin/bash
set -euo pipefail

# Create an HTTPS ALB for the Nomad ingress gateway (production / end-to-end TLS).
# Listens on HTTPS:443 and forwards all traffic to a single HTTPS target group (nginx:8443).
# No host-based rules needed — hostname routing is handled by nginx and Envoy internally.
# Requires a domain with a valid ACM certificate. For HTTP-only POC testing, use create_alb.sh.
# Requires: aws-cli, jq
#
# Usage: ./create_alb_https.sh <target-group-arn> <acm-certificate-arn> [alb-name]
#
# To list ACM certificates:
#   aws acm list-certificates --query 'CertificateSummaryList[*].[DomainName,CertificateArn]' --output table
#
# To get target group ARN:
#   aws elbv2 describe-target-groups --names nomad-target-group --query 'TargetGroups[0].TargetGroupArn' --output text

command -v aws &>/dev/null || { echo "Error: aws-cli required"; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <target-group-arn> <acm-certificate-arn> [alb-name]"
    echo ""
    echo "To get target group ARN:"
    echo "  aws elbv2 describe-target-groups --names nomad-target-group --query 'TargetGroups[0].TargetGroupArn' --output text"
    
    exit 1
fi

TARGET_GROUP_ARN="$1"
ACM_CERTIFICATE_ARN="$2"
ALB_NAME="${3:-nomad-alb}"

# Subnets (need at least 2 in different AZs for ALB), these should be public subnets in the VPC
SUBNETS="subnet-3ee53954 subnet-5eafa423"

# Security groups (default, SSH, HTTPS, HTTP, NOMAD-CONSUL)
SECURITY_GROUPS="sg-77476f14 sg-07fee22cbcdad4c58 sg-0beaa6c98d73ebd3b sg-09aa7199da65ed0e3 sg-08e51d2a581377e0b"

echo "Creating Application Load Balancer: ${ALB_NAME}"

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

# Single HTTPS:443 listener forwarding all traffic to nginx:8443.
# No host-based rules — nginx handles all hostname routing internally.
echo "Creating HTTPS listener on port 443..."
listener_result=$(aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTPS \
    --port 443 \
    --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
    --certificates CertificateArn="${ACM_CERTIFICATE_ARN}" \
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
echo "  curl -H 'Host: web-service.example.com' https://${ALB_DNS}/"
echo ""
echo "Check ALB status:"
echo "  aws elbv2 describe-load-balancers --names ${ALB_NAME}"
echo ""
echo "Check target health:"
echo "  aws elbv2 describe-target-health --target-group-arn ${TARGET_GROUP_ARN}"
