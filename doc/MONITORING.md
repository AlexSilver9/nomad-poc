# Monitoring

This document describes how to add Prometheus + Grafana metrics monitoring to the cluster.

Monitoring is **opt-in** — it does not run by default and requires no changes to existing cluster configuration.

---

## What is installed

- **Prometheus** (port 9090) — scrapes CPU and memory metrics per Nomad allocation/task from all nodes
- **Grafana** (port 3000) — dashboards; Prometheus pre-configured as a datasource
- Per-job, per-task CPU and memory visible in Grafana dashboard [10902](https://grafana.com/grafana/dashboards/10902)

---

## Architecture

```
Nomad agent :4646/v1/metrics   (all 3 nodes)
        ↑
  Prometheus :9090              (single allocation, Consul SD discovers Nomad nodes)
        ↑
    Grafana :3000               (single allocation, datasource auto-provisioned)
```

- Prometheus and Grafana run as `service` jobs (one allocation each, not system jobs)
- Both use `host` network mode and static ports
- Data is persisted to EFS (`/data/prometheus`, `/data/grafana`) via host volumes
- Prometheus discovers Nomad nodes via Consul service discovery (no hardcoded IPs)

---

## Files

| File | Purpose |
|------|---------|
| `aws/bin/instance/setup_nomad_monitoring.sh` | Run on each node: writes telemetry + host volume config, restarts Nomad |
| `aws/bin/cluster/setup_monitoring.sh` | Run once from your machine: calls instance script, creates ACL token if needed, deploys jobs |
| `aws/acl/nomad/policies/metrics-scraper.policy.hcl` | Minimal Nomad ACL policy for Prometheus scraping (used only when ACL is enforced) |
| `aws/infrastructure/prometheus/job.nomad.hcl` | Prometheus Nomad job |
| `aws/infrastructure/grafana/job.nomad.hcl` | Grafana Nomad job |

---

## Setup

### Prerequisites

- Cluster is running (ACL enforced or not — both work)
- `NOMAD_ADDR` set in your shell (`NOMAD_TOKEN` only needed when Nomad ACL is enforced)
- `CONSUL_HTTP_ADDR` set in your shell (`CONSUL_HTTP_TOKEN` only needed when Consul ACL is enforced)

### Run

```bash
cd aws
bin/cluster/setup_monitoring.sh
```

This script:
1. SSHs into each node and runs `setup_nomad_monitoring.sh` (writes `/etc/nomad.d/telemetry.hcl` and `/etc/nomad.d/monitoring-volumes.hcl`, restarts Nomad)
2. Probes `GET /v1/metrics` — if Nomad returns 403, creates a `metrics-scraper` ACL token and passes it to the job; otherwise deploys without a token
3. Deploys the Prometheus and Grafana jobs
4. Prints the Grafana URL

### Access Grafana

```
http://<any-node-ip>:3000
```

Login: `admin` / the password entered during `setup_monitoring.sh`.

Import dashboard **10902** from grafana.com. The Traefik panels will show no data (not used) — all Nomad allocation CPU/memory panels work with nginx as well.

---

## What gets written to each node

`setup_nomad_monitoring.sh` writes two files and restarts Nomad — no existing config is modified:

**`/etc/nomad.d/telemetry.hcl`**
```hcl
telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
```

**`/etc/nomad.d/monitoring-volumes.hcl`**
```hcl
client {
  host_volume "prometheus-data" {
    path      = "/data/prometheus"
    read_only = false
  }
  host_volume "grafana-data" {
    path      = "/data/grafana"
    read_only = false
  }
}
```

---

## ACL

Monitoring works with and without ACL enforcement.

| ACL state | Behaviour |
|-----------|-----------|
| Not enforced | Prometheus scrapes `/v1/metrics` unauthenticated. No token is created. |
| Enforced (403) | `setup_monitoring.sh` automatically creates a `metrics-scraper` token and passes it to the Prometheus job. Token is saved to `aws/acl/monitoring-tokens.txt` (gitignored). |

If ACL is enabled **after** monitoring is already running, re-run `setup_monitoring.sh`. It will detect the 403, create the token, and redeploy Prometheus with it — takes ~10 seconds, no data loss.

The `metrics-scraper` policy grants the minimum required permissions:

```hcl
agent     { policy = "read" }
node      { policy = "read" }
namespace "default" { policy = "read" }
```

---

## Teardown

```bash
nomad job stop prometheus
nomad job stop grafana
```

To also remove data:
```bash
# On any node (EFS is shared)
rm -rf /data/prometheus /data/grafana
```

To remove Nomad config from nodes, delete `/etc/nomad.d/telemetry.hcl` and `/etc/nomad.d/monitoring-volumes.hcl` and restart Nomad.
