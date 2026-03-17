# Cluster Setup Guide

End-to-end guide for building a 3-node Nomad + Consul cluster on AWS, from scratch to a
fully running cluster with services, load balancer, and optional ACL enforcement.

The resulting cluster follows the architecture described in [ARCHITECTURE.md](ARCHITECTURE.md).

All scripts run from your **local machine** unless noted otherwise.

---

## Prerequisites

**AWS resources** — VPC, subnets, security groups, and key pair must exist before running setup. See [PREREQUISITES.md](PREREQUISITES.md) for the full list of required AWS resources and security group port rules.

Before running `setup_cluster.sh` or `rebuild_cluster.sh` for the first time, update the hardcoded AWS resource IDs in these scripts:

| Script | What to update |
|---|---|
| `aws/bin/cluster/create_instances.sh` | `SubnetId` — subnet for EC2 instances; max five `sg-*` IDs — security groups for EC2 instances |
| `aws/bin/cluster/create_target_group.sh` | `VPC_ID` — VPC the target group belongs to |
| `aws/bin/cluster/create_alb.sh` | `SUBNETS` — two subnets in different AZs for the ALB; `SECURITY_GROUPS` — security groups for the ALB |
| `aws/bin/cluster/setup_cluster.sh` | `GITHUB_RAW_BASE` — GitHub repo URL and branch name if forked or renamed |

**Local tools required:**
```bash
aws-cli    # configured with access to the target AWS account
jq         # JSON processor (brew install jq)
ssh        # with key at ~/workspace/nomad/nomad-keypair.pem (or set SSH_KEY env var)
```

**GitHub**: `setup_cluster.sh` downloads job files and scripts directly from the
`api-gateway` branch on GitHub. Push all local changes before running setup:
```bash
git push origin api-gateway
```

---

## Fresh cluster setup (automated)

One script handles everything: EC2 instances, EFS, Consul, Nomad, Consul config entries,
Nomad jobs, ALB, and a smoke test.

```bash
cd aws/bin/cluster
./setup_cluster.sh
```

What it does, in order:

| Step | What happens |
|---|---|
| 1 | Creates 3 EC2 instances (t3.small, eu-central-1) |
| 2 | Creates EFS volume and mounts it on all nodes |
| 3 | Waits for SSH on all nodes |
| 4 | Installs Consul on all nodes (rolling, parallel) |
| 5 | Installs Nomad on all nodes (with CNI plugins, Docker, Consul integration) |
| 6 | Writes Consul config entries (service-defaults, intentions, routes, gateway) |
| 7 | Runs Nomad jobs: traefik-rewrite, api-gateway, web-service, business-service, https-service |
| 8 | Smoke-tests internal routing via HTTP on port 8081 |
| 9 | Creates ALB target group + load balancer |
| 10 | Waits for ALB targets to be healthy, tests ALB endpoints |
| 11 | Downloads additional operation scripts to the first node |

At the end, the script prints node DNS names, ALB DNS, and SSH commands.

**To rebuild from scratch** (tears down everything first):
```bash
./rebuild_cluster.sh
```

**To tear down only** (no rebuild):
```bash
./teardown_cluster.sh
```

---

## ACL setup (optional, recommended for production)

ACL is a Day-2 operation — run it on a healthy, fully running cluster. It is a three-step
process with a mandatory gap between bootstrapping and enforcing.

### Step 1 — Bootstrap

```bash
cd aws/bin/cluster
./bootstrap_acl.sh
```

What it does:
- **Phase 0**: Enables `acl { enabled = true, default_policy = "allow" }` on all nodes, rolling restart of Consul
- **Phase 1**: Bootstraps Consul ACL, creates policies and infrastructure tokens, applies agent tokens
- **Phase 2**: Writes Nomad's Consul integration token to all nodes, restarts Nomad
- **Phase 3**: Bootstraps Nomad ACL, creates policies (no user tokens yet)
- **Phase 4**: Configures Nomad Workload Identity (NWI) — required for the API Gateway

After this step, Consul still allows unauthenticated access (`default_policy = "allow"`).
The Nomad UI requires the management token immediately.

Tokens are saved to `aws/acl/bootstrap-output.txt` — store these securely.

### Step 2 — Between bootstrap and enforce (mandatory)

