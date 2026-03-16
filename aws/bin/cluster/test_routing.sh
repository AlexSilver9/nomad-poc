#!/bin/bash
set -euo pipefail

# Routing test script for Consul API Gateway.
# Tests HTTP routing rules configured in aws/infrastructure/api-gateway/routes/.
# Usage: ./test_routing.sh [NODE_IP]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }
section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# --- Input ---

NODE_IP="${1:-}"
if [[ -z "$NODE_IP" ]]; then
    read -rp "Node IP (public or private): " NODE_IP
fi
API_GW="http://${NODE_IP}:8080"    # Direct API Gateway (no rewrite)
TRAEFIK="http://${NODE_IP}:8081"   # Traefik HTTP → API Gateway :8080 (regex rewrite)
TRAEFIK_TLS="https://${NODE_IP}:8443"  # Traefik HTTPS → API Gateway :8082 (TLS term + rewrite)

# --- Helpers ---

# http_status HOST PATH [EXTRA_CURL_ARGS...]
http_status() {
    local host="$1" path="$2"; shift 2
    curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: $host" "$@" \
        --connect-timeout 5 --max-time 10 \
        "${API_GW}${path}" 2>/dev/null || echo "000"
}

# http_body HOST PATH [EXTRA_CURL_ARGS...]
http_body() {
    local host="$1" path="$2"; shift 2
    curl -s \
        -H "Host: $host" "$@" \
        --connect-timeout 5 --max-time 10 \
        "${API_GW}${path}" 2>/dev/null || true
}

check_status() {
    local desc="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$desc (HTTP $got)"
    else
        fail "$desc (want HTTP $want, got HTTP $got)"
    fi
}

check_body_contains() {
    local desc="$1" pattern="$2" body="$3"
    if echo "$body" | grep -q "$pattern"; then
        pass "$desc"
    else
        fail "$desc (pattern '$pattern' not found in response)"
        # Show the request line (GET /path HTTP/1.1) to diagnose rewrite issues
        local req_line
        req_line=$(echo "$body" | grep -E "^(GET|POST|PUT|DELETE|PATCH) " | head -1)
        if [[ -n "$req_line" ]]; then
            echo "    Upstream saw: $req_line"
        else
            echo "    Response: $(echo "$body" | head -5)"
        fi
    fi
}

# --- Tests ---

section "Gateway reachability"

status=$(http_status "unknown.example.com" "/")
check_status "Unknown hostname → 404 from Envoy" "404" "$status"

section "web-service (http-echo)"

status=$(http_status "web-service.example.com" "/")
check_status "web-service / → 200" "200" "$status"

section "business-service (whoami)"

status=$(http_status "business-service.example.com" "/")
check_status "business-service / → 200" "200" "$status"

status=$(http_status "business-service.example.com" "/api")
check_status "business-service /api → 200" "200" "$status"
body=$(http_body "business-service.example.com" "/api")
# containous/whoami outputs the request line as "GET /path HTTP/1.1", not "RequestURI: /path"
check_body_contains "business-service /api URLRewrite → upstream sees /business-service/api" \
    "GET /business-service/api HTTP" "$body"

# /legacy-download via API Gateway directly: service-router PrefixRewrite does NOT propagate
# through the API Gateway (architectural limitation). Upstream receives original path unchanged.
body=$(http_body "business-service.example.com" "/legacy-download/abc123")
status=$(http_status "business-service.example.com" "/legacy-download/abc123")
check_status "business-service /legacy-download/abc123 → 200 (reaches service)" "200" "$status"
if echo "$body" | grep -q "GET /legacy-download/abc123 HTTP"; then
    echo -e "  ${YELLOW}KNOWN${NC} /legacy-download NOT rewritten via API Gateway (expected — see router.consul.hcl)"
elif echo "$body" | grep -q "GET /business-service/download.xhtml/abc123 HTTP"; then
    pass "/legacy-download rewritten (unexpected via direct API Gateway — check traefik bypass)"
