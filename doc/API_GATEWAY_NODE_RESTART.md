# api-gateway: 0 listeners after node reboot

## Symptom

After a node reboot (or manual restart of the Nomad agent), services routed through the
API Gateway become unreachable. nginx logs show upstream connection failures:

```
connect() failed (111: Connection refused) while connecting to upstream
upstream: "https://127.0.0.1:<service-port>"
```

All api-gateway TCP ports for services refuse connections. Port 8080 (HTTP) is
also unresponsive. The Nomad job shows as running and all tasks appear healthy and in
Consul UI also all services and the API-Gateway show as healthy without any hint to the problem.
---

## Why this is not obvious

The Nomad job shows green. The `api` task (Envoy) is running. Consul reports the api-gateway
allocation as healthy. Everything looks fine — until you query Envoy's admin API and discover
it has zero listeners:

```bash
# Find the bridge namespace IP of the api-gateway alloc on this node
ip addr | grep -A2 "nomad"

# Or
iptables -t nat -L -n | grep "to:172" | grep "dpt:8080"

# Then query Envoy admin (default admin port 19000):
curl http://<bridge-ip>:19000/listeners
# → returns empty (no listeners)
```

Envoy is running but has received no configuration from Consul.

---

## Diagnostic commands

### Step 1 — Confirm the port is unreachable

```bash
# Check loopback (used by nginx upstreams)
nc -zv 127.0.0.1 <service-port>

# Check node primary IP
nc -zv <node-primary-ip> <service-port>

# Check what is actually listening
ss -tlnp | grep <service-port>
```

If nothing is listening on the service port at all, the issue is Envoy having no listeners (continue
to step 3). If something is listening but connections are refused via loopback only, the
issue is `route_localnet` (see below).

### Step 2 — Check iptables DNAT rules

Consul Connect in bridge mode uses iptables DNAT to forward traffic from host ports into
the bridge namespace. These rules are written by CNI on allocation start.

```bash
iptables -t nat -L -n | grep <service-port>
```

If no DNAT rules exist for teh service port, the allocation was not re-initialized correctly
after the reboot. Stop and re-run the job.

### Step 3 — Query Envoy's listener count

Find the bridge IP of the api-gateway allocation:

```bash
# List all bridge IPs and match to Nomad alloc
ip addr show type bridge

# Or
iptables -t nat -L -n | grep "to:172" | grep "dpt:8080"
```

Query Envoy's admin API:

```bash
curl http://<bridge-ip>:19000/listeners
# Healthy: lists all listeners for services
# Broken:  empty response
```

If empty, Consul has not pushed any xDS configuration to Envoy. Continue to step 4.

### Step 4 — Check Consul service registration

```bash
curl http://localhost:8500/v1/catalog/service/api-gateway
# Healthy: JSON array with one entry per node
# Broken:  [] (empty array)
```

An empty array means the api-gateway service is not registered in Consul on this node.
This is the root cause: without a registration, Consul's xDS server sends Envoy zero
resources → zero listeners.

### Step 6 — Check the ACL token (if ACL is enabled)

A missing or expired Consul token would also cause registration failures, but the token
from the previous allocation is still valid (tokens do not expire on node reboot):

```bash
# Find the token written by the last successful consul login
cat /opt/nomad/data/alloc/<api-gateway alloc-id>/alloc/consul.token

# Verify it is still valid in Consul
curl -s http://localhost:8500/v1/acl/token/self \
  -H "X-Consul-Token: $(cat /opt/nomad/data/alloc/<alloc-id>/alloc/consul.token)" \
  | python3 -m json.tool | grep -E "AccessorID|ExpirationTime"
```

Consul tokens created via `consul login` (NWI) have no expiration time unless explicitly
set — they survive node reboots indefinitely.

### Step 7 — Check Envoy logs for xDS errors

```bash
nomad alloc logs <alloc-id> api
# Look for: "gRPC config stream closed", "connection refused", or xDS NACK messages
```

---

## Root cause

The api-gateway Nomad job uses a two-task design:

1. `setup` (prestart): calls `consul connect envoy -gateway api -register` to register the
   service in Consul and generate the Envoy bootstrap config.
2. `api` (main): runs Envoy using the generated bootstrap config.

**Original design (broken on reboots):** `setup` was a prestart *oneshot* (`sidecar = false`).
It ran once when the allocation was first created and then exited.

When a node reboots:
1. Nomad restores the existing allocation (same alloc ID, same alloc dir) — it does **not**
   create a new allocation.
2. Because the allocation already exists, the prestart oneshot task is **not re-run**.
3. Envoy (`api` task) restarts using the old bootstrap config from the alloc dir.
4. Envoy connects to Consul xDS successfully — but finds no service registration for itself
   (Consul removed all registrations when the node went offline during the reboot).
5. Consul pushes zero resources to Envoy → Envoy has zero listeners → all ports refuse
   connections.

