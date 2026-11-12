# Hazelcast Cluster via Consul Service Mesh

## Problem

Payara web services share HTTP session state via **Payara clustering**, which uses an embedded
**Hazelcast** member inside every Payara instance. Every Hazelcast member must open a TCP
connection to **every other member** of its cluster.

Current setup (example):

| Aspect | Current state |
|---|---|
| Discovery | Hazelcast queries the Consul catalog (`CLUSTER_MODE=CONSUL`) — requires a Consul RO token in the job |
| Transport | Plain TCP on a **published dynamic host port** (`port "hazelcast" { to = 5701 }`) |
| Encryption | None |
| Authentication | None — anything that can reach the host port and knows the cluster name can join |

Anyone inside the VPC — or any container of any team on the cluster nodes — can join the
Hazelcast cluster or read session data off the wire.

### Options considered

| Option | Verdict |
|---|---|
| Hazelcast TLS / security (SocketInterceptor, member auth) | Enterprise only |
| Payara Data Grid encryption | Enterprise only |
| stunnel / custom TLS tunnel | Works, but manual PKI and peer lists — re-implements what Consul already does |
| Normal mesh upstream to `hz` service | Load-balances across members — cannot address one **specific** member |
| Transparent proxy | Only one `connect` block per group (HTTPS + Hazelcast need two); inbound redirect goes to a single `local_service_port`; `DialedDirectly` not documented for Nomad bridge mode |
| **One virtual mesh service per member** | **Chosen** — mTLS + intentions, OSS only, no new certificates to manage |

---

## Solution: one virtual mesh service per member

Each member gets a stable **ordinal** (`NOMAD_ALLOC_INDEX`: 0, 1, 2, …). For every ordinal,
Consul exposes a **virtual service name** (`<svc>-hz-0`, `<svc>-hz-1`, …) that always resolves to
exactly one instance — the member with that ordinal. Every allocation declares one mesh upstream
per ordinal, so every member reaches every other member on a fixed local address.

```text
   ┌───────────────── alloc 0 (nomad1) ─────────────────┐
   │                                                    │
   │  Hazelcast member 0  (binds :5701, not published)  │
   │  public-address = 127.0.0.1:15700                  │
   │                                                    │
   │  Envoy upstreams (local listeners):                │
   │    127.0.0.1:15700 ──► <svc>-hz-0 ─► member 0 ─┐   │  (itself)
   │    127.0.0.1:15701 ──► <svc>-hz-1 ─► member 1 ─┼───┼──► mTLS ──► alloc 1 sidecar ──► :5701
   │    127.0.0.1:15702 ──► <svc>-hz-2 ─► member 2 ─┼───┼──► mTLS ──► alloc 2 sidecar ──► :5701
   │                                                │   │
   │  Envoy public listener (dynamic host port) ◄───┘   │  ◄── mTLS only, intention-checked
   └────────────────────────────────────────────────────┘

   alloc 1 and alloc 2 look identical — same upstream ports, own public-address 15701 / 15702.
```

Every allocation sees the **same address → member mapping**:

| Address (inside every alloc) | Always reaches | Advertised by |
|---|---|---|
| `127.0.0.1:15700` | member 0 | member 0 (`public-address`) |
| `127.0.0.1:15701` | member 1 | member 1 |
| `127.0.0.1:15702` | member 2 | member 2 |

Hazelcast identifies members by their advertised address. Because the mapping is identical in
every alloc, all members agree on who is who:

```text
Members {size:3, ver:3} [
	Member [127.0.0.1]:15700 - e422c181-... this
	Member [127.0.0.1]:15701 - ccbc866a-...
	Member [127.0.0.1]:15702 - 25bc003d-...
]
```

A member also reaches **itself** through its own upstream (Hazelcast skips its own address in the
member list, but the mapping must still be consistent).

---

## New concepts: network namespace, discovery chain, resolver, subset, redirect

So far we only used `service-defaults` (protocol), `service-intentions` (who may talk to whom),
`service-router` (east-west path routing) and API Gateway routes. This solution adds the
**service-resolver**, and relies on how bridge networking isolates ports.

### Network namespace (alloc network)