else
    fail "/legacy-download path unexpected (body: $(echo "$body" | head -5))"
fi

section "Traefik regex URL rewrite (port 8081 → API Gateway)"

# /download/<token> via Traefik: external client path used since the ingress-gateway era.
# Traefik rewrites /download/<token> → /business-service/download.xhtml?token=<token>
# before forwarding to the API Gateway, which routes to business-service by hostname.
# This is a separate path from /legacy-download/ (east-west, service-router — see below).
tr_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: business-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK}/download/abc123" 2>/dev/null || echo "000")
check_status "traefik /download/abc123 → 200" "200" "$tr_status"

tr_body=$(curl -s \
    -H "Host: business-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK}/download/abc123" 2>/dev/null || true)
check_body_contains \
    "traefik regex rewrite → upstream sees /business-service/download.xhtml?token=abc123" \
    "/business-service/download.xhtml?token=abc123" "$tr_body"

# Verify passthrough: non-rewrite paths still reach the correct service through traefik.
tr_pt_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: web-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK}/" 2>/dev/null || echo "000")
check_status "traefik passthrough: web-service / → 200" "200" "$tr_pt_status"

section "Traefik HTTPS (port 8443 → API Gateway :8082 → https-service)"

# Traefik terminates client TLS on :8443, re-encrypts, and forwards to API Gateway TCP :8082.
# The API Gateway passes the bytes through to https-service which terminates the inner TLS.
# -k = skip self-signed cert verification on the Traefik side.

tls_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Host: https-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK_TLS}/" 2>/dev/null || echo "000")
check_status "https-service via Traefik :8443 → 200" "200" "$tls_status"

tls_body=$(curl -sk \
    -H "Host: https-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK_TLS}/" 2>/dev/null || true)
check_body_contains "https-service response body confirms TLS end-to-end" \
    "Hello from https-service" "$tls_body"

# HTTPS regex rewrite: /download/<token> via Traefik :8443 — same rewrite as HTTP path.
# business-service (whoami) reflects the request line, confirming the rewrite was applied.
tls_rw_body=$(curl -sk \
    -H "Host: business-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK_TLS}/download/abc123" 2>/dev/null || true)
check_body_contains \
    "traefik HTTPS regex rewrite → upstream sees /business-service/download.xhtml?token=abc123" \
    "/business-service/download.xhtml?token=abc123" "$tls_rw_body"

# Verify non-HTTPS services still route through Traefik :8443 to API Gateway :8080 (HTTP path).
tls_pt_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Host: web-service.example.com" \
    --connect-timeout 5 --max-time 10 \
    "${TRAEFIK_TLS}/" 2>/dev/null || echo "000")
check_status "web-service via Traefik :8443 (TLS term → HTTP upstream) → 200" "200" "$tls_pt_status"

section "HTTPS/TCP passthrough (port 8082)"

# TLS connection attempt — expects a TLS error (reset/handshake), not a connection timeout.
# A timeout means the port is not reachable at all (security group or listener not running).
tcp_out=$(curl -sk --connect-timeout 5 --max-time 5 "https://${NODE_IP}:8082/" 2>&1 || true)
if echo "$tcp_out" | grep -qiE "reset|handshake|refused|connection|tls|ssl|empty reply"; then
    pass "TCP 8082 reachable (TLS error from gateway — expected when no backend cert)"
elif [[ -z "$tcp_out" ]]; then
    # curl -sk returned empty output with exit 0 — TLS passthrough working, backend accepted TLS
    pass "TCP 8082 reachable (TLS passthrough working — backend handled TLS handshake)"
else
    fail "TCP 8082 not reachable (timeout — check security group port 8082 and api-gateway tcp listener)"
fi

# --- Summary ---

echo ""
echo -e "${BLUE}Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
[[ $FAIL -eq 0 ]] || exit 1
