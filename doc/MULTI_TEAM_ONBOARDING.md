# Multi-Team / Multi-Region Onboarding

This document explores approaches for onboarding new teams into the Nomad/Consul
environment. Team XYZ is the first new team and serves as the reference for future
onboardings. It is a working document for internal discussion — not a final architecture
decision.

---

## Context

**Team ABC** is the team with the existing cluster. Their Nomad/Consul setup is the reference architecture:
separate clusters per environment, each with its own servers and clients.

**Team XYZ** is the new team to be onboarded.

The separate-cluster-per-environment model is a fixed constraint and applies to all teams.

---

## Team ABC Topology (existing)

Three independent clusters in Ireland, one per environment. No cross-cluster connectivity.

```
Ireland (eu-west-1)
  miaccess-dev     (servers + clients)
  miaccess-stg     (servers + clients)
  miaccess-prd     (servers + clients)
```

Each cluster: AWS ALB → N nodes (Nomad server+client, Consul, nginx, API Gateway, services).

---

## Team XYZ Topology

Team XYZ runs each environment simultaneously in two AWS regions for active-active HA.
This gives six clusters:

```
ca-central-1
  aca-dev-1    (servers + clients)  ┐
  aca-stg-1    (servers + clients)  ├── HA pairs with ca-west-1
  aca-prd-1    (servers + clients)  ┘

ca-west-1
  aca-dev-2    (servers + clients)  ┐
  aca-stg-2    (servers + clients)  ├── HA pairs with ca-central-1
  aca-prd-2    (servers + clients)  ┘
```

The HA pair for each environment is the same-env cluster in the other region
(aca-prd-1 ↔ aca-prd-2, etc.). nginx currently distributes traffic between the two
regions and handles failover.

---

## Option A: Extend Existing Cluster (not viable)

Nomad's single cluster supports multiple `datacenter` labels. XYZ's nodes would join as
clients in a different datacenter while servers stay in the current region.

**Why this doesn't work well here:**

- Nomad clients heartbeat to servers every ~5s. Cross-region latency causes false "node
  lost" events. `heartbeat_grace` can be tuned but the connection stays fragile.
- If the server region has a network partition or outage, all clients in all regions lose
  scheduling. That's the opposite of HA.
- The scheduler runs in the server region and must make decisions for remote nodes —
  not designed for this.

**Verdict:** Avoid for cross-region production use. Works fine within a single region or
same-AZ multi-AZ setups.

---

## Option A2: Add Servers to Existing Cluster in Other Regions (not viable)

A variation of Option A: instead of keeping servers only in the current region, spread
Nomad servers across all regions so quorum can survive a regional outage.

**Why this is worse than Option A:**

- **Raft is write-latency-sensitive.** Every scheduling decision requires the leader to
  replicate a log entry to a quorum of servers before it commits. With servers across
  Ireland and Canada (100–200ms RTT), every job placement takes that round-trip.
  Scheduling throughput degrades significantly.
- **Cross-region network partitions cause quorum loss.** If the inter-region link drops,
  neither side can reach a majority of servers. The cluster becomes completely unavailable
  — no new scheduling decisions can be made until connectivity is restored. This is not
  split-brain (Raft prevents two simultaneous leaders); it is the opposite: no leader at
  all. Within a region this is unlikely; across continents it is a realistic failure
  mode — exactly the scenario HA is meant to survive.
- **Single scheduler, global blast radius.** Even with servers in multiple regions,
  there is still one scheduler. A Nomad server bug or misconfiguration affects all regions
  simultaneously.

HashiCorp recommends Raft servers be co-located (same region) and designed `multiregion`
federation specifically because cross-region Raft does not scale. This option trades the
client heartbeat fragility of Option A for a more fundamental Raft performance and
availability problem.

**Verdict:** Not viable. Strictly worse than Option A.

---

## Option B: Six Separate Clusters + Nomad `multiregion` Federation

Each XYZ environment pair is federated. Nomad's `multiregion` job stanza connects the
two HA clusters for each environment:

```
aca-dev-1 ◄──multiregion──► aca-dev-2
aca-stg-1 ◄──multiregion──► aca-stg-2
aca-prd-1 ◄──multiregion──► aca-prd-2
```

A single `nomad job run` deploys to both HA clusters simultaneously:

