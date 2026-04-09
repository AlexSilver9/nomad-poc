# Monitoring

This document describes how to add Prometheus + Grafana metrics monitoring to the cluster.

Monitoring is **opt-in** — it does not run by default and requires no changes to existing cluster configuration.

---

## What is installed

- **Prometheus** — scrapes CPU and memory metrics per Nomad allocation/task from all nodes
- **Grafana** — dashboards; Prometheus pre-configured as a datasource via the service mesh

---

## Architecture

```
Nomad agent :4646/v1/metrics   (all 3 nodes)
        ↑
  Prometheus  (Consul Connect sidecar, Consul SD discovers Nomad nodes)
        ↑  (east-west: sidecar upstream localhost:9091)
    Grafana   (Consul Connect sidecar, datasource auto-provisioned)
        ↑
  API Gateway :8080             (hostname-based routing via Consul http-route)
        ↑
   ALB / nginx                  (ingress)
```

- Prometheus and Grafana run as `service` jobs in `bridge` network mode with Consul Connect sidecars
- Grafana reaches Prometheus via a sidecar upstream on `localhost:9091` — works regardless of which node Prometheus is scheduled on
- Both services are routable through the API Gateway: `grafana.example.com` → Grafana, `prometheus.example.com` → Prometheus
- Data is persisted to EFS (`/data/prometheus`, `/data/grafana`) via host volumes

---

## Files

| File | Purpose |
|------|---------|
| `aws/bin/instance/setup_nomad_monitoring.sh` | Run on each node: writes telemetry + host volume config, restarts Nomad |
| `aws/bin/cluster/setup_monitoring.sh` | Run once from your machine: configures nodes, applies Consul config, deploys jobs |
| `aws/acl/nomad/policies/metrics-scraper.policy.hcl` | Minimal Nomad ACL policy for Prometheus scraping (used only when ACL is enforced) |
| `aws/infrastructure/prometheus/job.nomad.hcl` | Prometheus Nomad job |
| `aws/infrastructure/prometheus/defaults.consul.hcl` | Consul service-defaults for Prometheus (protocol: http) |
| `aws/infrastructure/prometheus/intentions.consul.hcl` | Consul intentions: api-gateway and grafana allowed to reach Prometheus |
| `aws/infrastructure/prometheus/route.consul.hcl` | Consul http-route: `prometheus.example.com` → prometheus service |
| `aws/infrastructure/grafana/job.nomad.hcl` | Grafana Nomad job |
| `aws/infrastructure/grafana/defaults.consul.hcl` | Consul service-defaults for Grafana (protocol: http) |
| `aws/infrastructure/grafana/intentions.consul.hcl` | Consul intentions: api-gateway allowed to reach Grafana |
| `aws/infrastructure/grafana/route.consul.hcl` | Consul http-route: `grafana.example.com` → grafana service |

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

The script prompts for passwords (or reads them from environment variables), then:

1. SSHs into each node and runs `setup_nomad_monitoring.sh` — writes `/etc/nomad.d/telemetry.hcl` and `/etc/nomad.d/monitoring-volumes.hcl`, restarts Nomad
2. Probes `GET /v1/metrics` — if Nomad returns 403, creates a `metrics-scraper` ACL token and passes it to the Prometheus job; otherwise deploys without a token
3. Downloads and applies the 6 Consul config entries (defaults → intentions → routes)
4. Generates bcrypt hashes for Prometheus basic auth on a remote node
5. Deploys Prometheus
6. Deploys Grafana; discovers the dynamic host port via Consul and waits for HTTP readiness
7. Creates Grafana tech users via the Grafana HTTP API
8. Saves all credentials to `aws/acl/monitoring-credentials.txt` (gitignored)

### Access

Both services are routed through the API Gateway using hostname-based routing:

```bash
# North-south via API Gateway
curl -H 'Host: grafana.example.com'    http://<ingress>:8080/api/health
curl -H 'Host: prometheus.example.com' http://<ingress>:8080/-/healthy
```

Both services use bridge network mode — their container ports are not exposed directly on host ports. Use Consul to find the dynamic port for direct node access (e.g. for debugging):

```bash
# SSH to a node first
curl -s http://localhost:8500/v1/catalog/service/grafana    | jq '.[0].ServicePort'
curl -s http://localhost:8500/v1/catalog/service/prometheus | jq '.[0].ServicePort'
```

