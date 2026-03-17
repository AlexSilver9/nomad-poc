# Consul API Gateway on Nomad

This document describes the Consul API Gateway solution: what it is, how it fits into the
cluster, how traffic flows through it, how routes are configured, and how to operate it.

For the authentication mechanism (Nomad Workload Identity), see [NWI.md](NWI.md).

## What is the Consul API Gateway

The Consul API Gateway is an Envoy-based ingress gateway that replaces the older Consul
ingress gateway (deprecated in Consul 1.22). It handles north-south traffic — requests
entering the cluster from outside — and routes them to the correct service based on HTTP
Host headers, paths, and rules defined in Consul config entries.

Key properties:
- Runs on every node as a Nomad `system` job (one Envoy process per node)
- Routes HTTP traffic by Host header — all services share a single port (8080)
- Routes TCP traffic by dedicated port — one port per HTTPS-native backend (8082, 8083, ...)
- Config-driven: routes are Consul config entries, not Nomad job parameters
- Replaces the deprecated Consul ingress gateway

## Architecture

```
Internet / ALB
      │
      ├── :8081 (HTTP)   ──► nginx/Traefik :8081 ──► API Gateway :8080 ──► Envoy sidecar ──► service
      │
      └── :8443 (HTTPS)  ──► nginx/Traefik :8443 (TLS termination)
                                  │
                                  ├── plain HTTP services ──► API Gateway :8080 ──► sidecar ──► service
                                  └── HTTPS-native services ──► API Gateway :8082 (TCP) ──► service
```

nginx/Traefik sits between the ALB and the API Gateway. It handles:
- **TLS termination** on :8443, enabling HTTP-level routing and URL rewrites over HTTPS
- **Regex URL rewrite** with capture groups (e.g. `/download/<token>` → `/service/download.xhtml?token=<token>`)
- **Hostname-based routing** to forward to the correct API Gateway listener

The API Gateway (Envoy) handles:
- **HTTP routing** by Host header on :8080 — all HTTP services share this port
- **Static path rewrites** via `URLRewrite` rules in HTTPRoute config entries
- **TCP passthrough** on :8082 for HTTPS-native backends

## Why a rewriter (nginx/Traefik) in front

The API Gateway operates at L7 (HTTP) for plain services and L4 (TCP) for HTTPS-native
services. Two capabilities require a rewriter in front:

1. **Regex URL rewrite**: the API Gateway's `URLRewrite` only supports full-path replacement
   (no capture groups, no query-param injection). Regex rewrites with capture groups — e.g.
   `/download/abc123` → `/service/download.xhtml?token=abc123` — must be done upstream.

2. **TLS termination for HTTPS hostname routing**: the API Gateway TCP listener has no
   visibility into the Host header (TLS is opaque at L4). Without TLS termination upstream,
   hostname-based routing is impossible for HTTPS traffic. nginx/Traefik terminates TLS on
   :8443, decrypts the request, applies hostname routing and URL rewrites, then either
   forwards plain HTTP to the API Gateway HTTP listener (:8080) or re-encrypts to the TCP
   listener (:8082) for HTTPS-native backends.

## Nomad job: two-task pattern

The Consul API Gateway has no native Nomad jobspec integration — Nomad's `gateway` stanza
only supports ingress, terminating, and mesh types, not `api`. The current approach is a
two-task `system` job:

```
Task "setup" (prestart, exits after completion)
  └─ hashicorp/consul image
     ├─ consul login  →  exchanges NWI JWT for a Consul ACL token
     └─ consul connect envoy -gateway api -bootstrap  →  writes envoy_bootstrap.json to alloc dir

Task "api" (main, long-running)
  └─ envoyproxy/envoy image
     └─ envoy --config-path envoy_bootstrap.json  →  starts Envoy with bootstrap config from setup
```

The `setup` task is a `prestart` lifecycle task — it runs to completion before `api` starts.
The bootstrap config written to `${NOMAD_ALLOC_DIR}/envoy_bootstrap.json` is shared between
the two tasks via the allocation directory.

Both tasks run in bridge networking mode (required for Consul Connect CNI).

**Important**: `CONSUL_HTTP_ADDR` and `CONSUL_GRPC_ADDR` in the `setup` task must use the
node's primary IP (not `127.0.0.1`) because bridge networking containers cannot reach the
host loopback.

## Consul config entries

The API Gateway is configured through three layers of Consul config entries:

### 1. Gateway (`gateway.consul.hcl`)

Declares the listeners — which ports Envoy should bind to and what protocol each uses:

