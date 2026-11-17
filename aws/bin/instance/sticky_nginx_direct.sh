#!/bin/bash
set -euo pipefail

# POC: sticky sessions, Option A - nginx connects to the service instances DIRECTLY.
# See doc/STICKY_SESSIONS.md and services/sticky-https-service/.
#
#   client → nginx :8443 (TLS termination, STICKY_ROUTE cookie, hash consistent)
#          → instance host port (HTTPS, from the Consul catalog)      ← bypasses API Gateway + mesh
#
# Verifies:
#   1. nginx renders the instance list from the Consul catalog (needs a Consul token via the
#      nginx job's workload identity - with ACLs the catalog is otherwise silently empty)
#   2. nginx sets STICKY_ROUTE on the first request
#   3. A client with the cookie always hits the same instance - via nginx on ANY node
#   4. Instance failure: its clients move, the other instance's clients stay; what happens when
#      the replacement (new address) comes back
#
# Switches the cluster from traefik-rewrite to nginx-rewrite, using the test variant
# services/sticky-https-service/nginx-a.nomad.hcl (same job name, ONLY the sticky-a route - other
# hostnames are not routed during the test). Cleanup restores the regular nginx-rewrite job.
# Each step pauses for verification before proceeding.
#
# Requires: NOMAD_TOKEN and CONSUL_HTTP_TOKEN exported (management tokens), jq.
# Usage: ./sticky_nginx_direct.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
SVC_DIR="services/sticky-https-service"
NGINX_JOB_FILE="$SVC_DIR/nginx-a.nomad.hcl"
NGINX_REGULAR_FILE="infrastructure/nginx-rewrite/job.nomad.hcl"
NGINX_JOB_NAME="nginx-rewrite"
JOB_NAME="sticky-https-service"
HOST="sticky-a.example.com"
PORT=8443
COOKIE="STICKY_ROUTE"
CLIENTS=6
NOMAD_API="${NOMAD_ADDR:-http://127.0.0.1:4646}"
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
CONSUL_ADDR="${CONSUL_ADDR#http://}"
CONSUL_ADDR="http://${CONSUL_ADDR}"

[[ -n "${NOMAD_TOKEN:-}" ]]       || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
command -v jq &>/dev/null         || { echo "Error: jq required"; exit 1; }

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
  local args=(-sk -i --max-time 5 --resolve "$HOST:$PORT:$ip")
  [[ -n "$cookie" ]] && args+=(-H "Cookie: $COOKIE=$cookie")
  resp=$(curl "${args[@]}" "https://$HOST:$PORT/" | tr -d '\r' || true)
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
mkdir -p "$SVC_DIR" "$(dirname "$NGINX_REGULAR_FILE")"
for f in job.nomad.hcl defaults.consul.hcl nginx-a.nomad.hcl; do
  wget -q -O "$SVC_DIR/$f" "$GITHUB_RAW_BASE/$SVC_DIR/$f"
done
wget -q -O "$NGINX_REGULAR_FILE" "$GITHUB_RAW_BASE/$NGINX_REGULAR_FILE"
echo "Downloaded service job, service-defaults, nginx test variant A and regular nginx-rewrite"
echo "Nodes: ${NODES[*]}"

read -rp "Press Enter to switch to nginx-rewrite (test variant A)..."

# Step 2: nginx instead of traefik (both bind 8081/8443 on the host). Variant A has the Consul
# identity + instance-list template. nginx stays pending if the Consul token exchange for the
# identity fails (check: nomad job status $NGINX_JOB_NAME).
echo "=== STEP 2: Switch to nginx-rewrite (test variant A) ==="
if [[ "$(job_status traefik-rewrite)" != "dead" && "$(job_status traefik-rewrite)" != "absent" ]]; then
  nomad job stop traefik-rewrite
fi
nomad job run "$NGINX_JOB_FILE"

# The test variant routes ONLY the sticky hostname - remind to restore if the script stops early
RESTORED=false
trap '[[ $RESTORED == true ]] || echo "NOTE: nginx-rewrite still runs the test variant - restore: nomad job run $NGINX_REGULAR_FILE"' EXIT

read -rp "Press Enter to deploy $JOB_NAME..."

# Step 3: Deploy (service-defaults tcp: HTTPS-native like Payara; no intentions needed - Option A
# does not go through the mesh)
echo "=== STEP 3: Deploy $JOB_NAME (count=2) ==="
consul config write "$SVC_DIR/defaults.consul.hcl"
nomad job run "$SVC_DIR/job.nomad.hcl"
echo "Waiting for 2 passing instances in Consul..."
for _ in $(seq 1 30); do
  [[ "$(passing_instances)" -ge 2 ]] && break
  sleep 3
done
echo "Passing instances: $(passing_instances)"

read -rp "Press Enter to check the rendered nginx upstreams..."

# Step 4: Rendered upstream on every nginx alloc. Expected: 2 "server <node-ip>:<port>" lines.
# "server 127.0.0.1:1 down" means the template sees no instances - usually a missing Consul token
# (catalog filtered by ACLs).
echo "=== STEP 4: Rendered upstream sticky_a per nginx node ==="
sleep 5
while read -r alloc _; do
  [[ -z "$alloc" ]] && continue
  echo "  --- nginx alloc ${alloc:0:8}"
  nomad alloc fs "$alloc" nginx/local/conf.d/sticky-a-upstream.conf | sed -n '/^upstream/,/^}/s/^/    /p' || true
done < <(running_allocs "$NGINX_JOB_NAME")

read -rp "Press Enter to send requests WITHOUT cookie..."

# Step 5: No cookie → nginx sets STICKY_ROUTE; new clients spread over both instances
echo "=== STEP 5: Requests without cookie (expected: Set-Cookie $COOKIE on each, both instances) ==="
for i in $(seq 0 7); do
  echo "  via $(node "$i"): $(request "$(node "$i")")"
done

read -rp "Press Enter to run the sticky client test..."

# Step 6: Each client keeps the cookie of its first response and sends it on every request,
# rotating over all nodes. All requests of one client must hit the same instance.
echo "=== STEP 6: $CLIENTS clients x 9 requests, rotating over ${#NODES[@]} nodes ==="
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

# Step 7: Stop the instance of client 1. Expected:
#   - client 1 moves to the other instance (in production: new login)
#   - clients of the other instance stay
#   - when the replacement comes back (NEW host address) nginx's hash ring changes → some clients
#     of the surviving instance may move as well (in production: logged out)
echo "=== STEP 7: Failover ==="
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
echo "After failover - all clients (moved = session lost in production):"
for c in "${!CLIENT_COOKIES[@]}"; do
  now=$(request "$(node "$c")" "${CLIENT_COOKIES[$c]}" | cut -d' ' -f1)
  mark="stayed"; [[ "$now" != "${CLIENT_INSTANCES[$c]}" ]] && mark="MOVED"
  echo "  client $((c + 1)): before=${CLIENT_INSTANCES[$c]} now=$now  $mark"
done

read -rp "Press Enter to stop and purge the job..."

# Step 8: Cleanup + restore the regular nginx-rewrite job
echo "=== STEP 8: Stop, purge, cleanup, restore regular nginx-rewrite ==="
nomad job stop -purge "$JOB_NAME"
consul config delete -kind service-defaults -name "$JOB_NAME" || true
nomad job run "$NGINX_REGULAR_FILE"
RESTORED=true

echo ""
echo "Done. The regular nginx-rewrite is running. Switch back to traefik with:"
echo "  nomad job stop nginx-rewrite && nomad job run infrastructure/traefik-rewrite/job.nomad.hcl"
