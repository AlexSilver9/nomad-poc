# Sticky Sessions for HTTPS-Native Services

## Problem

Java web services (e.g. on Payara) often share HTTP session state through an embedded Hazelcast
cluster, which is unsecured in the community editions (see [HAZELCAST_MESH.md](HAZELCAST_MESH.md)).
Alternatives are securing Hazelcast through the mesh or an external session store
(see [REDIS_SESSIONS.md](REDIS_SESSIONS.md)).

The simplest alternative needs neither: run several instances **without** session sharing and
make sessions **sticky**:

- A service runs with **2 instances**
- No session sharing — each instance is independent
- **Sticky sessions**: a user always lands on the same instance

The catch: the services speak **HTTPS natively**, so the routing layer behind the TLS-terminating proxy only sees TCP streams.

### Traffic path

```text
ALB → nginx :443 (TLS termination, hostname routing)
    → re-encrypt → 127.0.0.1:<port> API Gateway (TCP listener, one port per service)
    → mTLS → sidecar → service :8443 (HTTPS)
```

Because the service speaks HTTPS, everything behind nginx is a **TCP stream** for Consul and
Envoy. This decides where stickiness can happen:

| Layer | Sticky possible? | Why |
|---|---|---|
| ALB stickiness | ❌ | ALB targets are **nodes**, not service instances. The API Gateway behind it picks an instance cluster-wide |
| API Gateway / mesh | ❌ | Load-balancer hash policies (cookie, header) require `Protocol = "http"`. With an HTTPS backend Envoy sees encrypted bytes only. Source-IP hashing is useless: behind nginx every connection comes from `127.0.0.1` |
| nginx | ✅ | Terminates TLS, sees cookies — but only works if nginx can address **each instance individually**. With one gateway port per service, the gateway load-balances behind it |

Both options below do the stickiness in nginx. They differ in **how nginx reaches one specific
instance**.

---

## Common part: nginx route cookie + consistent hash

nginx OSS has no `sticky` directive (nginx Plus only). Instead: an own route cookie and
`hash … consistent`:

```nginx
# Route key: the STICKY_ROUTE cookie, or a new random key on the first request
map $cookie_STICKY_ROUTE $sticky_route_key {
    ""      $request_id;
    default $cookie_STICKY_ROUTE;
}
# Set-Cookie only on the first request (add_header skips empty values)
map $cookie_STICKY_ROUTE $sticky_set_cookie {
    ""      "STICKY_ROUTE=$request_id; Path=/; Secure; HttpOnly";
    default "";
}

upstream my_service {
    hash $sticky_route_key consistent;
    server <instance 0> max_fails=1 fail_timeout=10s;
    server <instance 1> max_fails=1 fail_timeout=10s;
}

location / {
    proxy_pass            https://my_service;
    proxy_connect_timeout 2s;
    proxy_next_upstream   error timeout;     # instance down → try the other one
    add_header            Set-Cookie $sticky_set_cookie always;
}
```

The first request gets a random key, the hash picks the instance, and the cookie keeps the key →
all following requests hit the same instance.

Why not other hash keys:

| Key | Problem |
|---|---|
| `$cookie_JSESSIONID` | First request has no cookie → instance A creates the session, but its cookie value later hashes to (maybe) instance B |
| `$remote_addr` (real IP via `real_ip_header`) | Breaks on client IP change (mobile Wi-Fi ↔ LTE); corporate NAT concentrates users on one instance |

---

## Option A: nginx → instances directly (bypasses the mesh)

```text
ALB → nginx :443 (TLS term, route cookie, hash)
    → service instance host port (HTTPS, published dynamic port)     ← bypasses API Gateway + mesh
```

The instance list comes from the Consul catalog — a Nomad `template` renders the upstream (only
passing instances) and reloads nginx on change:

```nginx
upstream my_service {
    hash $sticky_route_key consistent;
{{- range service "my-service" }}
    server {{ .Address }}:{{ .Port }} max_fails=1 fail_timeout=10s;
{{- else }}
    server 127.0.0.1:1 down;   # service not deployed - keeps the nginx config valid
{{- end }}
}
```