```hcl
Kind = "api-gateway"
Name = "api-gateway"

Listeners = [
  { Name = "http",         Port = 8080, Protocol = "http" },
  { Name = "https-service", Port = 8082, Protocol = "tcp"  },
]
```

Add a new listener entry here (and a matching port in `job.nomad.hcl`) for each
additional HTTPS-native service.

### 2. Routes (`services/<svc>/route.consul.hcl`)

Routes connect incoming traffic to backend services. Each service owns its route file alongside its other Consul config entries in `services/<svc>/`. Two route types are used:

**HTTPRoute** — for plain HTTP services, matched by Host header:

```hcl
Kind      = "http-route"
Name      = "web-service"
Hostnames = ["web-service.example.com"]

Rules = [{ Services = [{ Name = "web-service" }] }]

Parents = [{ Kind = "api-gateway", Name = "api-gateway", SectionName = "http" }]
```

HTTPRoutes support path matching and static `URLRewrite`. They do NOT support regex
rewrites or query-param injection — those must be handled by the rewriter (nginx/Traefik) upstream.

**TCPRoute** — for HTTPS-native services, matched by port (no Host header visibility):

```hcl
Kind = "tcp-route"
Name = "https-service"

Services = [{ Name = "https-service" }]

Parents = [{ Kind = "api-gateway", Name = "api-gateway", SectionName = "https-service" }]
```

### 3. Service-defaults

Every service must have a `service-defaults` config entry declaring its protocol
(`http` or `tcp`). This must be applied **before** any route that references the service,
otherwise Consul rejects the route with an inconsistent-protocol error.
See `services/<svc>/defaults.consul.hcl`

## URL rewrite: what goes where

| Layer | Mechanism | Supports |
|---|---|---|
| nginx/Traefik | `rewrite` directive / `replacePathRegex` middleware (regex) | Capture groups, query-param injection |
| API Gateway | `URLRewrite` in HTTPRoute | Full-path replacement only (no suffix, no regex) |
| Consul service-router | `PrefixRewrite` | Prefix replacement, suffix preserved (east-west only — not applied by API Gateway) |

Example: `/download/abc123` → `/business-service/download.xhtml?token=abc123`
- nginx/Traefik rewrites: captures `abc123`, builds query-param URL → passes to API Gateway
- API Gateway routes by Host header to `business-service`
- Service sidecar delivers to the container

## Adding a new service

See [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) for the full checklist — infrastructure
implications, required files, apply order, and connection impact.

## Operations

**Apply a new or updated route** (no job restart needed — Envoy reloads automatically):
```bash
consul config write services/<service>/route.consul.hcl
```

**Update the gateway listeners** (requires api-gateway job restart):
```bash
consul config write infrastructure/api-gateway/gateway.consul.hcl
nomad job stop api-gateway && nomad job run infrastructure/api-gateway/job.nomad.hcl
```

**Check Envoy routing state** (admin API on any node):
```bash
curl http://localhost:19000/config_dump    # full Envoy config
curl http://localhost:19000/clusters       # upstream clusters (registered services)
curl http://localhost:19000/listeners      # active listeners
```

**Check api-gateway job status**:
```bash
nomad job status api-gateway
nomad alloc logs <alloc-id> api     # Envoy logs
nomad alloc logs <alloc-id> setup   # setup task logs (NWI login, bootstrap)
```

## ACL and Nomad Workload Identity

When Consul ACL is in deny mode, the `setup` task must present a valid Consul token to
`consul connect envoy -gateway api`. This is handled via Nomad Workload Identity (NWI):
the `setup` task has an `identity` block that causes Nomad to mint a signed JWT, which is
exchanged for a scoped Consul token via `consul login`.

Full details: [NWI.md](NWI.md)

## Version compatibility

| Component | Version | Notes |
|---|---|---|
| Consul | 1.22.3 | API Gateway GA since 1.15; ingress gateway deprecated in 1.22 |
| Envoy | v1.35.8 | Must be compatible with Consul 1.22.x (requires Envoy 1.30+) |
| Nomad | 1.11.2 | NWI `identity` block with `env = true` required |

Keep Envoy version in sync with what Nomad uses for Connect sidecars on the cluster.

## References

- https://github.com/hashicorp-guides/consul-api-gateway-on-nomad — official guide repo (two-task pattern origin)
- https://developer.hashicorp.com/nomad/tutorials/integrate-consul/deploy-api-gateway-on-nomad
- https://developer.hashicorp.com/consul/docs/reference/config-entry/api-gateway
- https://developer.hashicorp.com/consul/docs/reference/config-entry/http-route
- https://developer.hashicorp.com/consul/docs/reference/config-entry/tcp-route
