#!/bin/bash
set -euo pipefail

# POC: Hazelcast member-to-member traffic through the Consul service mesh.
# See services/hazelcast-mesh-service/job.nomad.hcl for the design.
#
# Verifies:
#   1. Nomad accepts two Connect services (app + hz) in one task group
#   2. Redirect-only service-resolvers work for unregistered virtual names (hz-0..hz-2)
#   3. All members form one cluster (clusterSize = 3) via mesh upstreams
#   4. A rogue Hazelcast member (plain TCP, no mesh cert) cannot join
#   5. A member that restarts while the intention denies cannot rejoin; it can after re-allowing
#   6. A rolling update keeps the cluster intact
#
# Each step pauses for verification in the Nomad / Consul UI before proceeding.
#
# Requires ACLs enabled AND enforced on the cluster (run aws/bin/cluster/bootstrap_acl.sh, then
# enforce_acl.sh - see doc/SETUP.md). Consul's default intention action follows the ACL
# default_policy: without enforcement (no ACLs, or default_policy = "allow") connections not
# covered by an intention are ALLOWED, so "Hazelcast members of other services are denied by
# default" would not hold.
#
# Requires: NOMAD_TOKEN and CONSUL_HTTP_TOKEN exported (management tokens), jq, sudo docker.
# Usage: ./hazelcast_mesh.sh

GITHUB_RAW_BASE="https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/api-gateway/aws"
SVC_DIR="services/hazelcast-mesh-service"
JOB_NAME="hazelcast-mesh-service"
HZ_SVC="hazelcast-mesh-service-hz"
MEMBERS=3
CONSUL_ADDR="${CONSUL_HTTP_ADDR:-http://127.0.0.1:8500}"
CONSUL_ADDR="${CONSUL_ADDR#http://}"
CONSUL_ADDR="http://${CONSUL_ADDR}"
ROGUE_NAME="hz-rogue"

[[ -n "${NOMAD_TOKEN:-}" ]]       || { echo "Error: NOMAD_TOKEN not set"; exit 1; }
[[ -n "${CONSUL_HTTP_TOKEN:-}" ]] || { echo "Error: CONSUL_HTTP_TOKEN not set"; exit 1; }
command -v jq &>/dev/null         || { echo "Error: jq required"; exit 1; }

CONFIG_FILES=(
  defaults.consul.hcl
  defaults-app.consul.hcl
  intentions.consul.hcl
  resolver.consul.hcl
)
for ((i = 0; i < MEMBERS; i++)); do CONFIG_FILES+=("resolver-member-$i.consul.hcl"); done

# --- Helpers ---

running_allocs() {
  nomad job allocs -t '{{range .}}{{if eq .ClientStatus "running"}}{{println .ID}}{{end}}{{end}}' "$JOB_NAME"
}