Before switching Consul to deny mode, the API Gateway allocation must be restarted so it
picks up a NWI token. The running allocation was started before NWI existed and has no
Consul token — it would lose its xDS connection the moment deny mode activates.

```bash
ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<NODE>

# Restart api-gateway to pick up NWI token
nomad job stop api-gateway
nomad job run infrastructure/api-gateway/job.nomad.hcl
```

At this point is a good idea to create tokens for users. See [USER_TOKENS.md](USER_TOKENS.md) for the full procedure

```bash
# Optional: create operator/user tokens (alice, bob, etc.)
ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<NODE>
./create_user_tokens.sh
```

### Step 3 — Enforce (maintenance window)

```bash
cd aws/bin/cluster
./enforce_acl.sh
```

This is a **one-way operation**. It switches Consul to `default_policy = "deny"` on all
nodes via rolling restart. After this, all Consul UI and API access requires a valid token.

Verify:
```bash
open http://<node>:8500   # should prompt for a token
```

For full ACL details and troubleshooting, see [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md).

---

## Testing routing

The test script runs from your local machine and covers all routing scenarios:

```bash
cd aws/bin/cluster
./test_routing.sh <NODE_IP>
```

Tests covered (14 total):
- Gateway reachability (unknown hostname → 404)
- web-service HTTP routing
- business-service HTTP routing, path rewrite (`/api` → `/business-service/api`), legacy download
- URL regex rewrite via rewriter port 8081 (`/download/<token>` → `/business-service/download.xhtml?token=<token>`)
- HTTPS routing via port 8443 (TLS termination, hostname routing, regex rewrite)
- https-service end-to-end TLS
- TCP passthrough port 8082

Expected result: **14/14 PASS**.

For details on the routing architecture, see [API_GATEWAY.md](API_GATEWAY.md).

---

## Switching between Traefik and nginx

After setup, **Traefik** runs as the default rewriter on ports 8081 and 8443. **nginx** is
downloaded to the first node but not started (both bind the same ports — only one can run).

Both pass all 14 routing tests. The key difference is the URL rewrite format:
- **nginx**: `/business-service/download.xhtml?token=abc123` (query-param - full featured regex groups capture)
- **Traefik v3**: `/business-service/download.xhtml/abc123` (path-based only — v3 limitation)

**Switch to nginx:**
```bash
ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<NODE>
nomad job stop traefik-rewrite
nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
sleep 15   # wait for gen-cert prestart task
nomad job status nginx-rewrite   # verify: 3 allocations running
```

**Switch back to Traefik:**
```bash
nomad job stop nginx-rewrite
nomad job run infrastructure/traefik-rewrite/job.nomad.hcl
```

---

## Adding nodes

**Standard node** (joins default pool):
```bash
cd aws/bin/cluster
./add_client_nodes.sh [count]   # default: 1
```

**Isolated node** (joins sensitive-node-pool, for sensitive-service):
```bash
./add_isolated_nodes.sh [count]
```

Both scripts create new EC2 instances, install Consul + Nomad, register them with the
cluster, and add them to the ALB target group.

After adding a node, system jobs (traefik, nginx, api-gateway) need to be re-evaluated to
schedule an allocation on the new node:
```bash
ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<NODE>
./eval_system_jobs.sh
```

---

## UIs

| UI | URL | Auth required |
|---|---|---|
| Nomad | `http://<node>:4646` | after ACL bootstrap: Management or user token |
| Consul | `http://<node>:8500` | allow mode: No / after enforce: Management or user token |

---

## Related documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Cluster architecture overview |
| [PREREQUISITES.md](PREREQUISITES.md) | AWS resources required before running setup (VPC, subnets, security groups, ports) |
| [API_GATEWAY.md](API_GATEWAY.md) | API Gateway architecture, traffic flows, routes, adding services |
| [NWI.md](NWI.md) | Nomad Workload Identity — how the API Gateway authenticates to Consul |
| [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md) | Full ACL bootstrap procedure and token structure |
| [USER_TOKENS.md](USER_TOKENS.md) | Creating and managing personal operator tokens |
| [CHEATSHEET.md](../doc/CHEATSHEET.md) | Common Nomad/Consul CLI commands |
| [VAULT.md](VAULT.md) | Vault setup (optional) |
