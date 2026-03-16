# Traffic Flows in the Consul Service Mesh

## Key terms

| Term | Meaning |
|---|---|
| **North-south** | Traffic crossing the cluster boundary — external clients talking to services |
| **East-west** | Traffic between services inside the cluster |
| **Upstream** | The target a proxy forwards requests *to* |
| **Downstream** | The caller a proxy receives requests *from* |
| **Sidecar proxy** | An Envoy container injected alongside each service, handling all network traffic for it |

---

## North-south: external client → service

An external client (browser, mobile app, ALB health check) reaches a service through
**Traefik** (port 8081) and then the **Consul API Gateway** (port 8080).
Each layer has one job:

```
External client
      │
      ▼
[ Load Balancer ]  (AWS ALB)
      │
      ▼  port 8081
[ Traefik ]
      │
      │  Regex URL rewrite with capture groups
      │  Example: /download/abc123 → /business-service/download.xhtml?token=abc123
      │  Host header forwarded unchanged.
      │
      ▼  port 8080
[ API Gateway (Envoy) ]
      │
      │  Routing config: http-route (Consul config entries)
      │  Matches: hostname + path (path already rewritten by Traefik if needed)
      │
      ├─ Host: pet-shop.example.com  ──────────────────────────────────┐
      │                                                                 │
      └─ Host: database.example.com  ──────────── (not exposed)       │
                                                                       ▼
                                                        [ pet-shop-service sidecar ]
                                                                       │  mTLS
                                                                       ▼
                                                        [ pet-shop-service container ]
```

Each layer's rewrite capability:

| Layer | Rewrite type | Suffix preserved |
|---|---|---|
| Traefik | Regex with capture groups | ✅ |
| API Gateway (`http-route` URLRewrite.Path) | Full-path replacement only | ❌ |

---

## East-west: service talking to another service

When `pet-shop-service` calls `database-service` internally, traffic flows through
**sidecar proxies** on both ends. No API Gateway is involved.

```
[ pet-shop-service container ]
      │  localhost:5432 (configured upstream port)
      ▼
[ pet-shop-service sidecar (Envoy) ]
      │
      │  Routing config: service-router (Consul config entry)
      │  Applied by the SOURCE sidecar before forwarding.
      │  Supports: PrefixRewrite, service splitting, traffic shaping.
      │
      ▼  mTLS (mutual TLS — automatic, no cert management needed)
[ database-service sidecar (Envoy) ]
      │
      ▼
[ database-service container ]
```

The `service-router` for `database-service` would live in
`services/database-service/router.consul.hcl` and is applied by the
`pet-shop-service` sidecar when it resolves where to send the request.

---

## Why the API Gateway does not apply service-router rules

The API Gateway is not a regular sidecar — it manages its own routing config from
`http-route` entries. When it forwards to `pet-shop-service`, it resolves endpoints
directly from Consul's service catalog and applies only its own rules. It never
consults the service-router.

```
NORTH-SOUTH (API Gateway):
  client → [ API Gateway ] → [ pet-shop sidecar ] → [ pet-shop container ]
                │
                applies: http-route  (URLRewrite.Path = full replacement only)
                ignores: service-router

EAST-WEST (sidecar-to-sidecar):
  [ pet-shop sidecar ] → [ database sidecar ] → [ database container ]
         │
         applies: service-router  (PrefixRewrite = suffix-preserving)
         ignores: http-route
```

This is why a `PrefixRewrite` in a service-router has no effect on traffic
arriving via the API Gateway. See [HTTPS_ROUTING.md](HTTPS_ROUTING.md) and
`infrastructure/api-gateway/routes/` for the current routing configuration.

---

## Upstream / downstream from a proxy's perspective

```
Request direction  →→→→→→→→→→→→→→→→→→→→→→→→→

[ Caller ]   →→→   [ Proxy / Sidecar ]   →→→   [ Target service ]
 DOWNSTREAM              │       │                   UPSTREAM
 (requests               │       │                   (requests go
  arrive from here)  downstream  upstream             to here)
                     connection  connection

API Gateway example:
  downstream = external client (browser)
  upstream   = pet-shop-service sidecar

pet-shop-service sidecar (receiving from gateway):
  downstream = API Gateway
  upstream   = pet-shop-service container (localhost)

pet-shop-service sidecar (making an internal call to database-service):
  downstream = pet-shop-service container
  upstream   = database-service sidecar
```

---

## mTLS

All sidecar-to-sidecar connections (including API Gateway → upstream sidecar) use
mutual TLS automatically. Consul manages certificate rotation — services and the
gateway need no TLS configuration of their own. The `X-Forwarded-Client-Cert` header
on responses confirms mTLS is active.