A Linux **network namespace** (netns) is an isolated network stack: own interfaces, own IP,
own `127.0.0.1`, own ports, own iptables rules. Processes in different namespaces cannot see
each other's ports.

With `network { mode = "bridge" }`, Nomad creates **one network namespace per allocation**.
All tasks of the allocation — including the Envoy sidecar — share it:

```text
host nomad1 (10.0.1.10)
│
├── alloc 0 network namespace (172.26.64.5)
│     ├── task "app"          :8080
│     ├── task "hazelcast"    :5701
│     ├── Envoy sidecar       :15700-15702 (upstreams) + public listener
│     └── 127.0.0.1 — shared by all of the above
│
└── alloc 1 network namespace (172.26.64.6)
      └── ... own copy, own 127.0.0.1
```

Consequences used by this solution:

- App, Hazelcast and sidecar talk to each other via `127.0.0.1` — the POC's separate
  `hazelcast` task behaves exactly like Payara's embedded Hazelcast.
- Every allocation can use the same upstream ports 15700–15702 without conflicts.
- A port is reachable from outside the allocation **only if it is published** on the host.

Publishing vs only registering a port:

| Job spec | Effect | Reachable by |
|---|---|---|
| `network { port "hazelcast" { to = 5701 } }` (current demo-service) | Nomad maps a dynamic host port (e.g. `10.0.1.10:24817`) → 5701 inside the namespace | Anyone who can reach the host |
| `service { port = "5701" }` only, no `network` port (this solution) | Port is registered in Consul so the sidecar knows where to forward — nothing is mapped on the host | Only processes inside the allocation's namespace, i.e. its own Envoy sidecar |

### Discovery chain

When a sidecar has an upstream `destination_name = "X"`, Envoy does not simply look up
instances of `X`. Consul first evaluates the **discovery chain** for `X` and pushes the result
to Envoy via xDS:

```text
upstream "X"
  │
  ▼
service-router   (optional)  match on HTTP path/header → pick a service      (HTTP only)
  │
  ▼
service-splitter (optional)  split traffic by weight between services/subsets (HTTP only)
  │
  ▼
service-resolver (optional)  WHICH INSTANCES of the service are valid targets
  │                          (subsets, redirect, failover, load balancing)
  ▼
healthy instances → Envoy cluster endpoints
```

Router and splitter need protocol `http`. The **resolver also works for `tcp`** — which is
why it is usable for Hazelcast's binary protocol.

### service-resolver

A config entry (`Kind = "service-resolver"`) attached to a service name. It does not route
requests by content; it decides **which instances** a connection to that service name ends up on.
Typical uses: subsets (e.g. `v1`/`v2` for canaries), failover to another datacenter, redirects,
load-balancing policy, connect timeout.

### Subset