### Users

**Grafana**

| User | Role | Password |
|------|------|----------|
| `admin` | Grafana Admin | Set during `setup_monitoring.sh` |
| `tech-admin` | Admin | Set during `setup_monitoring.sh` |
| `tech-editor` | Editor (can create dashboards, cannot delete others') | Set during `setup_monitoring.sh` |
| `tech-viewer` | Viewer (read-only) | Set during `setup_monitoring.sh` |

**Prometheus**: no application-level authentication. Access control relies on two layers:

1. **Consul Connect intentions** — only the `api-gateway` and `grafana` sidecars are permitted to reach Prometheus through the service mesh (mTLS enforced by Envoy).
2. **EC2 security group** — the security group must not expose the ephemeral port range Nomad allocates from. Anyone who can reach the dynamic host port directly (e.g. via SSH to the node) bypasses the mesh and has unauthenticated access. This is acceptable for internal infrastructure in a correctly locked-down security group.

---

## Data persistence

Both Prometheus and Grafana mount their data directories from EFS-backed host volumes:

| Service | Host path | Container path | Persists |
|---------|-----------|----------------|----------|
| Prometheus | `/data/prometheus` | `/prometheus` | Metrics data, WAL |
| Grafana | `/data/grafana` | `/var/lib/grafana` | SQLite DB, users, dashboards |

**Restarts and re-deploys do not lose data.** Nomad job updates, allocation restarts, and node reschedules all leave data intact because the volume is on EFS.

### Prometheus persistence

Prometheus stores its TSDB (all scraped metrics + write-ahead log) at `/prometheus`, which is mounted from EFS. Restarts pick up exactly where they left off — no gap in metrics history.

**Retention**: configured to **7 days** via `--storage.tsdb.retention.time=7d` in the job's `args` block ([aws/infrastructure/prometheus/job.nomad.hcl](../aws/infrastructure/prometheus/job.nomad.hcl)). Prometheus defaults to 15 days if not set. Change the value and redeploy to adjust.

`prometheus.yml` is a Nomad template regenerated fresh on every allocation start. Scrape config changes take effect on redeploy (or by sending a `SIGHUP` to the Prometheus process).

### Grafana user persistence

Grafana stores all users (including tech users created via the API) in its SQLite database at `/var/lib/grafana/grafana.db`. This file persists on EFS.

**`GF_SECURITY_ADMIN_PASSWORD`** (set in the job's `env` block) only applies on first initialization — when `grafana.db` does not yet exist. On subsequent starts, Grafana ignores it and uses whatever password is stored in the database. This means:

- Rerunning `setup_monitoring.sh` with a different admin password will **not** change the existing admin password.
- To change the admin password after initial setup, use the Grafana UI or API: `PUT /api/user/password`.

**Tech users** created via the API (`tech-admin`, `tech-editor`, `tech-viewer`) also live in the database. If `setup_monitoring.sh` is run again, the user creation calls return HTTP 409 (user already exists), which the script logs as a warning and continues — no duplicate users are created and no passwords are overwritten.

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
| Enforced (403) | `setup_monitoring.sh` automatically creates a `metrics-scraper` token and passes it to the Prometheus job. Token is saved to `aws/acl/monitoring-credentials.txt` (gitignored). |

If ACL is enabled **after** monitoring is already running, re-run `setup_monitoring.sh`. It will detect the 403, create the token, and redeploy Prometheus with it — no data loss.

The `metrics-scraper` policy grants the minimum required permissions:

```hcl
agent     { policy = "read" }
node      { policy = "read" }
namespace "default" { policy = "read" }
```

---

## Teardown

```bash
# SSH to a node first
nomad job stop prometheus
nomad job stop grafana
```

To also remove Consul config entries:
```bash
consul config delete -kind http-route         -name prometheus
consul config delete -kind http-route         -name grafana
consul config delete -kind service-intentions -name prometheus
consul config delete -kind service-intentions -name grafana
consul config delete -kind service-defaults   -name prometheus
consul config delete -kind service-defaults   -name grafana
```

To remove data (EFS is shared — run on any node):
```bash
rm -rf /data/prometheus /data/grafana
```

To remove Nomad config from nodes, delete `/etc/nomad.d/telemetry.hcl` and `/etc/nomad.d/monitoring-volumes.hcl` and restart Nomad.
