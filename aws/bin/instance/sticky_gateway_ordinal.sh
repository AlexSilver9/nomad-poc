#!/bin/bash
set -euo pipefail

# POC: sticky sessions, Option B - nginx addresses each instance via its OWN API Gateway port.
# See doc/STICKY_SESSIONS.md and services/sticky-https-service/.
#
#   client → nginx :8443 (TLS termination, STICKY_ROUTE cookie, hash consistent)
#          → 127.0.0.1:8083 / :8084 (API Gateway TCP listener per instance)
#          → tcp-route → virtual service sticky-https-service-<N> → redirect → subset ordinal-<N>
#          → mTLS → sidecar → instance N (HTTPS)
#
# Verifies:
#   1. The API Gateway's tcp-route accepts a virtual service (redirect resolver) and reaches
#      exactly one instance per port (proven for sidecar upstreams in hazelcast_mesh.sh, not yet
#      for the gateway)
#   2. nginx sets STICKY_ROUTE on the first request
#   3. A client with the cookie always hits the same instance - via nginx on ANY node
#   4. Instance failure: its clients fail over to the other instance, the other instance's
#      clients stay; the replacement (same ordinal → same gateway port) takes its clients back
#
# Updates the API Gateway (new listeners 8083/8084 - brief interruption of all gateway traffic)
# and switches the cluster from traefik-rewrite to nginx-rewrite, using the test variant
# services/sticky-https-service/nginx-b.nomad.hcl (same job name, ONLY the sticky-b route - other
# hostnames are not routed during the test). Cleanup restores the regular nginx-rewrite job.
# Each step pauses for verification before proceeding.
#
# Requires ACLs enabled AND enforced (bootstrap_acl.sh, enforce_acl.sh) so the intention
# api-gateway → sticky-https-service is actually needed.
# Requires: NOMAD_TOKEN and CONSUL_HTTP_TOKEN exported (management tokens), jq.
# Usage: ./sticky_gateway_ordinal.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
SVC_DIR="services/sticky-https-service"
NGINX_JOB_FILE="$SVC_DIR/nginx-b.nomad.hcl"
NGINX_REGULAR_FILE="infrastructure/nginx-rewrite/job.nomad.hcl"
GW_JOB_FILE="infrastructure/api-gateway/job.nomad.hcl"
GW_CONFIG_FILE="infrastructure/api-gateway/gateway.consul.hcl"
JOB_NAME="sticky-https-service"
HOST="sticky-b.example.com"
COOKIE="STICKY_ROUTE"
CLIENTS=6
NOMAD_API="${NOMAD_ADDR:-http://127.0.0.1:4646}"
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
CONSUL_ADDR="${CONSUL_ADDR#http://}"
CONSUL_ADDR="http://${CONSUL_ADDR}"

[[ -n "${NOMAD_TOKEN:-}" ]]       || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
command -v jq &>/dev/null         || { echo "Error: jq required"; exit 1; }

# Order matters: subsets (resolver) before the redirects that reference them, redirects before
# the routes that use the virtual names.
CONFIG_FILES=(
  defaults.consul.hcl
  intentions.consul.hcl
  resolver.consul.hcl
  resolver-instance-0.consul.hcl
  resolver-instance-1.consul.hcl
  route-instance-0.consul.hcl
  route-instance-1.consul.hcl
)

# --- Helpers ---