A named **filter over the instances** of one service. Instances are selected by a
[filter expression](https://developer.hashicorp.com/consul/api-docs/features/filtering) on
their catalog data — usually `Service.Meta` or `Service.Tags`.

```hcl
Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz"

DefaultSubset = "member-0"

Subsets = {
  "member-0" = { Filter = "\"hz-ordinal-0\" in Service.Tags", OnlyPassing = true }
  "member-1" = { Filter = "\"hz-ordinal-1\" in Service.Tags", OnlyPassing = true }
  "member-2" = { Filter = "\"hz-ordinal-2\" in Service.Tags", OnlyPassing = true }
}
```

- The job sets `tags = ["hz-ordinal-${NOMAD_ALLOC_INDEX}"]` on the service **and** its
  `sidecar_service`, so each instance carries its ordinal.
- Filters are evaluated against the **sidecar** registration: Consul queries upstream endpoints
  with `Connect=true`, which returns the proxy instances, not the services behind them.
- **Tags, not meta:** Nomad interpolates `sidecar_service.tags`, but registers
  `sidecar_service.meta` verbatim — the sidecar would carry the literal string
  `${NOMAD_ALLOC_INDEX}` and no subset would match (verified in Nomad source,
  `client/taskenv/services.go`).
- `OnlyPassing = true` — only instances with passing health checks are targets (default
  also accepts `warning`).
- `DefaultSubset` — where traffic to the plain service name goes. Required syntax-wise only;
  members never use the plain name.

A subset is **not** a service. Nomad upstreams cannot reference a subset directly — that is
what the redirect is for.

### Redirect (virtual service)

A service-resolver with a `Redirect` block sends everything for its name to a different service
and/or subset. The name itself **does not need to be registered** in the catalog — it exists only
as this config entry, i.e. a **virtual service**.

```hcl
Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz-1"     # virtual — no instance is registered under this name

Redirect {
  Service       = "hazelcast-mesh-service-hz"
  ServiceSubset = "member-1"
}
```

Full resolution of one upstream:

```text
upstream "hazelcast-mesh-service-hz-1"  (local_bind_port 15701)
  │
  ▼  service-resolver "hazelcast-mesh-service-hz-1"   Redirect
  │
  ▼  service-resolver "hazelcast-mesh-service-hz"     Subset "member-1"
  │                                                    Filter: "hz-ordinal-1" in Service.Tags
  ▼
exactly one healthy instance: the alloc with NOMAD_ALLOC_INDEX = 1
```

#### Normal service vs virtual service

A virtual service is only a **name** — comparable to a DNS CNAME or a saved search. It has no
process, no instances and no identity of its own.

| Aspect | Normal service (`web-service`, `hazelcast-mesh-service-hz`) | Virtual service (`hazelcast-mesh-service-hz-1`) |
|---|---|---|
| Defined by | Nomad `service {}` block in the job | Consul config entry (`service-resolver` with `Redirect`) |
| Registered in catalog | Yes — one instance per alloc | No |
| Instances (address, port, health, meta) | Own | None — borrowed from the redirect target |
| Identity (mTLS cert, intentions) | Own service identity | None — intentions use the **target** service name |
| Usable as `destination_name` in upstreams | Yes | Yes — indistinguishable for the upstream |
| Visible in Consul UI | Services list | Config entries / **Routing** tab of the target service |
| Lifetime | Exists while allocs are running | Exists until the config entry is deleted |

Not to be confused with transparent proxy's *virtual IPs* (`<svc>.virtual.consul`) — those
belong to real, registered services.

### Intentions with redirects

Intentions are enforced by the **destination** sidecar, based on the real service identities in
the mTLS certificates — not on the virtual name. One intention covers all virtual member names:

```hcl
Kind    = "service-intentions"
Name    = "hazelcast-mesh-service-hz"
Sources = [{ Name = "hazelcast-mesh-service-hz", Action = "allow" }]
```

Hazelcast members of other services (`other-service-hz`) present a different identity and are
denied by default.

---

## Job spec — key points

See `aws/services/hazelcast-mesh-service/job.nomad.hcl`.

| Element | Purpose |
|---|---|
| `variable "members"` | Single source for `count`, the upstream list and the Hazelcast member list |
| Two Connect services in one group | App service (HTTPS in production) + `<svc>-hz`, each with its own sidecar |
| `port = "5701"` (numeric) on the hz service | Registers the port inside the alloc's network namespace **without** publishing a host port (see [Network namespace](#network-namespace-alloc-network)) |
| `tags = ["hz-ordinal-${NOMAD_ALLOC_INDEX}"]` | Set on service **and** sidecar — input for the subset filters (tags, not meta: see [Subset](#subset)) |
| `dynamic "upstreams"` | `<svc>-hz-<N>` → `127.0.0.1:15700+N` for N in `0..members-1` |
| Hazelcast config (template) | TCP-IP join with the upstream addresses, own `public-address`, multicast/auto-detection off |
| Script health check | Nomad runs `curl -sf .../hazelcast/health/ready` inside the hazelcast task's container and maps the exit code to the status: `0` passing, `1` warning, other critical (e.g. `22` HTTP ≥ 400, `7` connection refused). No host port, no expose path. See [Health check scope](#health-check-scope) |
| `update { max_parallel = 1 }` + `kill_timeout` + `shutdownhook.policy=GRACEFUL` | Replace one member at a time; partitions migrate before a member stops |

No Consul ACL token is needed in the job anymore — Hazelcast no longer reads the catalog.

### Health check scope

`/hazelcast/health/ready` returns 200 once the member is **started and active**. It does
**not** verify that the member joined the others — a standalone member also returns 200.

This is intentional. The resolver subsets use `OnlyPassing = true`, so a member only receives
mesh traffic once its check passes. A check requiring `clusterSize > 1` would deadlock at
startup: no member could become healthy before the others can reach it.

The check therefore means "this member can accept connections". Cluster formation is verified
separately — `hazelcast_mesh.sh` compares `clusterSize` on all members.

---

## Security properties

| Threat | Before | After |
|---|---|---|
| Rogue process joins the cluster | Possible (plain TCP host port) | Blocked — only entry is the sidecar, which requires a Consul-issued client cert |
| Eavesdropping on session data | Plain text on the network | mTLS between sidecars (traffic in plain text only on `127.0.0.1` inside the alloc) |
| Member of another service joins | Possible with same cluster name | Denied by intention (different service identity) |
| Consul token exposure in job spec | RO token in job vars/env | Not needed |

---

## Consul config entries

| File | Kind | Purpose |
|---|---|---|
| `defaults.consul.hcl` | `service-defaults` | `<svc>-hz` protocol `tcp` |
| `defaults-app.consul.hcl` | `service-defaults` | App service protocol |
| `intentions.consul.hcl` | `service-intentions` | `<svc>-hz` → `<svc>-hz` allow |
| `resolver.consul.hcl` | `service-resolver` | One subset per ordinal |
| `resolver-member-<N>.consul.hcl` | `service-resolver` | Virtual name `<svc>-hz-<N>` → subset `member-<N>` |

Apply order: subset resolver before the redirects (they reference its subsets). Delete in
reverse order.

---

## Lifecycle behaviour

| Event | Behaviour |
|---|---|
| Rolling update | Old alloc N is stopped (graceful Hazelcast shutdown), new alloc N starts with the same ordinal and address, rejoins with a new member UUID |
| Alloc rescheduled to another node | Same ordinal → same virtual name; Consul pushes the new endpoint to all sidecars via xDS |
| Intention changed to deny | Envoy checks intentions on **new** connections — existing member connections survive until a member reconnects |
| Member unhealthy | `OnlyPassing` removes it as a target; other members see it as unreachable |

---

## Limitations

| Limitation | Impact |
|---|---|
| Fixed member count | Changing `members` requires matching subsets + redirect resolvers. To be generated by a script for production |
| Ordinal overlap during updates | Old and new alloc with the same ordinal can briefly coexist (shutdown phase); `max_parallel = 1` and `OnlyPassing` keep this short |
| Config entries per service | 3 + N entries per clustered service — must be templated for all web services |
| Payara image change | Hazelcast discovery must switch from Consul to TCP-IP member list + `public-address` |

---

## Status

| Check | Result |
|---|---|
| Hazelcast 5.5 address mapping (Docker + socat emulating upstreams) | ✅ cluster of 3, consistent member view |
| Member restart rejoins | ✅ locally |
| Job renders with Nomad 2.0.0 | ✅ |
| Two Connect services in one group — accepted by Nomad 2.0.0 server | ✅ `job validate` + `job plan` create two sidecar tasks |
| Two Connect services in one group — runtime | ⏳ POC cluster |
| Hazelcast `public-address` template (consul-template) | ✅ index 0 → `15700`, index 2 → `15702` |
| Redirect resolver for unregistered virtual name — Consul 1.22 dev agent | ✅ all entries accepted; chain `<svc>-hz-1` → single target `member-1`, protocol `tcp` |
| Subset filter on sidecar tag — Consul 1.22 dev agent, sidecars registered like Nomad does | ✅ tag filter returns exactly member 1's sidecar; meta filter (uninterpolated) returns 0 |
| Redirect + subset with real Nomad allocations and Envoy | ⏳ POC cluster |
| Rogue member blocked / intention deny / rolling update | ⏳ POC cluster |

Test: `aws/bin/instance/hazelcast_mesh.sh` (step-by-step, run on a cluster node with
`NOMAD_TOKEN` and `CONSUL_HTTP_TOKEN` exported).
