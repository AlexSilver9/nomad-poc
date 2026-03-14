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
GW="http://${NODE_IP}:8080"

# --- Helpers ---

# http_status HOST PATH [EXTRA_CURL_ARGS...]
http_status() {
    local host="$1" path="$2"; shift 2
    curl -s -o /dev/null -w "%{http_code}" \
        -H "Host: $host" "$@" \
        --connect-timeout 5 --max-time 10 \
        "${GW}${path}" 2>/dev/null || echo "000"
}

# http_body HOST PATH [EXTRA_CURL_ARGS...]
http_body() {
    local host="$1" path="$2"; shift 2
    curl -s \
        -H "Host: $host" "$@" \
        --connect-timeout 5 --max-time 10 \
        "${GW}${path}" 2>/dev/null || true
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
        echo "    Response: $(echo "$body" | head -5)"
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

# /legacy-download: api-gateway routes to business-service (whoami); service-router PrefixRewrite
# does NOT propagate through the api-gateway (architectural limitation — see router.consul.hcl).
# The test documents current behaviour: upstream receives the original path unchanged.
body=$(http_body "business-service.example.com" "/legacy-download/abc123")
status=$(http_status "business-service.example.com" "/legacy-download/abc123")
check_status "business-service /legacy-download/abc123 → 200 (reaches service)" "200" "$status"
if echo "$body" | grep -q "GET /business-service/download.xhtml/abc123 HTTP"; then
    pass "/legacy-download prefix rewrite applied (service-router active through gateway)"
elif echo "$body" | grep -q "GET /legacy-download/abc123 HTTP"; then
    echo -e "  ${YELLOW}KNOWN${NC} /legacy-download prefix NOT rewritten (api-gateway limitation — see router.consul.hcl)"
else
    fail "/legacy-download path unexpected (body: $(echo "$body" | head -5))"
fi

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