# Node IPs - nginx-rewrite (system job) listens on :8443 on every node, like behind the ALB
NODES=()
while IFS= read -r ip; do NODES+=("$ip"); done < <(
  curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_ADDR/v1/catalog/nodes" | jq -r '.[].Address'
)
[[ ${#NODES[@]} -gt 0 ]] || { echo "Error: no Consul nodes found"; exit 1; }

node() {
  echo "${NODES[$(( $1 % ${#NODES[@]} ))]}";
}

# Prints the job status (running/pending/dead) or "absent"
job_status() {
  curl -s -H "X-Nomad-Token: $NOMAD_TOKEN" "$NOMAD_API/v1/job/$1" \
    | jq -Rr '(fromjson? // {}) | .Status // "absent"'
}

running_allocs() {
  nomad job allocs -t '{{range .}}{{if eq .ClientStatus "running"}}{{.ID}} {{.Name}}{{println}}{{end}}{{end}}' "$1"
}

passing_instances() {
  curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_ADDR/v1/health/service/$JOB_NAME?passing" | jq length
}

# request <node-ip> [cookie] → "<Name>/<Hostname> <Set-Cookie header or ->"
# --resolve sends SNI + Host for $HOST to the given node. The cookie is sent as a header: curl
# scopes jar cookies to one host, but each request goes to a different node.
request() {
  local ip="$1" cookie="${2:-}" resp name host setcookie
  local args=(-sk -i --max-time 5 --resolve "$HOST:8443:$ip")
  [[ -n "$cookie" ]] && args+=(-H "Cookie: $COOKIE=$cookie")
  resp=$(curl "${args[@]}" "https://$HOST:8443/" | tr -d '\r' || true)
  name=$(sed -n 's/^Name: //p' <<< "$resp")
  host=$(sed -n 's/^Hostname: //p' <<< "$resp")
  setcookie=$(sed -n 's/^[Ss]et-[Cc]ookie: //p' <<< "$resp" | sed -n 1p)
  echo "${name:-?}/${host:-?} ${setcookie:--}"
}

cookie_value() {
  sed -nE "s/^$COOKIE=([^;]*).*/\1/p" <<< "$1";
}

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p "$SVC_DIR" "$(dirname "$NGINX_REGULAR_FILE")" "$(dirname "$GW_JOB_FILE")"
for f in job.nomad.hcl nginx-b.nomad.hcl "${CONFIG_FILES[@]}"; do
  wget -q -O "$SVC_DIR/$f" "$GITHUB_RAW_BASE/$SVC_DIR/$f"
done
for f in "$NGINX_REGULAR_FILE" "$GW_JOB_FILE" "$GW_CONFIG_FILE"; do
  wget -q -O "$f" "$GITHUB_RAW_BASE/$f"
done
echo "Downloaded service job, ${#CONFIG_FILES[@]} Consul config files, nginx test variant B, regular nginx-rewrite and api-gateway"
echo "Nodes: ${NODES[*]}"

read -rp "Press Enter to switch to nginx-rewrite (test variant B)..."

# Step 2: nginx instead of traefik (both bind 8081/8443 on the host)
echo "=== STEP 2: Switch to nginx-rewrite (test variant B) ==="
if [[ "$(job_status traefik-rewrite)" != "dead" && "$(job_status traefik-rewrite)" != "absent" ]]; then
  nomad job stop traefik-rewrite
fi
nomad job run "$NGINX_JOB_FILE"

# The test variant routes ONLY the sticky hostname - remind to restore if the script stops early
RESTORED=false
trap '[[ $RESTORED == true ]] || echo "NOTE: nginx-rewrite still runs the test variant - restore: nomad job run $NGINX_REGULAR_FILE"' EXIT

read -rp "Press Enter to update the API Gateway (listeners 8083/8084 - brief interruption)..."

# Step 3: API Gateway with one TCP listener per instance
echo "=== STEP 3: API Gateway listeners + static ports 8083/8084 ==="
consul config write "$GW_CONFIG_FILE"
nomad job run "$GW_JOB_FILE"
echo "If allocations are not placed: nomad job status api-gateway / nomad job eval api-gateway"

read -rp "Press Enter to apply Consul configurations and deploy $JOB_NAME..."

# Step 4: Consul entries + deploy
echo "=== STEP 4: Consul configurations + deploy $JOB_NAME (count=2) ==="
for f in "${CONFIG_FILES[@]}"; do
  consul config write "$SVC_DIR/$f"
  echo "  applied $f"
done
nomad job run "$SVC_DIR/job.nomad.hcl"
echo "Waiting for 2 passing instances in Consul..."
for _ in $(seq 1 30); do
  [[ "$(passing_instances)" -ge 2 ]] && break
  sleep 3
done
echo "Passing instances: $(passing_instances)"

read -rp "Press Enter to check the per-instance gateway ports..."

# Step 5: Each gateway port must reach exactly ONE instance (no nginx involved).
# Expected: :8083 → only sticky-0, :8084 → only sticky-1, on every node's gateway.
echo "=== STEP 5: Per-instance gateway ports (5 requests each, per node) ==="
for ip in "${NODES[@]}"; do
  for port in 8083 8084; do
    hits=""
    for _ in $(seq 1 5); do
      hits+="$(curl -sk --max-time 5 "https://$ip:$port/" | tr -d '\r' | sed -n 's/^Name: //p' || true) "
    done
    echo "  $ip:$port → $hits"
  done
done

read -rp "Press Enter to send requests WITHOUT cookie..."

# Step 6: No cookie → nginx sets STICKY_ROUTE; new clients spread over both instances
echo "=== STEP 6: Requests without cookie (expected: Set-Cookie $COOKIE on each, both instances) ==="
for i in $(seq 0 7); do
  echo "  via $(node "$i"): $(request "$(node "$i")")"
done

read -rp "Press Enter to run the sticky client test..."

# Step 7: Each client keeps the cookie of its first response and sends it on every request,
# rotating over all nodes. All requests of one client must hit the same instance.
echo "=== STEP 7: $CLIENTS clients x 9 requests, rotating over ${#NODES[@]} nodes ==="
CLIENT_COOKIES=()
CLIENT_INSTANCES=()
for c in $(seq 1 "$CLIENTS"); do
  first=$(request "$(node 0)")
  cookie=$(cookie_value "${first#* }")
  if [[ -z "$cookie" ]]; then
    echo "  client $c: FAIL - no $COOKIE cookie in response ($first)"
    continue
  fi
  instances="${first%% *}"$'\n'
  for i in $(seq 1 8); do
    r=$(request "$(node "$i")" "$cookie")
    instances+="${r%% *}"$'\n'
  done
  distinct=$(sort -u <<< "$instances" | sed '/^$/d')
  if [[ $(wc -l <<< "$distinct") -eq 1 ]]; then
    echo "  client $c: PASS - all 9 requests on $distinct"
  else
    echo "  client $c: FAIL - hit: $(tr '\n' ' ' <<< "$distinct")"
  fi
  CLIENT_COOKIES+=("$cookie")
  CLIENT_INSTANCES+=("$(sed -n 1p <<< "$distinct")")
done
[[ ${#CLIENT_COOKIES[@]} -gt 0 ]] || { echo "Error: no client got a cookie - stopping"; exit 1; }
echo "Clients per instance (expected: both instances used):"
printf '%s\n' "${CLIENT_INSTANCES[@]}" | sort | uniq -c | sed 's/^/  /'

read -rp "Press Enter to run the failover test (stops one instance)..."

# Step 8: Stop the instance of client 1. Expected:
#   - client 1 fails over to the other instance (real app: new login)
#   - clients of the other instance stay - also when the replacement comes back: it gets the same
#     ordinal → same gateway port → nginx's hash ring never changes
#   - client 1 returns to the replacement once it is healthy (real app: second login)
echo "=== STEP 8: Failover ==="
VICTIM_INSTANCE="${CLIENT_INSTANCES[0]}"
VICTIM_INDEX=$(sed -nE 's/^sticky-([0-9]+)\/.*/\1/p' <<< "$VICTIM_INSTANCE")
VICTIM_ALLOC=$(running_allocs "$JOB_NAME" | awk -v idx="[$VICTIM_INDEX]" 'index($2, idx) {print $1}' | sed -n 1p)
[[ -n "$VICTIM_ALLOC" ]] || { echo "Error: no running alloc for $VICTIM_INSTANCE"; exit 1; }
OTHER=""
for i in "${!CLIENT_INSTANCES[@]}"; do
  if [[ "${CLIENT_INSTANCES[$i]}" != "$VICTIM_INSTANCE" ]]; then OTHER=$i; break; fi
done
echo "Client 1 is on $VICTIM_INSTANCE → stopping alloc ${VICTIM_ALLOC:0:8}"
if [[ -n "$OTHER" ]]; then
  echo "Client $((OTHER + 1)) is on ${CLIENT_INSTANCES[$OTHER]} → should stay there"
else
  echo "(all clients are on one instance - nothing to check for staying)"
fi
nomad alloc stop -detach "$VICTIM_ALLOC"
echo "Requests every 3s for 90s (Nomad places a replacement - watch when it is back):"
for i in $(seq 1 30); do
  line="  $(date +%T) client1=$(request "$(node "$i")" "${CLIENT_COOKIES[0]}" | cut -d' ' -f1)"
  if [[ -n "$OTHER" ]]; then
    line+=" client$((OTHER + 1))=$(request "$(node "$i")" "${CLIENT_COOKIES[$OTHER]}" | cut -d' ' -f1)"
  fi
  echo "$line"
  sleep 3
done
echo ""
echo "After failover - all clients (moved = session lost in a real app):"
for c in "${!CLIENT_COOKIES[@]}"; do
  now=$(request "$(node "$c")" "${CLIENT_COOKIES[$c]}" | cut -d' ' -f1)
  mark="stayed"; [[ "$now" != "${CLIENT_INSTANCES[$c]}" ]] && mark="MOVED"
  echo "  client $((c + 1)): before=${CLIENT_INSTANCES[$c]} now=$now  $mark"
done

read -rp "Press Enter to stop and purge the job..."

# Step 9: Cleanup (routes first, then redirects, then the subset resolver).
# The gateway listeners 8083/8084 stay (no route attached → unused).
echo "=== STEP 9: Stop, purge, cleanup, restore regular nginx-rewrite ==="
nomad job stop -purge "$JOB_NAME"
for n in 0 1; do consul config delete -kind tcp-route -name "$JOB_NAME-$n" || true; done
for n in 0 1; do consul config delete -kind service-resolver -name "$JOB_NAME-$n" || true; done
consul config delete -kind service-resolver -name "$JOB_NAME" || true
consul config delete -kind service-intentions -name "$JOB_NAME" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true
nomad job run "$NGINX_REGULAR_FILE"
RESTORED=true

echo ""
echo "Done. The regular nginx-rewrite is running. Switch back to traefik with:"
echo "  nomad job stop nginx-rewrite && nomad job run infrastructure/traefik-rewrite/job.nomad.hcl"