# Prints "<alloc> <health json>" per running alloc
# nomad alloc exec occasionally returns empty output - retry up to 3 times, 15s timeout each.
cluster_health() {
  local alloc out
  while IFS= read -r alloc; do
    [[ -z "$alloc" ]] && continue
    out=""
    for _ in 1 2 3; do
      out=$(timeout 15 nomad alloc exec -i=false -t=false -task hazelcast "$alloc" \
        curl -s --max-time 3 http://127.0.0.1:5701/hazelcast/health < /dev/null || true)
      [[ -n "$out" ]] && break
      sleep 2
    done
    [[ -n "$out" ]] || out='{"error":"unreachable"}'
    echo "${alloc:0:8} $out"
  done < <(running_allocs)
}

# Succeeds if every running member reports clusterSize = $1
expect_cluster_size() {
  local want="$1" ok=0 line size
  while IFS= read -r line; do
    echo "  $line"
    size=$(echo "${line#* }" | jq -r '.clusterSize // "n/a"')
    [[ "$size" == "$want" ]] || ok=1
  done < <(cluster_health)
  if [[ $ok -eq 0 ]]; then echo "PASS: all members report clusterSize=$want"; else echo "FAIL: expected clusterSize=$want"; fi
  return $ok
}

# Step 1: Download required files from GitHub
echo "=== STEP 1: Download required files ==="
mkdir -p "$SVC_DIR"
wget -q -O "$SVC_DIR/job.nomad.hcl" "$GITHUB_RAW_BASE/$SVC_DIR/job.nomad.hcl"
for f in "${CONFIG_FILES[@]}"; do
  wget -q -O "$SVC_DIR/$f" "$GITHUB_RAW_BASE/$SVC_DIR/$f"
done
echo "Downloaded job and ${#CONFIG_FILES[@]} Consul config files"

read -rp "Press Enter to apply Consul configurations..."

# Step 2: Apply Consul configurations (subset resolver before the redirects that reference it)
echo "=== STEP 2: Apply Consul configurations ==="
for f in "${CONFIG_FILES[@]}"; do
  consul config write "$SVC_DIR/$f"
  echo "  applied $f"
done

read -rp "Press Enter to deploy the job..."

# Step 3: Deploy - verifies two Connect services per group are accepted
echo "=== STEP 3: Deploy $JOB_NAME (count=$MEMBERS) ==="
nomad job run "$SVC_DIR/job.nomad.hcl"
nomad job status "$JOB_NAME"

echo ""
echo "Check in Consul UI: $HZ_SVC has $MEMBERS instances tagged hz-ordinal-0..$((MEMBERS - 1)) (sidecars too),"
echo "and Routing shows hazelcast-mesh-service-hz-<N> redirecting to subset member-<N>."
read -rp "Press Enter to verify cluster formation..."

# Step 4: Verify cluster formation through the mesh
echo "=== STEP 4: Verify all members joined one cluster ==="
expect_cluster_size "$MEMBERS" || true
echo ""
echo "Member list of one alloc (all addresses must be 127.0.0.1:157xx):"
nomad alloc logs -task hazelcast "$(running_allocs | sed -n 1p)" | grep -A$((MEMBERS + 1)) 'Members {size' | tail -$((MEMBERS + 2)) || true

read -rp "Press Enter to run the rogue member test..."

# Step 5: Rogue member - plain Hazelcast pointed at the sidecars' public mTLS listeners.
# 5701 is not published on the host, so the sidecar listener is the only reachable entry point.
echo "=== STEP 5: Rogue member must NOT be able to join ==="
SIDECAR_ADDRS=$(curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" "$CONSUL_ADDR/v1/health/connect/$HZ_SVC" \
  | jq -r '.[] | "\(.Service.Address):\(.Service.Port)"')
echo "Sidecar public listeners:"
echo "$SIDECAR_ADDRS" | sed 's/^/  /'

ROGUE_CFG=$(mktemp)
{
  echo "hazelcast:"
  echo "  cluster-name: hazelcast-mesh-service"
  echo "  network:"
  echo "    port: {port: 5799, auto-increment: false}"
  echo "    join:"
  echo "      auto-detection: {enabled: false}"
  echo "      multicast: {enabled: false}"
  echo "      tcp-ip:"
  echo "        enabled: true"
  echo "        member-list:"
  echo "$SIDECAR_ADDRS" | sed 's/^/          - /'
} > "$ROGUE_CFG"
chmod 644 "$ROGUE_CFG"

sudo docker rm -f "$ROGUE_NAME" &>/dev/null || true
# Memory limit is essential: without it the JVM sizes its heap from the NODE's total RAM
# (MaxRAMPercentage=80) and starves Consul/Nomad servers on this node.
sudo docker run -d --name "$ROGUE_NAME" --network host \
  --memory 320m \
  -v "$ROGUE_CFG:/opt/hazelcast/config/rogue.yaml:ro" \
  -e HAZELCAST_CONFIG=/opt/hazelcast/config/rogue.yaml \
  -e JAVA_OPTS="-XX:MaxRAMPercentage=50" \
  hazelcast/hazelcast:5.5.0 >/dev/null
echo "Rogue member started, waiting 45s for join attempts..."
sleep 45

echo "Rogue member log (expected: connection errors, standalone cluster of size 1):"
sudo docker logs "$ROGUE_NAME" 2>&1 | grep -E 'Members \{size|Connection|SSL|closed|refused' | tail -10 || true
echo ""
expect_cluster_size "$MEMBERS" || true
sudo docker rm -f "$ROGUE_NAME" >/dev/null
rm -f "$ROGUE_CFG"

read -rp "Press Enter to run the intention deny test..."

# Step 6: Intention deny. Envoy enforces intentions on new connections only, so existing member
# connections survive. Restarting one member forces it to reconnect - which must fail.
echo "=== STEP 6: Deny intention, restart one member ==="
DENY_CFG=$(mktemp)
cat > "$DENY_CFG" <<EOF
Kind = "service-intentions"
Name = "$HZ_SVC"
Sources = [{ Name = "$HZ_SVC", Action = "deny" }]
EOF
consul config write "$DENY_CFG"
rm -f "$DENY_CFG"

VICTIM=$(running_allocs | sed -n 1p)
echo "Restarting hazelcast task of alloc ${VICTIM:0:8}..."
nomad alloc restart "$VICTIM" hazelcast
echo "Waiting 60s..."
sleep 60
echo "Expected: ${VICTIM:0:8} reports clusterSize=1, the others $((MEMBERS - 1)):"
cluster_health | sed 's/^/  /'

read -rp "Press Enter to restore the allow intention and restart the member again..."

consul config write "$SVC_DIR/intentions.consul.hcl"
nomad alloc restart "$VICTIM" hazelcast
echo "Waiting 60s..."
sleep 60
expect_cluster_size "$MEMBERS" || true

read -rp "Press Enter to run a rolling update (watch Nomad UI)..."

# Step 7: Rolling update - members are replaced one by one, the cluster must stay intact
echo "=== STEP 7: Rolling update ==="
# Right after submit, -latest may still return the previous (already successful) deployment.
# Remember it and wait until a new one appears.
PREV_DEPLOYMENT=$(nomad job deployments -latest -t '{{.ID}}' "$JOB_NAME")
nomad job run -detach -var revision="$(date +%s)" "$SVC_DIR/job.nomad.hcl"
DEPLOYMENT="$PREV_DEPLOYMENT"
for _ in $(seq 1 30); do
  DEPLOYMENT=$(nomad job deployments -latest -t '{{.ID}}' "$JOB_NAME")
  [[ "$DEPLOYMENT" != "$PREV_DEPLOYMENT" ]] && break
  sleep 2
done
[[ "$DEPLOYMENT" != "$PREV_DEPLOYMENT" ]] || { echo "Error: no new deployment after 60s"; exit 1; }
while true; do
  STATUS=$(nomad deployment status -t '{{.Status}}' "$DEPLOYMENT")
  echo "--- $(date +%T) deployment=$STATUS"
  cluster_health | sed 's/^/  /'
  [[ "$STATUS" == "running" ]] || break
  sleep 10
done
echo ""
expect_cluster_size "$MEMBERS" || true

read -rp "Press Enter to stop and purge the job..."

# Step 8: Stop and purge job
echo "=== STEP 8: Stop and purge job ==="
nomad job stop -purge "$JOB_NAME"

# Step 9: Cleanup (redirect resolvers first - they reference the subset resolver)
echo "=== STEP 9: Cleanup ==="
for ((i = 0; i < MEMBERS; i++)); do
  consul config delete -kind service-resolver -name "$HZ_SVC-$i" || true
done
consul config delete -kind service-resolver -name "$HZ_SVC" || true
consul config delete -kind service-intentions -name "$HZ_SVC" || true
consul config delete -kind service-defaults -name "$HZ_SVC" || true
consul config delete -kind service-defaults -name "$JOB_NAME" || true

echo "Done"
