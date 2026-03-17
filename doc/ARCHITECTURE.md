# Cluster Architecture

## Current Solution: nginx/Traefik + Consul API Gateway

nginx or Traefik sits between the ALB and the Consul API Gateway. Each layer has a single responsibility:

| Layer | Port | Responsibility |
|---|---|---|
| nginx **or** Traefik | :8081 (HTTP) / :8443 (HTTPS) | TLS termination, regex URL rewrite with capture groups |
| Consul API Gateway | :8080 (HTTP) / :8082 (TCP) | Hostname routing, service mesh entry point |
| Connect sidecar | dynamic | east-west mTLS, service-router (PrefixRewrite, traffic splitting) |

nginx and Traefik are interchangeable — both listen on the same ports and pass all routing tests.
Only one can run at a time (port conflict). nginx is preferred for production (correct `?token=`
query-param rewrite format; Traefik v3 produces a path-based variant).

```text
                    ┌─────────────────────────────────────────────────┐
                    │                   AWS ALB                       │
                    │  Target Group: all instances :8081/:8443        │
                    └──────────────────┬──────────────────────────────┘
                                       │
            ┌──────────────────────────┼──────────────────────────┐
            ▼                          ▼                          ▼
   ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
   │      nomad1      │     │      nomad2      │     │      nomad3      │  Nomad Cluster
   │──────────────────│     │──────────────────│     │──────────────────│
   │ nginx/Traefik    │     │ nginx/Traefik    │     │ nginx/Traefik    │
   │  :8081 (HTTP)    │     │  :8081 (HTTP)    │     │  :8081 (HTTP)    │  regex rewrite
   │  :8443 (HTTPS)   │     │  :8443 (HTTPS)   │     │  :8443 (HTTPS)   │  TLS term + rewrite + re-ecnrypt
   │    ↓        ↓    │     │    ↓        ↓    │     │    ↓        ↓    │
   │  :8080    :8082  │     │  :8080    :8082  │     │  :8080    :8082  │  Consul API Gateway
   │  HTTP     TCP    │     │  HTTP     TCP    │     │  HTTP     TCP    │  HTTP routing / TCP pass
   │──────────────────│     │──────────────────│     │──────────────────│
   │  Sidecar (mTLS)  │     │  Sidecar (mTLS)  │     │  Sidecar (mTLS)  │  Connect Sidecar
   │        ↓         │     │        ↓         │     │        ↓         │  (automatic mTLS)
   │     Service      │     │     Service      │     │     Service      │  Application
   └──────────────────┘     └──────────────────┘     └──────────────────┘
```

Each Nomad node runs one rewriter allocation (nginx or Traefik, system job, host network
:8081/:8443), one API Gateway allocation (system job, bridge network, static ports
:8080/:8082), and zero or more service allocations (bridge network, dynamic ports, accessed
only through their sidecar).

The API Gateway is an Envoy proxy running as a two-task Nomad system job (`setup` prestart +
`api` main). It is NOT configured via Nomad's `gateway` stanza — that does not support the
`api` type. See [API_GATEWAY.md](API_GATEWAY.md) for details.

#### Responsibility split — nginx vs API Gateway:

| Layer | Responsibility |
|---|---|
| nginx/Traefik | **Hostname-based routing** for **HTTPS** traffic (via `server_name` after TLS termination); regex URL rewrites with capture groups |
| API Gateway (Envoy) | **Service discovery and resolution** — routes to the current location of a service via Consul's live service catalog (xDS); **Hostname-based routing** for plain **HTTP** |

nginx/Traefik runs on **host network** and always forwards to `127.0.0.1:8080` / `127.0.0.1:8082` — the API Gateway on the **same node**. When a service allocation is rescheduled to a different node, nginx configuration does not change. The API Gateway receives xDS updates from Consul automatically and routes to the new location. nginx/Traefik decides *which service* to send traffic to (via `server_name` matching); the API Gateway decides *where that service currently is* (via Consul).

#### Adding services — infrastructure implications

Plain HTTP services require only Consul config entries and a Nomad job — no port or infrastructure changes.

Every HTTPS-native service requires a new dedicated internal port between the rewriter and the API Gateway: new TCP listener in `gateway.consul.hcl`, new static port in `job.nomad.hcl`, new server block in the rewriter job. No security group or ALB changes are needed — the new port is loopback-only (`127.0.0.1`), and the ALB already forwards all `:8443` traffic to nginx/Traefik which handles hostname routing.

See [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) for the full checklist.

---

