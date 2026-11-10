# Routing Troubleshooting

A service is deployed and healthy in Nomad but requests are not reaching it.
Work through the layers from the outside in.

## Architecture reminder

```
Client
  └── nginx :8443 (TLS termination, hostname routing)
        └── API Gateway (Envoy) :8080 HTTP  or  :820x TCP
              └── Consul Connect intention check
                    └── Envoy sidecar
                          └── service container
```

Each layer can independently fail. Start at the outside and move in.

---

## Layer 1 — nginx: server block present and correct?

Check whether the service's hostname has a server block in the running nginx config:
```bash
nomad alloc exec -task nginx <nginx-alloc-id> nginx -T | grep -A15 "<service-hostname>"
```

**Common mistakes:**
- Server block missing entirely (service was onboarded but nginx job was not redeployed)
- Wrong `proxy_pass` port (TCP service should use the dedicated gateway port, HTTP service uses `:8080`)
- Wrong `server_name` (hostname typo)

**Fix:** Update the nginx job spec and redeploy.

---

## Layer 2 — API Gateway: listener and route configured?

**Check the gateway listener** (HTTPS-native / TCP services only — each needs its own port):
```bash
consul config read -kind api-gateway -name api-gateway
```
Verify a listener entry exists with the correct `Name` and `Port` for this service.

**Check the route:**
```bash
consul config list -kind tcp-route    # for HTTPS-native services
consul config list -kind http-route   # for plain HTTP services
consul config read -kind tcp-route -name <service>
consul config read -kind http-route -name <service>
```

**Common mistakes:**
- Route file was copy-pasted from another service and the `Name`, `Services[].Name`,
  and `Parents[].SectionName` fields still reference the old service.
- Route written but references a `SectionName` that doesn't exist in the gateway config.
- Gateway listener added but `consul config write gateway.consul.hcl` was not run,
  or the api-gateway job was not redeployed after adding a new port.

**Fix (no job restart needed for routes — Envoy reloads automatically):**
```bash
consul config write services/<service>/route.consul.hcl
```

**Fix (required when adding a new TCP listener):**
```bash
consul config write infrastructure/api-gateway/gateway.consul.hcl
nomad job run infrastructure/api-gateway/job.nomad.hcl
```

---

## Layer 3 — Consul intentions: traffic allowed?

```bash
consul config read -kind service-intentions -name <service>
```

The `api-gateway` must appear as an allowed source:
```hcl
Sources = [{ Name = "api-gateway", Action = "allow" }]
```

**Common mistakes:**
- Intentions file not written (onboarding script failed partway through)
- `api-gateway` not in the allow list
- Wrong destination service name in the intentions file

**Fix:**
```bash
consul config write services/<service>/intentions.consul.hcl
```

---

## Layer 4 — service-defaults: protocol declared?

```bash
consul config read -kind service-defaults -name <service>
```

Must be present and protocol must match the service type:
- `Protocol = "tcp"` for HTTPS-native services
- `Protocol = "http"` for plain HTTP services

**Important:** `service-defaults` must be applied **before** any route that references
the service. If applied after, rewrite the route to trigger Consul to re-evaluate it.

**Fix:**
```bash
consul config write services/<service>/defaults.consul.hcl
```

---

## Layer 5 — Connect sidecar: running and healthy?

```bash
# Sidecar health via Consul
consul health service <service>

# Sidecar task status in Nomad
nomad alloc status <alloc-id>

# Sidecar logs (Envoy)
nomad alloc logs <alloc-id> connect-proxy-<service>
```

If the sidecar is not running, check [CONNECT_SIDECAR_PITFALLS.md](CONNECT_SIDECAR_PITFALLS.md).

For east-west (service-to-service) upstream failures, see [CONNECT_UPSTREAM_TROUBLESHOOTING.md](CONNECT_UPSTREAM_TROUBLESHOOTING.md).

---

## Layer 6 — Service itself: responding inside the container?

```bash
nomad alloc exec -task app <alloc-id> curl -s http://localhost:<port>/health
```

If this fails, the problem is in the application, not the routing stack.

---

## End-to-end tests

**Bypass nginx — hit the API Gateway port directly** (confirms layers 2–6):
```bash
curl -vk --connect-to :<gw-port>:<node-ip>:<gw-port> https://<node-ip>:<gw-port>/
```

**Full path through nginx** (confirms all layers):
```bash
curl -vk --resolve <service-hostname>:8443:<node-ip> https://<service-hostname>:8443/
```

---

## Quick config consistency check

When a service is not reachable, verify all four config entries are present and
reference the **same service name** with no copy-paste errors:

```bash
SERVICE=<service-name>
consul config read -kind service-defaults   -name $SERVICE | grep -E 'Name|Protocol'
consul config read -kind service-intentions -name $SERVICE | grep -E 'Name|Action'
consul config read -kind tcp-route          -name $SERVICE | grep -E 'Name|SectionName'
consul config read -kind api-gateway        -name api-gateway | grep -E 'Name|Port'
```

A mismatch in any `Name` or `SectionName` field means traffic is silently dropped.