Required changes compared to a static nginx setup:

| Change | Detail |
|---|---|
| nginx job: `template` block | The upstream must be rendered by Nomad (`change_mode = "signal"`, `SIGHUP`) into a **directory** mount (consul-template replaces the file; a single-file bind mount would keep the old inode) |
| nginx job: Consul token | `identity { name = "consul_default" … }` + a binding rule granting `service:read`. Without a token Consul ACLs **silently filter** the catalog → empty upstream, no error |
| Security groups | nginx on node X connects to the dynamic host ports (20000–32000) of instances on other nodes |
| Service host port | Must be published (a `port` in the job's `network` block) |

Downside: these services leave the mesh — no mTLS identity and no intentions between nginx and
the service.

---

## Option B: nginx → one API Gateway port per instance (stays in the mesh)

Reuses the Hazelcast mesh pattern ([HAZELCAST_MESH.md](HAZELCAST_MESH.md)): each instance gets
its own virtual service, and the API Gateway one TCP listener per virtual service.

```text
ALB → nginx :443 (TLS term, route cookie, hash)
    → 127.0.0.1:<port 0> → API Gateway listener my-service-0 → tcp-route → my-service-0
    → 127.0.0.1:<port 1> → API Gateway listener my-service-1 → tcp-route → my-service-1
         my-service-<N> = virtual service → redirect → subset ordinal-<N> of my-service
    → mTLS → sidecar → service instance N (HTTPS)
```

| Piece | Content |
|---|---|
| Job | `count = 2`, tag `ordinal-${NOMAD_ALLOC_INDEX}` on the service **and** `sidecar_service` (subset filters are evaluated against the sidecar) |
| `service-resolver` | Subsets `ordinal-0`, `ordinal-1` with tag filter + `OnlyPassing = true` |
| Redirect resolvers | `my-service-<N>` → subset `ordinal-<N>` |
| API Gateway | One TCP listener + static port per instance (instead of per service) |
| `tcp-route` | Listener `my-service-<N>` → service `my-service-<N>` |
| Intentions | Unchanged: `api-gateway → my-service` (intentions apply to the real service) |
| nginx | **Static** upstream `server 127.0.0.1:<port 0>; server 127.0.0.1:<port 1>;` — no Consul access needed |

An unhealthy instance has no endpoint in its subset → its gateway port drops the connection →
`proxy_next_upstream` sends the request to the other instance.

Downside: fixed instance count (scaling = new gateway listener + port + config entries), and
changing gateway listeners redeploys the API Gateway (brief interruption of all services).

---

## Failover and deployments

Neither option shares sessions — a user whose instance goes away has to log in again.

| Event | Option A | Option B |
|---|---|---|
| Instance stops | Its users move to the other instance (login) | Same |
| Users of the surviving instance | Stay — until the replacement comes back: it has a **new address** → nginx's hash ring changes → part of them is remapped (login) | **Always stay** — the replacement gets the same ordinal → same gateway port → hash ring never changes |
| Users of the failed instance when the replacement is back | Partly back to the new instance (login) | All back to the new instance (second login) |
| Rolling deployment (both instances replaced one by one) | Every user logs in again, some twice | Every user logs in twice (to the other instance and back) |

---

## Comparison

| | Option A: nginx → instances | Option B: gateway port per instance |
|---|---|---|
| Application change | None | None |
| Stays in mesh (mTLS, intentions) | ❌ | ✅ |
| nginx config | Templated from Consul + Consul token | Static |
| Gateway / Consul config | None | Resolver, 2 redirects, 2 tcp-routes, 1 extra listener + port per service |
| Instance count | Free (template follows) | Fixed |
| Users of the surviving instance on failover | Partly logged out when the replacement returns | Never logged out |
| Removal | Revert nginx template | Revert gateway listeners + config entries |
| Uncertainty | Consul token for the nginx template | API Gateway `tcp-route` to a virtual service (accepted + bound on Consul 2.0.4 dev agent; runtime pending) |

---

## Common to both options

| Topic | Effect / Action |
|---|---|
| `count = 2` | In the service's job spec |
| Shared volumes | Both instances would write into the same log / data directories → per-alloc directories (e.g. a prestart task creating `<dir>/${NOMAD_ALLOC_ID}`) |
| Per-instance in-memory state | Exists twice: timers/crons, caches, rate-limit or lockout counters — check that this is uncritical |
| `Secure` cookie flag | Set by nginx (TLS terminated there) |

---

## Not applicable: Envoy cookie hash in the API Gateway

With `Protocol = "http"` the API Gateway could do the stickiness itself (service-resolver
`LoadBalancer` maglev + cookie hash, per a
[HashiCorp support article](https://support.hashicorp.com/hc/en-us/articles/42765807161107-How-to-Enable-Cookie-Based-Session-Affinity-with-Consul-ServiceResolver-and-Maglev-Load-Balancer)).
This requires the service to serve **plain HTTP** internally (plus `X-Forwarded-Proto` scheme
mapping) — not applicable to HTTPS-native services, so it is out of scope here.

---

## POC

Shared test service `aws/services/sticky-https-service/`: 2 HTTPS instances (nginx with a
self-signed cert stands in for the application server), the response names the instance
(`sticky-0` / `sticky-1`).
nginx: each option has its own test variant of `infrastructure/nginx-rewrite` with the **same job
name** — `nomad job run` replaces the regular nginx in place (same host ports, one router). The
variants contain **only** the sticky test route, so other hostnames are not routed during a test.
The regular nginx-rewrite job stays unchanged (static).
- **A**: `services/sticky-https-service/nginx-a.nomad.hcl` — server `sticky-a.example.com`,
  Consul identity + instance-list template.
- **B**: `services/sticky-https-service/nginx-b.nomad.hcl` — server `sticky-b.example.com`, static.

Both scripts switch from traefik to the variant and restore the regular nginx-rewrite in cleanup
(if a script stops early it prints the restore command:
`nomad job run infrastructure/nginx-rewrite/job.nomad.hcl`).

| Script | Steps |
|---|---|
| `bin/instance/sticky_nginx_direct.sh` (A) | Switch to nginx variant A → deploy → **rendered upstream per nginx node** (2 servers, not `down`) → requests without cookie → 6 clients rotating over all nodes → failover |
| `bin/instance/sticky_gateway_ordinal.sh` (B) | Switch to nginx variant B → API Gateway listeners 8083/8084 → Consul entries + deploy → **per-instance gateway ports** (`:8083` only `sticky-0`, `:8084` only `sticky-1`, on every node) → requests without cookie → 6 clients → failover |

Both require `NOMAD_TOKEN` and `CONSUL_HTTP_TOKEN`; B requires enforced ACLs (intention needed).

---

## Status

| Item | Status |
|---|---|
| nginx config (`nginx -t`) with rendered and empty upstream | ✅ locally |
| nginx cookie + hash: Set-Cookie on first request only, 6 clients sticky, failover without errors, return after recovery | ✅ locally (Docker, 2 HTTPS backends) |
| Nomad 2.0.7: all jobs validate + plan | ✅ locally |
| Consul 2.0.4: `tcp-route` to virtual service accepted + bound; chain → single subset `ordinal-N`, tcp, OnlyPassing | ✅ dev agent |
| POC cluster: Option A (`sticky_nginx_direct.sh`) | ⏳ |
| POC cluster: Option B (`sticky_gateway_ordinal.sh`) | ⏳ |

Sources:
- [nginx upstream `hash`](https://nginx.org/en/docs/http/ngx_http_upstream_module.html#hash)
- [Consul service-resolver reference](https://developer.hashicorp.com/consul/docs/reference/config-entry/service-resolver)
- [Consul tcp-route reference](https://developer.hashicorp.com/consul/docs/reference/config-entry/tcp-route)