## HTTP routing (port 8081 via rewriter → 8080 API Gateway)

All HTTP traffic enters on port 8081 (nginx or Traefik). The rewriter applies regex rewrites
then forwards to the API Gateway on port 8080. The API Gateway routes by `Host` header to
the target service.

```text
Client
  │
  │  Host: business-service.example.com   GET /download/abc123
  ▼
nginx/Traefik :8081
  │
  ├─ PathPrefix /download  →  regex rewrite: /download/(.*) → /business-service/download.xhtml?token=$1
  │    (suffix-preserving regex rewrite — not possible in API Gateway alone)
  │
  └─ all other paths  →  forward unchanged (Host header preserved)
  │
  ▼
API Gateway :8080
  │
  ├─ Host: web-service.example.com  ──────────────────────────────► web-service sidecar → web-service
  │
  ├─ Host: business-service.example.com  GET /api ────────────────► business-service sidecar → business-service
  │    URLRewrite: /api → /business-service/api  (full-path replacement — static paths only)
  │
  ├─ Host: business-service.example.com  GET /business-service/download.xhtml?token=abc123
  │    (path already rewritten by rewriter) ──────────────────────► business-service sidecar → business-service
  │
  ├─ Host: <unknown>  ─────────────────────────────────────────────► 404 (Envoy default)
  │
  └─ ...one http-route config entry per service
```

Routing rules live in `services/<service>/route.consul.hcl` (http-route).
The gateway listener is declared in `infrastructure/api-gateway/gateway.consul.hcl`.
Rewriter rules live in `infrastructure/nginx-rewrite/job.nomad.hcl` or
`infrastructure/traefik-rewrite/job.nomad.hcl`.

---

## TCP routing (port 8443 via rewriter → 8082 API Gateway)

HTTPS-native services speak TLS natively. nginx/Traefik terminates the client-facing TLS on
port :8443. Once TLS is terminated, the rewriter has the plaintext request and can read the
`Host` header — this is where **hostname-based routing happens for HTTPS traffic**
(nginx `server_name` / Traefik `Host()` rule matching). The rewriter then either forwards
plain HTTP to the API Gateway HTTP listener (:8080) for regular services, or re-encrypts and
forwards to the API Gateway TCP listener (:8082) for HTTPS-native services. The API Gateway
passes the encrypted bytes through unchanged to the service, which terminates the inner TLS.

```text
Client
  │
  │  HTTPS (TLS)
  ▼
nginx/Traefik :8443  (TLS termination)
  │
  ├─ Host: https-service.example.com  →  re-encrypt → API Gateway :8082
  │    (TLS terminated, URL rewrite applied if needed, new TLS connection opened to :8082)
  │
  └─ Host: <any other>  →  forward HTTP → API Gateway :8080  (plain HTTP services)
  │
  ▼
API Gateway :8082
  │
  └─ TCP passthrough ──────────────────────────────► https-service sidecar → https-service (HTTPS)
       (no hostname routing — one port per HTTPS-native service)
```

Because TCP has no `Host` header, one listener port is required per HTTPS-native service.
Each additional HTTPS service needs a new port in `gateway.consul.hcl` and `job.nomad.hcl`.
The rewriter job routes to that new port via a dedicated server block (nginx) or router
entry (Traefik).

---

## URL rewrite capabilities by layer

| Rewrite type | Where | Applies to | nginx output | Traefik v3 output |
|---|---|---|---|---|
| Regex with capture groups | nginx or Traefik | North-south | `?token=abc123` (query-param) | `/abc123` (path-based) |
| Full-path replacement | API Gateway http-route | North-south | — | — |
| Prefix replacement (suffix-preserving) | service-router | East-west only | — | — |

---

## Consul config entries

| File | Kind | Purpose |
|---|---|---|
| `infrastructure/api-gateway/gateway.consul.hcl` | `api-gateway` | Declares listeners (:8080 http, :8082 tcp) |
| `services/<svc>/route.consul.hcl` | `http-route` / `tcp-route` | Hostname + path routing rules per service |
| `services/<svc>/defaults.consul.hcl` | `service-defaults` | Sets protocol (http/tcp) for each service |
| `services/<svc>/router.consul.hcl` | `service-router` | East-west path routing (not applied by API Gateway) |

---

## mTLS

All connections between the API Gateway and service sidecars are mutually authenticated
via TLS. Consul manages certificate issuance and rotation automatically. No TLS
configuration is needed in the service job specs.

The `X-Forwarded-Client-Cert` response header confirms mTLS is active.