**Why Consul removes the registration:** When a node goes offline, Consul removes all
service registrations for that node via its failure detection (gossip/heartbeat). This
happens regardless of the `-deregister-after-critical` flag — that flag only applies to
health check failures, not node-level failures.

**Why regular services are not affected:** Regular Nomad services declared with a `service {}`
block in the job spec are managed by Nomad directly. Nomad re-registers them in Consul on
every allocation start, including restores. The api-gateway has no native Nomad integration
and is not a service, so it bypasses this by registering itself manually in the setup task.

---

## Immediate fix (after a reboot)

Force a new allocation — this re-runs the setup task, re-registers the service in Consul,
and Envoy receives the full listener set from Consul xDS:

```bash
cd /data/scripts/deployment-descriptors-dev
nomad job stop api-gateway
nomad job run infrastructure/api-gateway/job.nomad.hcl
```

Verify:
```bash
# Service registered in Consul (must be non-empty):
curl http://localhost:8500/v1/catalog/service/api-gateway

# Envoy has listeners (must list all listeners):
curl http://<bridge-ip>:19000/listeners

# Port reachable:
nc -zv 127.0.0.1 20002
```

---

## Why `-deregister-after-critical 10s` made it worse

The original job spec used `-deregister-after-critical 10s`. This meant that if the
api-gateway Envoy health check failed for 10 seconds — e.g. during a normal Envoy restart
triggered by a Nomad job update — Consul would deregister the service. Envoy restarts
can take longer than 10 seconds, causing deregistration and then a stale xDS state.

This was changed to `300s` to give Envoy enough time to restart without losing its Consul
registration during brief outages. However, this does not help after a full node reboot,
because Consul removes the registration immediately when the node goes offline, regardless
of the deregister timeout.

---

## Permanent fix — setup task as persistent sidecar

Changing `setup` from a prestart oneshot to a prestart sidecar (`sidecar = true`) solves
the problem:

- A prestart sidecar starts before the main task AND is restarted whenever the allocation
  is restored (node reboot, Nomad agent restart, etc.).
- On every start, `setup` re-runs: `consul login` → `consul connect envoy -register` →
  re-registers the service in Consul → Consul pushes the full listener set to Envoy.
- The `api` task (Envoy) does not restart — its xDS connection to Consul is refreshed when
  the registration reappears.

The `setup` command ends with `sleep infinity` to keep the sidecar container alive (required
for Nomad to treat it as a running sidecar). The `api` task waits for bootstrap.json before
starting Envoy:

```hcl
# api task command (waits for setup to write bootstrap.json):
"until [ -s ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json ]; do sleep 1; done && exec envoy ..."
```

**JWT rotation:** With `sidecar = true` and `change_mode = "restart"`, Nomad restarts the
setup sidecar when the NWI JWT (1h TTL) rotates. The sidecar re-authenticates and
re-registers. The `api` task is not affected.

> **Note on `change_mode`:** Previously `change_mode = "restart"` was tried with
> `sidecar = false` (oneshot) and caused allocation failures on JWT expiry — Nomad tried
> to restart a task that had already exited. With `sidecar = true` the task is long-running,
> so restart on JWT rotation is valid and harmless.

---

## Investigation path that led to the fix

1. Customer reported `connect() failed (111: Connection refused)` on upstream port 20002
   after a node restart. The Nomad job appeared healthy.

2. Checked nginx — nginx itself was running and its upstream config was correct.

3. Checked whether the node primary IP worked where loopback did not — both refused.

4. Found that nothing was listening on port 20002 (`ss -tlnp | grep 20002` → empty).

5. Queried Envoy's admin API via the bridge namespace IP on port 19000 — returned empty
   (zero listeners). This confirmed Envoy was running but unconfigured.

6. Checked the Consul token — still valid, no expiration.

7. Queried the Consul catalog for the api-gateway service:
   ```bash
   curl http://localhost:8500/v1/catalog/service/api-gateway
   # → []
   ```
   Empty. The api-gateway was not registered in Consul. This was the root cause.

8. Verified the Consul config entry was intact:
   ```bash
   consul config read -kind api-gateway -name api-gateway
   # → returned full config (listeners, etc.) — config entries persist in Consul Raft
   ```

9. Confirmed that `nomad job stop` + `nomad job run` (forcing new allocation → setup task
   re-runs → re-registers → Consul pushes 17 listeners to Envoy) resolved the issue.

10. Traced why `nomad job run` alone (without stop) did not help: an existing running job
    with an unchanged spec does not create a new allocation — setup is not re-run.

11. Traced why the issue recurs after every reboot even with `deregister-after-critical 300s`:
    node-level failures cause immediate Consul deregistration regardless of the timeout.

12. Fix: changed `setup` from prestart oneshot to prestart sidecar, ensuring re-registration
    happens automatically on every allocation restore.