```hcl
job "aca-service" {
  multiregion {
    strategy {
      max_parallel = 2            # both regions at the same time
      on_failure   = "fail_local" # one region failing does not roll back the other
    }
    region "aca-prd-1" {
      count       = 2
      datacenters = ["ca-central-1"]
    }
    region "aca-prd-2" {
      count       = 2
      datacenters = ["ca-west-1"]
    }
  }
  group "service" { ... }
}
```

Nomad tracks deployment health per region and halts if one fails. This replaces nginx as
the mechanism ensuring both HA regions run the same version at the same time.

Consul cluster peering connects each HA pair for cross-region service discovery:

```
aca-prd-1 Consul ◄──cluster peer──► aca-prd-2 Consul
```

**Pros:**
- Nomad-native visibility into whether both HA regions are in sync
- A failing deployment in one region is detected and halted automatically
- Replaces the nginx cross-region coordination layer

**Cons:**
- Federation setup: region-to-region connectivity, ACL federation between cluster pairs
- Three federation pairs to configure and maintain (one per env)
- The only thing federation adds over Option C is Nomad-native atomicity — any CI/CD
  pipeline already provides the same outcome with less operational overhead

---

## Option C: Six Separate Clusters, No Federation (recommended)

Same six clusters, no `multiregion` stanza. CI/CD deploys to each cluster independently,
in parallel for each HA pair.

**Pros:**
- Each cluster is fully standalone — no inter-cluster dependencies or network requirements
- No federation setup, no ACL federation, no cross-cluster connectivity to maintain
- CI/CD already handles parallel deploys and fails the pipeline if either cluster fails —
  the same outcome as Nomad-native federation at a fraction of the operational cost

**Cons:**
- Version parity between HA regions is enforced by CI/CD, not Nomad — requires a
  well-configured pipeline

---

## Consul in a Multi-Cluster Setup

Each Nomad cluster has its own Consul cluster. This is the same pattern used by Team
ABC and applies to all six XYZ clusters. Each Consul instance is fully standalone:
own ACL domain, own CA, own service registry.

**Cluster peering is not required** for XYZ based on two assumptions:

1. **No intra-HA service calls.** Services in aca-prd-1 do not call services in
   aca-prd-2. Each region serves its own traffic independently. The HA pair exists for
   failover, not for east-west communication between regions.

2. **No cross-team east-west traffic.** XYZ services do not call ABC services (or
   vice versa) directly through the service mesh. Any cross-team communication is routed
   via the ALB — north-south traffic, not Consul Connect.

If either assumption changes, Consul cluster peering can be added between the relevant
clusters without restructuring anything. Peering is additive and does not affect clusters
that don't participate in it.

This further supports Option C: with no cross-cluster service discovery needed, there is
no Consul-level reason to introduce federation either.

---

## Traffic Failover Between HA Regions

Both options above address deployment coordination. Live traffic routing between the two
XYZ regions is a separate concern — nginx handles it today. In a Nomad setup this moves
to the DNS/load balancer level:

- **DNS health-check routing**: monitors each region's ALB health and removes a
  failing region from DNS automatically. No application-level routing needed.
- **Consul cluster peering**: allows services in one region to discover and call peers in
  the other region. Useful for cross-region service-to-service calls during partial failover.

---

## Node Pools Within XYZ Clusters

Within each XYZ cluster, node pools can isolate different workload groups if needed —
for example, if certain XYZ services need dedicated nodes. This is independent of the
federation decision and can be introduced at any time.

---

## Comparison

| | Option B (federation) | Option C (no federation) |
|---|---|---|
| Clusters | 6 | 6 |
| Cross-region HA deployment | Nomad `multiregion` | CI/CD (parallel deploys) |
| Version sync detection | Automatic (Nomad halts) | CI/CD pipeline |
| Consul cross-region | Cluster peering | Cluster peering (opt-in) |
| Traffic failover | DNS health-check routing | DNS health-check routing |
| Federation setup required | Yes (3 pairs) | No |
| Operational complexity | Medium | Low |

---

## Federation and HA — Active/Active vs. Active/Passive

Federation does not manage which cluster is "active" and which is "standby".
Nomad has no concept of active or standby clusters.

Federation is a **deployment-time** mechanism. It ensures both clusters receive the
same job spec at the same time. Once deployed, Nomad's involvement ends — both clusters
run the job, and Nomad has no visibility into traffic, no ability to activate or deactivate
a cluster, and no role in failover decisions.

The active/active or active/passive distinction lives entirely outside Nomad:

- **DNS health-check routing** decides which region(s) receive traffic based on health checks or routing policy
- **ALB health checks** determine if a region is healthy enough to serve requests
- If one region's services fail, DNS health-check routing stops routing there — Nomad keeps the job
  running and reschedules failing allocations, but plays no role in the failover decision

| Setup | Both clusters run the job? | Who decides traffic? |
|---|---|---|
| Active-active | Yes | DNS health-check routing splits traffic between both |
| Active-passive | Yes | DNS health-check routing sends traffic to one, fails over on health failure |

In both cases, both clusters have the job deployed. The HA behaviour is entirely in
DNS health-check routing and the ALB — federation makes no difference to it.

---

## Federation — Deploying to a Subset of Clusters

A job without a `multiregion` stanza is local to the cluster it is submitted to.
Federation does not force all jobs to be multi-region.

A job with a `multiregion` stanza only targets the regions explicitly listed in it.
You can list one, two, or all federated clusters per job:

```hcl
# Deploys only to aca-prd-1, even though aca-prd-2 is federated
multiregion {
  region "aca-prd-1" {
    count       = 2
    datacenters = ["ca-central-1"]
  }
}
```

In a federated setup you would typically have a mix: services that need both HA regions
use the `multiregion` stanza with both regions listed; one-off jobs, migration scripts,
or region-specific services omit it or list only the target region.

Without federation the same result is achieved by submitting the job directly to whichever
cluster(s) the pipeline targets. The difference is where the targeting logic lives —
in the job spec (federation) or in the pipeline (no federation).

---

## Federation vs. No Federation — When Does It Matter?

Federation (`multiregion`) is worth the operational cost in specific scenarios. Outside
of those, it duplicates what CI/CD already does.

### When federation adds real value

**No CI/CD pipeline for deployment coordination.**
If services are deployed manually via `nomad job run`, federation is the only way to
target multiple clusters atomically in a single command. Without it, the operator must
run separate commands per cluster and manually verify parity.

**Serial cross-region promotion with automatic halt.**
The `multiregion` strategy supports `max_parallel = 1` with `on_failure = "fail_all"`:
deploy to region 1, wait for it to become healthy, then proceed to region 2 — and
automatically stop both if anything fails. This is Nomad-native and requires no pipeline
logic. Useful when the rollout order between HA regions matters (e.g., drain region 2
before deploying to region 1 to avoid split-brain during schema migrations).

**Unified observability across regions.**
A federated job shows deployment status across all regions in a single `nomad job status`
output. Without federation, you check each cluster separately.

**Cross-cluster batch job dispatch.**
Federation allows Nomad to dispatch batch jobs to whichever federated cluster has spare
capacity. Useful for workloads where placement flexibility across regions is desirable.

### When federation adds little

**CI/CD already coordinates the deployment.**
If a pipeline deploys to both clusters in parallel, checks health, and fails on divergence,
it provides the same guarantees as `multiregion`. Adding federation means maintaining both
the pipeline logic and the federation infrastructure — duplicated effort.

**Workloads are fully independent per cluster.**
If services in cluster A never need to call services in cluster B, and deployments are
driven by CI/CD, there is no coordination gap for federation to fill.

**Environments deploy on different schedules.**
Dev may deploy dozens of times a day while prod deploys weekly. Federation couples the
clusters conceptually even when they operate independently — adding friction without
benefit.

### For Team XYZ

XYZ's deployment is CI/CD-driven. The two HA clusters (per environment) deploy in
parallel via the pipeline, which already detects and halts on failure. Federation would
add three federation pairs to configure and maintain in exchange for moving coordination
logic from the pipeline into Nomad — a lateral move, not an improvement.

The scenario where federation would become worth it for XYZ is if the deployment process
moves away from CI/CD (e.g., operators running `nomad job run` directly) or if a
migration-safe serial rollout strategy between regions becomes a hard requirement.

---

## Recommendation

**Option C.** Six independent clusters managed by CI/CD. Federation (Option B) adds
infrastructure complexity to replicate something a CI/CD pipeline already does. Workloads
do not cross cluster boundaries, so there is nothing for federation to coordinate that a
pipeline cannot handle.

---

## Relationship to Team ABC

Team ABC (Ireland) and Team XYZ (us-west) are in different regions and run independent
clusters. No shared infrastructure is required. If a future requirement calls for
cross-team service discovery, Consul cluster peering between a Portal cluster and an XYZ
cluster can be added on demand.
