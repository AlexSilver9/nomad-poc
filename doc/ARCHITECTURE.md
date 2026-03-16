# Cluster Architecture

## Current Solution: Traefik + Consul API Gateway

Traefik / Nginx sits between the ALB and the Consul API Gateway. Each layer has a single responsibility:

| Layer | Port | Responsibility |
|---|---|---|
| Traefik | :8081 (HTTP) / :8443 (HTTPS) | TLS termination, regex URL rewrite with capture groups |
| Consul API Gateway | :8080 (HTTP) / :8082 (TCP) | mTLS, hostname routing, service mesh entry point |
| Connect sidecar | dynamic | east-west mTLS, service-router (PrefixRewrite, traffic splitting) |

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
   │  Traefik :8081   │     │  Traefik :8081   │     │  Traefik :8081   │  HTTP: regex rewrite
   │  Traefik :8443   │     │  Traefik :8443   │     │  Traefik :8443   │  HTTPS: TLS term + rewrite
   │    ↓        ↓    │     │    ↓        ↓    │     │    ↓        ↓    │
   │  :8080    :8082  │     │  :8080    :8082  │     │  :8080    :8082  │  Consul API Gateway
   │  HTTP     TCP    │     │  HTTP     TCP    │     │  HTTP     TCP    │  HTTP routing / TCP pass
   │──────────────────│     │──────────────────│     │──────────────────│
   │  Sidecar (mTLS)  │     │  Sidecar (mTLS)  │     │  Sidecar (mTLS)  │  Connect Sidecar
   │        ↓         │     │        ↓         │     │        ↓         │  (automatic mTLS)
   │     Service      │     │     Service      │     │     Service      │  Application
   └──────────────────┘     └──────────────────┘     └──────────────────┘
```

Each Nomad node runs one Traefik allocation (system job, host network :8081), one API Gateway
allocation (static ports :8080/:8082), and zero or more service allocations (dynamic ports,
accessed only through their sidecar).

---

## HTTP routing (port 8081 via Traefik → 8080 API Gateway)

All HTTP traffic enters on port 8081 (Traefik). Traefik applies regex rewrites then forwards
to the API Gateway on port 8080. The API Gateway routes by `Host` header to the target service.

```text
Client
  │
  │  Host: business-service.example.com   GET /download/abc123
  ▼
Traefik :8081
  │
  ├─ PathPrefix /download  →  replacePathRegex: /download/(.*) → /business-service/download.xhtml?token=$1
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
  ├─ Host: business-service.example.com  GET /business-service/download.xhtml/abc123
  │    (path already rewritten by Traefik) ───────────────────────► business-service sidecar → business-service
  │
  ├─ Host: <unknown>  ─────────────────────────────────────────────► 404 (Envoy default)
  │
  └─ ...one http-route config entry per service
```

Routing rules live in `infrastructure/api-gateway/routes/<service>.consul.hcl` (http-route).
The gateway listener is declared in `infrastructure/api-gateway/gateway.consul.hcl`.
Traefik rules live in `infrastructure/traefik-rewrite/job.nomad.hcl`.

---

## TCP routing (port 8443 via Traefik → 8082 API Gateway)

HTTPS-native services speak TLS natively. Traefik terminates the client-facing TLS on port
:8443, applies any URL rewrite rules, re-encrypts, and forwards HTTPS to the API Gateway TCP
listener on :8082. The API Gateway passes the encrypted bytes through unchanged to the service,
which terminates the inner TLS.

```text
Client
  │
  │  HTTPS (TLS — client cert issued by ALB or Traefik)
  ▼
Traefik :8443
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
The Traefik job routes to that new port via a dedicated router entry in `dynamic.yaml`.

---

## URL rewrite capabilities by layer

| Rewrite type | Where | Applies to | Example |
|---|---|---|---|
| Regex with capture groups | Traefik | North-south | `/download/abc123` → `/business-service/download.xhtml?token=abc123` |
| Full-path replacement | API Gateway http-route | North-south | `/api` → `/business-service/api` |
| Prefix replacement (suffix-preserving) | service-router | East-west only | `/legacy-download/abc123` → `/business-service/download.xhtml/abc123` |

---

## Consul config entries

| File | Kind | Purpose |
|---|---|---|
| `infrastructure/api-gateway/gateway.consul.hcl` | `api-gateway` | Declares listeners (:8080 http, :8082 tcp) |
| `infrastructure/api-gateway/routes/<svc>.consul.hcl` | `http-route` / `tcp-route` | Hostname + path routing rules per service |
| `services/<svc>/defaults.consul.hcl` | `service-defaults` | Sets protocol (http/tcp) for each service |
| `services/<svc>/router.consul.hcl` | `service-router` | East-west path routing (not applied by API Gateway) |

---

## mTLS

All connections between the API Gateway and service sidecars are mutually authenticated
via TLS. Consul manages certificate issuance and rotation automatically. No TLS
configuration is needed in the service job specs.

The `X-Forwarded-Client-Cert` response header confirms mTLS is active.
