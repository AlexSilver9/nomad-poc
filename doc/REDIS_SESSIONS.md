# Session Persistence in Redis/Valkey

Status: **design notes** — nothing implemented or tested yet.

## Context

Payara web services that run with more than one instance need shared HTTP sessions. Commonly
this is done with Payara's embedded Hazelcast, which is unsecured in Community (plain TCP, anyone
can join).

| Approach | State |
|---|---|
| Hazelcast through the mesh ([HAZELCAST_MESH.md](HAZELCAST_MESH.md)) | ✅ POC validated — but needs a Payara image change (TCP-IP member list, `public-address`). Not zero-downtime capable, see [Hazelcast and zero downtime](#hazelcast-and-zero-downtime) |
| Hazelcast with its own TLS / member auth | ❌ Hazelcast Enterprise / Payara Enterprise only — too expensive. Community has only the cluster name check |
| Sticky sessions without sharing ([STICKY_SESSIONS.md](STICKY_SESSIONS.md)) | Simplest — but every failover/deployment logs users out |
| **Sessions in Redis/Valkey** (this document) | Discussed here |
| Stateless apps + managed Valkey | Recommended target, see [Target architecture](#target-architecture) |

On Payara Community, the mesh (service resolvers + per-member upstreams) is the **only** way to
secure the Hazelcast traffic.

Goals assumed for the target: a modern, more cloud-style architecture, more stability and
resilience, **zero downtime**. Constraint: **the platform stays on Nomad** (no move to ECS/EKS).

## Where Redis sessions fit

An external session store (Redis/Valkey) is the common way to share sessions in Spring, Node,
.NET etc. **On Payara it is not the native way**: Payara's HA session persistence is Hazelcast
(`persistence-type="hazelcast"`). The built-in types are `memory`, `file` and `hazelcast` — there is no Redis type.

---

## Hazelcast and zero downtime

The Hazelcast mesh secures the traffic, but embedded Hazelcast (Community) has structural limits
that conflict with zero downtime.

### Rolling upgrades are Enterprise-only

Hazelcast docs (5.5, "Upgrade to a new version"): rolling member upgrades require Hazelcast
Enterprise — both for a new **patch** version and for the next **minor** version ("Enterprise
Edition only"). Members of different versions cannot reliably form one cluster in Community.

Payara bundles Hazelcast, so **a Payara upgrade can be a Hazelcast upgrade**:

| Payara release | Hazelcast | Effect |
|---|---|---|
| Payara Community 5.2021.3 | 4.2 | Release notes: rolling updates from earlier Community releases not supported |
| Payara 7.2026.9 | 5.7.0 (from 5.3.8-payara-1) | [payara/Payara#8558](https://github.com/payara/Payara/issues/8558) (open, 2026-11-09): new instances fail to join (`HazelcastSerializationException` in `JoinRequest`), log "Could not join cluster. Shutting down now!", rollout stalls |

An application on Payara **7.2026.6** or earlier hits exactly this case with the next upgrade to
7.2026.9+.

What this means in practice: during a rolling deployment with a Hazelcast version change, the
new instance cannot join the old cluster. Either it shuts down (deployment stalls), or — if it
starts its own cluster — there are **two separate session clusters** behind the same service: a
user switching between old and new instance loses the session. The only clean way is to stop all
instances and start the new version → **all users logged out** on such upgrades.

### Network splits and member loss

| Situation | Effect on sessions |
|---|---|
| Network split between members (split brain) | Both sides keep working with their own copy. On merge, Hazelcast applies a merge policy (default `PutIfAbsentMergePolicy`) → updates made on one side are lost. Jepsen found lost writes in the first seconds of a partition (Hazelcast 3.8.3) |
| More members lost at once than `backup-count` | Session data in those partitions is gone |
| Rolling restart without graceful shutdown | Partitions are not migrated before the member stops → same as member loss |
| Fixed member count (mesh) | Mesh needs one upstream per member ordinal → no free scaling, a missing member means a broken upstream |

Session state lives **inside** the app instances. For zero downtime, app instances should be
disposable and the state should live outside them.

---

## Idea

Payara instances do not talk to each other at all. Each instance stores its sessions in a central
Redis/Valkey and reads them from there on every request. Any instance can serve any request.

```text
Client → nginx → API Gateway → Payara instance 0 ─┐
                             → Payara instance 1 ─┼→ 127.0.0.1:6379 → sidecar → mTLS → Redis/Valkey
                                                   ┘   (mesh upstream "redis")
```

---

## Where Redis runs: self-hosted vs managed

### Overview

| | Redis (self-hosted) | Valkey (self-hosted) | ElastiCache for Valkey (node-based) | ElastiCache Serverless for Valkey | MemoryDB for Valkey |
|---|---|---|---|---|---|
| License | Redis 7.4+: RSAL/SSPL, Redis 8: also AGPLv3 | BSD (Linux Foundation fork of Redis 7.2) | Managed by AWS | Managed by AWS | Managed by AWS |
| Runs on | Nomad job | Nomad job | AWS, outside the cluster | AWS, outside the cluster | AWS, outside the cluster |
| HA | Single instance realistic (Sentinel/Cluster hard in the mesh) | Same | Multi-AZ replica, automatic failover, primary endpoint (DNS) | Built in, multi-AZ | Multi-AZ, automatic failover |
| Durability | AOF/RDB on a host volume (pins to one node) | Same | Replica in memory; full outage = data lost (a durability option for Valkey has been announced — verify) | Snapshots; not a durable store | Durable: multi-AZ transaction log, primary database |
| Patching / failover | Us | Us | AWS | AWS | AWS |
| Cost model | Node resources only | Node resources only | Per node-hour (reserved nodes cheaper) | Per GB stored + per ECPU (min. 100 MB for Valkey) | Per node-hour, above ElastiCache |
| Fit for sessions | POC / non-HA | POC / non-HA | ✅ Recommended | ✅ Good for small/spiky load | Only if sessions must survive a full outage |

Illustration from a third-party post (Tokyo, 2× `r7g.large`): ElastiCache ≈ 307 USD/month,
MemoryDB ≈ 379 USD/month. Session data is small — smaller node types or Serverless are likely
enough. **Verify with the AWS pricing calculator.**

**Redis vs Valkey:** protocol-compatible, same clients (Lettuce, Jedis, Redisson, Spring Data
Redis). Valkey avoids the Redis license question and is cheaper on ElastiCache (node-based ~20%,
Serverless ~33% lower than Redis OSS). No reason to pick Redis for this use case.

### Option 1: Valkey as a Nomad job in the mesh

Much simpler than Hazelcast: Valkey is **client → server**, not peer-to-peer. One normal mesh
service and one normal upstream — no subsets, redirects or per-instance addressing.

| Piece | Content |
|---|---|
| Nomad job `redis` | `count = 1`, bridge network, Connect service `redis`, port 6379 **not** published on the host |
| Payara jobs | One upstream `redis` → `127.0.0.1:6379` in the sidecar |
| `service-defaults` | `Protocol = "tcp"` |
| Intentions | `<payara-service> → redis` allow, per service; everything else denied (default deny) |
| Auth | ACL users per service (`user my-service on >… ~my-service:* +@all -@dangerous`) on top of the mesh — limits each service to its own key prefix |
| Health check | Script check `valkey-cli ping` inside the task (same idea as the Hazelcast `ready` check) |
| Secrets | Passwords via Nomad Variables / template, not in the job spec |

Security result: same as the Hazelcast mesh — no host port, mTLS on the wire, intentions decide
which service may connect, plus ACLs per service.

Weak point: **HA**. Sentinel and Cluster advertise node IPs to clients (Sentinel: master address;
Cluster: `MOVED` redirects) → same addressing problem as Hazelcast in the mesh.
`replica-announce-ip` / `sentinel announce-ip` exist, but with dynamic Nomad placement and sidecar
upstreams this is the per-instance pattern again. Realistic in-mesh setup: **one** instance,
restarted by Nomad → **not zero-downtime capable** (restart = short outage, without persistence
all users logged out).

### Option 2: ElastiCache for Valkey — provisioned in AWS outside the cluster

| Topic | Detail |
|---|---|
| HA | Multi-AZ with automatic failover. With cluster mode **disabled**, clients use the **primary endpoint** — a DNS name that always points to the current primary. No node IPs reach the client → none of the mesh addressing problems |
| Security | TLS in transit (`required` mode), RBAC users per service (replaces our ACL users) |
| Mesh integration | Consul **terminating gateway** (Nomad job) for the external service `redis` → apps keep a normal upstream, intentions still apply, the gateway does TLS to ElastiCache. Or direct TLS from the apps without the mesh |
| Keyspace events | `notify-keyspace-events` via parameter group (needed by Spring Session for expiry events) |
| Operations | Patching, failover, monitoring (CloudWatch) by AWS |

This removes the biggest operational objection (single point of failure, HA hard in the mesh) —
but it must be provisioned in AWS outside the cluster.

---

## Application side: how the apps store sessions in Redis

Payara has no Redis session store, so it must be added either per application or once per server:

| Variant | Fit |
|---|---|
| **Spring Session** (`spring-session-data-redis`) | Works in any Servlet container incl. Payara: `SessionRepositoryFilter` replaces the `HttpSession` for the app. The app needs the Spring Framework jars + one config class, **not** a Spring architecture. Recommended **bridge** if apps keep the `HttpSession` |
| Explicit state store (Lettuce/Redisson, small DTOs as JSON) | Recommended **target**: the app stores only what must be shared (login flow state, lockouts, …) under its own keys with a TTL — see [Target architecture](#target-architecture) |
| Own servlet filter that wraps `HttpSession` | ⚠️ Not recommended — re-implements what Spring Session does (delta saves, expiry, events) |
| Payara server plugin: own persistence type via `PersistenceStrategyBuilder` (HK2 service) | Once per image instead of per app, transparent for the apps. No existing open-source Redis implementation found; coupled to Payara internals. Needs an image change, like the Hazelcast mesh |
| Redisson Tomcat session manager | ❌ Tomcat only, not Payara |

What Spring Session already handles:

| Topic | Spring Session behavior |
|---|---|
| Concurrent requests (AJAX, tabs) | Only changed attributes are written (delta), not the whole session |
| Expiry / destroy events | Fires `SessionExpiredEvent` / `SessionDeletedEvent` from Redis keyspace notifications (`notify-keyspace-events`; set by Spring Session automatically, on ElastiCache via parameter group) |
| Session timeout | Redis key TTL = session timeout |

Requirements and pitfalls that remain:

| Topic | Detail |
|---|---|
| Serializable session | Everything in the session must be serializable. Problem areas: JSF view state (server-side state saving stores views in the session), CDI `@SessionScoped` beans, SAML/IDP flow state. See [JSON vs Java serialization](#json-vs-java-serialization) |
| **CDI `@SessionScoped` (Weld)** | Weld binds its session context in a `ServletRequestListener`, i.e. **before** any filter runs, and reads/writes session attributes there. With a filter-based store (Spring Session), `@SessionScoped` beans may end up in Payara's local session instead of Redis — sessions look shared but CDI state is not. **Must be tested** in any POC |
| Filter order | `SessionRepositoryFilter` must run before anything that touches the session |
| Session size | Read/written on every request → keep sessions small; consider JSF client-side state saving |
| `HttpSessionListener` | Container listeners do not fire for Redis sessions; logout/cleanup code must use Spring Session events |
| Non-session state | Things kept in application memory (caches, lockout counters, SAML replay cache) are **not** shared by this — still per instance |

This is likely **more** work than the Hazelcast image change, and it is per application.

### JSON vs Java serialization

Whatever is stored outside the instance (Redis or Hazelcast) must be serialized. The format
decides whether **old and new app versions can read each other's data** — the core requirement
for zero-downtime rolling deployments, where both versions run at the same time.

| | Java serialization | JSON (e.g. Jackson) |
|---|---|---|
| Default in | Spring Session, Payara/Hazelcast sessions | Must be configured (Spring Session: `RedisSerializer` bean `springSessionDefaultRedisSerializer`, e.g. `GenericJackson2JsonRedisSerializer`) or written explicitly |
| Coupling | Binary format bound to the exact class: package, name, fields, `serialVersionUID` | Bound to field names only |
| Class change (new version) | Changed `serialVersionUID` or incompatible field change → `InvalidClassException` → session unreadable → user logged out / error page | Added fields: ignored by old version (with `FAIL_ON_UNKNOWN_PROPERTIES = false`); removed fields: default value. Renames need care |
| Library upgrade | Framework objects in the session (OpenSAML, JSF view state, CDI proxies) change with the library → sessions of the old version break | Only own DTOs are stored → library upgrades do not matter |
| What can be stored | Any `Serializable` object graph (convenient, but also stores things that should not be shared) | Only plain data (DTOs). JSF view state, CDI beans, OpenSAML objects are not JSON-mappable |
| Polymorphism | Built in | Needs type info. Avoid default typing / `@class` for arbitrary types; use explicit DTO types or an allowlist (`PolymorphicTypeValidator`) |
| Security | Deserializing data from a store is a known attack vector (gadget chains) if an attacker can write to Redis — mitigated by mTLS/ACL, not eliminated | No code execution by deserialization when types are explicit |
| Debugging | Binary, unreadable in `valkey-cli` | Readable, easy to inspect and clean up |
| Size | Larger (class metadata) | Usually smaller for simple data |
| Known pitfalls | Every incompatible class change = all sessions of that type lost on deploy | Jackson / Spring Data Redis upgrades have changed the JSON type format in the past → pin and test serializer config |

Consequences:

- **Spring Session as a bridge** with the current `@SessionScoped` beans will in practice need
  **Java serialization** (the beans hold framework objects). Rules for zero downtime then: fixed
  `serialVersionUID` in every session class, only compatible changes (add fields, never
  rename/retype), library upgrades (OpenSAML, Faces) treated as "may log users out".
- **Target**: store only small explicit DTOs as **JSON** with a TTL (see below). Then rolling
  deployments and library upgrades do not affect stored state.
- The same Java serialization problem applies to Hazelcast sessions — it is not specific to Redis.

---

## Limits: what Redis sessions do not solve

Redis/Valkey shares **HTTP sessions only**. It is not a full replacement for a shared cluster.

Not solvable with Redis sessions:

| Topic | Detail |
|---|---|
| Non-session state | Caches, failed-login lockout counters, SAML replay cache, timers/crons stay per instance. Hazelcast can share these (maps); with Redis only if every app rewrites that code |
| Central dependency | Redis down → no session readable → nobody can log in. ElastiCache Multi-AZ reduces this, but a failover still interrupts requests for a few seconds |
| Transparency | Every app must be changed (Spring Session) — no solution without app code |

Only partly solvable (with Spring Session):

| Topic | Detail |
|---|---|
| CDI `@SessionScoped` | May stay in the local Payara session (Weld issue) → this state is not shared |
| Serialization | Everything in the session must be serializable (JSF view state, SAML flow state); otherwise errors or lost data. Java serialization breaks on incompatible class changes |
| Concurrent requests | Delta writes help, but two requests changing the **same** attribute → last write wins; no session locking |
| Session listeners | `HttpSessionListener` does not fire; logout/cleanup code must move to Spring Session events |
| Performance | Network round trip to Redis on every request; large sessions (JSF view state) make it slow → client-side state saving |

Gets worse:

| Topic | Detail |
|---|---|
| Operations | One more component to run, monitor, back up and secure (less with a managed service) |
| Restarts | Self-hosted without persistence (Option 1): Redis restart → all users logged out |

The target architecture below addresses the "not solvable" rows by moving that state to Valkey
explicitly.

---

## Target architecture

### Recommendation

| Situation | Recommendation |
|---|---|
| Keep the fixed setup, minimal investment | Hazelcast mesh (one image change, no app changes) — accepting the limits above |
| **Invest in resilience, zero downtime, more cloud-style (assumed goals)** | **Stateless Payara instances + ElastiCache for Valkey (Multi-AZ), on Nomad** |

Principle: **app instances hold no state that matters.** Any instance can be stopped, replaced or
added at any time. All shared state lives in one managed, highly available store with explicit,
versionable data (JSON + TTL).

```text
                   ┌──────────────── Nomad / Consul cluster (≥ 2 client nodes) ─────────────────┐
Client → ALB → nginx (per node) → API Gateway (per node) → Payara instances (≥ 2, spread on nodes)│
                   │                                               │ upstream "redis" (mesh, mTLS) │
                   │                                               ▼                               │
                   │                                   Terminating gateway (≥ 2)                   │
                   └───────────────────────────────────────────────┼───────────────────────────────┘
                                                                   │ TLS + RBAC user per service
                                                                   ▼
                                               ElastiCache for Valkey (Multi-AZ, primary endpoint)
```

### Components

| Component | Target | Why |
|---|---|---|
| Payara instances | ≥ 2 per service, `spread` / `distinct_hosts` over nodes, no Hazelcast session clustering | Disposable; losing an instance or a node loses no state |
| State store | ElastiCache for Valkey, cluster mode disabled, Multi-AZ, TLS required, RBAC user per service | HA and patching by AWS; DNS primary endpoint avoids the mesh addressing problem |
| Mesh access | Consul terminating gateway (Nomad job, ≥ 2 instances) with `redis` as linked service; one upstream per app | Intentions keep controlling which service may connect; apps see `127.0.0.1:6379` as today with Option 1 |
| Load balancing | No sticky sessions needed (after migration) | Even load, free scaling |
| Session cookie | Opaque session ID only; state in Valkey | Nothing sensitive in the browser |

### What moves to Valkey (explicitly, JSON + TTL)

| State | Today | Target key (example) | TTL |
|---|---|---|---|
| Login flow: OIDC `state` / `nonce` | `@SessionScoped` beans | `<service>:oidc:<state>` | Minutes (login flow timeout) |
| MFA progress | `@SessionScoped` bean | `<service>:mfa:<session-id>` | Minutes |
| Logged-in user / session data | `@SessionScoped` beans | `<service>:session:<session-id>` | Session timeout |
| Failed-login lockout counters | Per instance memory | `<service>:lockout:<user>` (`INCR` + `EXPIRE`) | Lockout window |
| SAML replay cache | Per instance memory | `<service>:saml-replay:<message-id>` (`SET NX`) | Assertion validity |
| JSF view state | Server-side, in session | Client-side state saving (in the page), or keep small | — |

CDI `@SessionScoped` beans can stay as a thin per-request facade that loads/saves the DTO from
Valkey — the state itself is no longer in the container session.

### Zero downtime on Nomad (beyond sessions)

| Topic | Requirement |
|---|---|
| Deployments | `update` block: `max_parallel = 1`, health checks, `min_healthy_time`, `auto_revert = true`; canaries for risky releases |
| Draining | `shutdown_delay` so Consul deregisters the instance before it stops; Payara graceful shutdown |
| Redundancy | No single instance anywhere: ≥ 2 app instances, nginx / API Gateway / terminating gateway on ≥ 2 nodes |
| Control plane | Nomad and Consul servers: 3 for quorum (single-server clusters are a single point of failure) |
| Data compatibility | Old and new app version run in parallel → JSON DTOs with compatible changes only; DB schema changes backward compatible (expand → migrate → contract) |
| Store failover | ElastiCache failover takes seconds → client reconnect/retry (Lettuce reconnects automatically); short timeouts |

### Migration path

| Phase | Content | Users logged out on deploy/failover? |
|---|---|---|
| 0 | Sticky sessions, 2 instances | Yes |
| 1 | ElastiCache for Valkey + terminating gateway + RBAC users; POC with self-hosted Valkey first | Yes (no app change yet) |
| 2 | Login service: login flow state, MFA, lockouts, SAML replay cache → Valkey (explicit, JSON) | Login flows survive |
| 3 | Session data of all apps → Valkey. Spring Session as shortcut only if the CDI POC passes (then Java serialization rules apply) | No |
| 4 | Remove sticky sessions, scale freely; other Payara apps follow the same pattern (shared library) | No |

---

## Operations (Option 1, self-hosted)

| Topic | Options / Problem |
|---|---|
| Availability | A single instance is a single point of failure: down → no session can be read → nobody can log in |
| HA | See Option 1 above — hard in the mesh. Use Option 2 if HA is required |
| Persistence | Sessions lost on restart = everybody logged out once. Acceptable? If not: AOF/RDB on a volume. EFS (NFS) is a poor fit (fsync latency); a host volume pins the job to one node |
| Memory | Sessions × average size; `maxmemory` + eviction policy (`volatile-ttl`), session TTL = session timeout |
| License | Use Valkey (BSD), see overview above |
| Monitoring | Prometheus exporter (`redis_exporter`, works with Valkey) in the existing monitoring stack |
| One instance for all services or one per service | Shared: fewer jobs, ACL users/key prefixes separate the services. Per service: blast radius limited |

---

## Comparison

| | Hazelcast mesh | Valkey in mesh (Opt. 1) | ElastiCache + Spring Session | **Target: stateless + ElastiCache** | Sticky (no sharing) |
|---|---|---|---|---|---|
| Payara/app change | Hazelcast config in the image | Spring Session in every app | Spring Session in every app | Explicit state store in apps (shared library) | None |
| Our mesh config | Subsets + redirects + upstreams per member | One service + one upstream per client service | Terminating gateway + one upstream per client service | Terminating gateway + one upstream per client service | A: nginx template; B: per-instance gateway ports |
| AWS infra needed | None | None | ElastiCache for Valkey | ElastiCache for Valkey | None |
| Failover of an app instance | Sessions survive (within `backup-count`) | Sessions survive | Sessions survive | Sessions survive | Users logged out |
| Rolling deployment | ✅ if same Hazelcast version and compatible classes | ✅ if compatible classes (Java ser.) | ✅ if compatible classes (Java ser.) | ✅ (JSON DTOs) | Users logged out |
| Payara upgrade with Hazelcast change | ❌ Full restart, all users logged out | ✅ | ✅ | ✅ | Users logged out |
| Store failover / restart | n/a | ❌ Outage, users logged out | ✅ Seconds (Multi-AZ) | ✅ Seconds (Multi-AZ) | n/a |
| Scaling instances | Fixed count | Free | Free | Free | A: free, B: fixed |
| New single point of failure | No | Valkey | No | No | No |
| CDI `@SessionScoped` shared | Yes | To be tested (Weld) | To be tested (Weld) | Yes (state moved to DTOs) | n/a |
| Shares non-session state | Yes (Hazelcast maps, if used) | No | No | Yes (lockouts, replay cache explicit) | No |
| Zero downtime | ❌ | ❌ | Partly | ✅ | ❌ |

---

## Questions to answer before choosing

1. Is investing in resilience, zero downtime and managed services a goal? Then the target
   architecture applies; otherwise the Hazelcast mesh.
2. Can ElastiCache for Valkey (Multi-AZ, TLS, RBAC) be provided? Serverless or node-based?
3. Do all Payara apps need shared state, or only some of them first?
4. Which state must survive a full ElastiCache outage (→ MemoryDB or durability option)? Likely
   none: sessions can be re-created by logging in again.
5. Are the sessions serializable today, and how large are they (JSF view state)? Can JSF use
   client-side state saving?
6. One shared Valkey for all services (ACL/RBAC per service) or one per service?
7. Who owns the explicit state store code (application team), and does it go into a shared
   library?
8. Nomad/Consul servers: 3 server nodes for quorum available?

## Possible next step

POC in this repo: Valkey as a mesh service, two client services with upstreams, intention test
(allowed / denied service), ACL users per service, `valkey-cli ping` health check. Then the same
via a terminating gateway to an external Valkey (TLS) to mirror the ElastiCache setup.

### Required: CDI `@SessionScoped` POC (go/no-go for Spring Session)

Typical JSF/CDI applications keep their login and user state in CDI `@SessionScoped` beans
(`jakarta.enterprise.context.SessionScoped`), e.g.:

| Area | State in `@SessionScoped` beans |
|---|---|
| Login | MFA state, OIDC `state`/`nonce`, current session |
| Application | Logged-in user, user account details, session store |
| Shared library | Session configuration, request validation, current locale |

If Spring Session does not capture these beans (Weld issue), switching instances breaks MFA,
the OIDC login callback and the user state. **Spring Session is only an option if
this POC passes** — otherwise the state must move to the explicit store (target architecture)
directly.

POC: small Payara app (same Payara version as the target apps) with Spring Session + Valkey, 2 instances,
no sticky sessions:

1. Write a value into a `@SessionScoped` bean on instance 0, read it on instance 1
2. Change the value on instance 1, read it again on instance 0 (updates, not only creation)
3. Same with a JSF page (view state) and a plain `HttpSession` attribute as reference
4. Session expiry / logout removes the bean state on all instances
5. Check the serialized bean contents in Valkey (no unexpected objects, size)
6. Rolling deploy of a changed bean class (added field) while sessions exist → still readable?

## References

- [Payara: HA session persistence](https://docs.payara.fish/community/docs/Technical%20Documentation/Payara%20Server%20Documentation/High%20Availability/Configuring%20HA%20Session%20Persistence%20and%20Failover.html), [list-persistence-types](https://docs.payara.fish/community/docs/Technical%20Documentation/Payara%20Server%20Documentation/Command%20Reference/list-persistence-types.html)
- [GlassFish: creating a session persistence module](https://glassfish.org/docs/5.1.0/add-on-component-development-guide/session-persistence-modules.html)
- [Hazelcast security overview (Enterprise features)](https://docs.hazelcast.com/hazelcast/5.5/security/overview)
- [Hazelcast: rolling upgrades (Enterprise only)](https://docs.hazelcast.com/hazelcast/5.5/maintain-cluster/rolling-upgrades)
- [Hazelcast: split-brain recovery](https://docs.hazelcast.com/hazelcast/5.5/network-partitioning/split-brain-recovery), [Jepsen: Hazelcast 3.8.3](https://jepsen.io/analyses/hazelcast-3-8-3)
- [payara/Payara#8558: Hazelcast 5.7.0 breaks rolling upgrades](https://github.com/payara/Payara/issues/8558), [Payara Community 5.2021.3 release notes](https://docs.payara.fish/community/docs/5.2022.4/Release%20Notes/Release%20Notes%205.2021.3.html)
- [Spring Session: HttpSession integration](https://docs.spring.io/spring-session/reference/http-session.html), [Redis configuration (serialization)](https://docs.spring.io/spring-session/reference/configuration/redis.html)
- [Horizontal scaling JSF applications with Spring Session](https://auth0.com/blog/horizontal-scaling-jsf-applications-with-spring-session/)
- [Weld: session replication / HttpSession access](https://developer.jboss.org/thread/250911)
- [ElastiCache endpoints](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Endpoints.html), [ElastiCache vs MemoryDB for Valkey](https://aws.amazon.com/compare/elasticache-and-memorydb-for-valkey/), [ElastiCache/MemoryDB Valkey support and pricing](https://aws.amazon.com/blogs/database/amazon-elasticache-and-amazon-memorydb-announce-support-for-valkey/)
- [Valkey Sentinel](https://valkey.io/topics/sentinel)
