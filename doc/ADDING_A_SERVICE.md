# Adding a New Service

This document is the checklist for onboarding a new service into the cluster.

For background on why the steps are structured this way, see:
- [ARCHITECTURE.md](ARCHITECTURE.md) — overall traffic flow and layer responsibilities
- [CONFIGURATION_GUIDE.md](CONFIGURATION_GUIDE.md) — detailed config entry reference
- [API_GATEWAY.md](API_GATEWAY.md) — API Gateway internals and URL rewrite details
- [FILE_ORGANIZATION.md](FILE_ORGANIZATION.md) — where to put each file

---

## Infrastructure implications at a glance

| What changes | Plain HTTP service | HTTPS-native service |
|---|---|---|
| Consul config entries | `service-defaults`, `intentions`, `http-route` | `service-defaults`, `intentions`, `tcp-route` |
| `gateway.consul.hcl` | No change | New listener (new port) |
| `api-gateway/job.nomad.hcl` | No change | New static port in network block |
| `nginx-rewrite` / `traefik-rewrite` job | Only if regex URL rewrite needed | New server block / router rule for `:8443` hostname routing |
| Security group | No change | No change |
| ALB | No change | No change |
| Jobs to restart | None | `api-gateway` and `nginx-rewrite` / `traefik-rewrite` |
| Connection impact on existing services | **None** — Envoy reloads via xDS | **Brief drop** — all services interrupted during job restarts |

**Key constraint for HTTPS-native services**: the API Gateway TCP listener has no visibility
into the `Host` header (TLS is opaque at L4). Hostname routing for HTTPS is done by
nginx/Traefik after TLS termination, via `server_name` / `Host()` matching. Each HTTPS-native
service therefore requires its own dedicated port between the rewriter and the API Gateway.
The port is loopback-only (`127.0.0.1`) — no security group or ALB changes are needed.

---

## Plain HTTP service

Create the following files under `services/<svc>/`:

| File | Purpose |
|---|---|
| `defaults.consul.hcl` | Declare protocol (`http`) |
| `intentions.consul.hcl` | Allow inbound from `api-gateway` |
| `route.consul.hcl` | `http-route` — hostname routing via API Gateway |
| `job.nomad.hcl` | Nomad job spec |

Apply in order (service-defaults before route — Consul rejects a route if the protocol is not declared yet):

```bash
consul config write services/<svc>/defaults.consul.hcl
consul config write services/<svc>/intentions.consul.hcl
consul config write services/<svc>/route.consul.hcl
nomad job run services/<svc>/job.nomad.hcl
```

No changes to `gateway.consul.hcl`, `api-gateway/job.nomad.hcl`, or the rewriter job.
Consul config entry changes are picked up by Envoy via xDS — no restart needed.

### With regex URL rewrite

If the service needs a suffix-preserving URL rewrite (e.g. `/download/<token>` →
`/service/download.xhtml?token=<token>`), add a named location block in
`nginx-rewrite/job.nomad.hcl` above the catch-all proxy block (or the equivalent middleware
in `traefik-rewrite/job.nomad.hcl`), then redeploy the rewriter job.

See [API_GATEWAY.md — URL rewrite: what goes where](API_GATEWAY.md#url-rewrite-what-goes-where) for details on which layer handles which rewrite type.

---

## HTTPS-native service (speaks HTTPS internally)

Create the following files under `services/<svc>/`:

| File | Purpose |
|---|---|
| `defaults.consul.hcl` | Declare protocol (`tcp`) |
| `intentions.consul.hcl` | Allow inbound from `api-gateway` |
| `route.consul.hcl` | `tcp-route` — port-based routing via API Gateway |
| `job.nomad.hcl` | Nomad job spec |

Then make the following infrastructure changes:

1. **`infrastructure/api-gateway/gateway.consul.hcl`** — add a new TCP listener with a new
   port (e.g. 8083):
   ```hcl
   { Name = "new-svc", Port = 8083, Protocol = "tcp" }
   ```

2. **`infrastructure/api-gateway/job.nomad.hcl`** — add a matching static port in the
   network block:
   ```hcl
   port "new_svc" { static = 8083 }
   ```

3. **`infrastructure/nginx-rewrite/job.nomad.hcl`** — add a `server {}` block on port 8443
   that matches the service's hostname and re-encrypts to the new TCP listener:
   ```nginx
   server {
     listen 8443 ssl;
     server_name new-svc.example.com;
     proxy_pass https://127.0.0.1:8083;
   }
   ```
   Or add the equivalent `Host()` router rule in `traefik-rewrite/job.nomad.hcl`.

Apply and redeploy in that order:

```bash
consul config write services/<svc>/defaults.consul.hcl
consul config write services/<svc>/intentions.consul.hcl
consul config write infrastructure/api-gateway/gateway.consul.hcl
consul config write services/<svc>/route.consul.hcl
nomad job run services/<svc>/job.nomad.hcl
nomad job stop api-gateway && nomad job run infrastructure/api-gateway/job.nomad.hcl
nomad job run infrastructure/nginx-rewrite/job.nomad.hcl   # or traefik-rewrite
```

**Connection impact**: redeploying `api-gateway` and the rewriter as system jobs causes a
brief interruption for **all services**, not just the new one. Plan this as a short
maintenance window.
