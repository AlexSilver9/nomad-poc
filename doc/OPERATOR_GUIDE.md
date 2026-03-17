# Operator Guide

Quick-start guide for engineers operating the Nomad/Consul cluster day-to-day.

---

## Prerequisites

- `nomad` and `consul` CLIs installed locally (or login on remote machine inside the cluster with binaries installed)
- Your personal tokens (see [USER_TOKENS.md](USER_TOKENS.md))
- SSH access to a cluster node (for operations that must run on-node)

Node addresses: see `aws/bin/cluster/describe_running_instances.sh` or the AWS console.

---

## Set your tokens

Export once per shell session — all CLI commands pick them up automatically:

```bash
export NOMAD_ADDR=http://<node-ip>:4646
export NOMAD_TOKEN=<your-nomad-token>

export CONSUL_HTTP_ADDR=http://<node-ip>:8500
export CONSUL_HTTP_TOKEN=<your-consul-token>
```

Or pass per-command: `nomad status -token=<token>` / `consul members -token=<token>`

**Which token to use:**

| Task | Token |
|---|---|
| View job status, logs, nodes | Nomad readonly |
| Deploy, stop, exec into jobs | Nomad deployer |
| Drain / re-enable nodes | Nomad operator |
| Browse services, health, KV | Consul readonly or readwrite |
| Write Consul config entries | Consul readwrite |
| ACL administration | Management token (from `bootstrap-output.txt`) |

---

## UI access

- **Nomad UI**: `http://<node-ip>:4646` — click the person icon (top right) → Log in
- **Consul UI**: `http://<node-ip>:8500` — click Log in (top right)

Paste your token. The management token additionally exposes the ACL panel in both UIs.

---

## Common operations

### Check cluster health

```bash
nomad server members        # Nomad server nodes
nomad node status           # Nomad client nodes
consul members              # Consul nodes
```

### Start / deploy a service

```bash
nomad job plan services/<svc>/job.nomad.hcl    # dry run — shows what will change
nomad job run  services/<svc>/job.nomad.hcl    # deploy or update
```

For a new service that has no Consul config entries yet, apply those first:

```bash
consul config write services/<svc>/defaults.consul.hcl
consul config write services/<svc>/intentions.consul.hcl
consul config write services/<svc>/route.consul.hcl
nomad job run services/<svc>/job.nomad.hcl
```

See [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) for the full checklist.

### Stop a service

```bash
nomad job stop <job>           # stop allocations, keep job history
nomad job stop -purge <job>    # stop and remove job entirely
```

To also remove the Consul config entries:

```bash
consul config delete -kind http-route -name <svc>
consul config delete -kind service-intentions -name <svc>
consul config delete -kind service-defaults -name <svc>
```

### View job status and logs

```bash
nomad status                                       # all jobs
nomad job status <job>                             # job detail + allocation list
nomad job allocs <job>                             # allocation IDs only
nomad alloc status <alloc-id>                      # alloc detail, port mappings
nomad alloc logs -f <alloc-id> <task>              # stream stdout
nomad alloc logs -f -stderr <alloc-id> <task>      # stream stderr
nomad alloc exec -task=<task> <alloc-id> /bin/sh   # shell into alloc
```

### Apply a Consul config entry

```bash
consul config write services/<svc>/route.consul.hcl
consul config list -kind http-route                # verify
consul config read -kind http-route -name <svc>    # inspect
```

### Rolling update / canary deployment

```bash
nomad job plan services/<svc>/job.nomad.hcl        # review diff
nomad job run  services/<svc>/job.nomad.hcl        # submit update

# Canary: promote or roll back
nomad job deployments <job>                        # get deployment ID
nomad deployment promote <deployment-id>           # approve canary
# or
nomad deployment fail    <deployment-id>           # roll back
```

### Node drain (planned maintenance)

```bash
nomad node status                                  # get node IDs
nomad node drain -enable -yes <node-id>           # drain (wait for allocs to migrate)
# ... perform maintenance ...
nomad node drain -disable <node-id>               # re-enable
nomad job eval api-gateway                        # reschedule system jobs if needed
nomad job eval traefik-rewrite                    # (same for other system jobs)
```

---

## Token management

Token operations require the management token from `aws/acl/bootstrap-output.txt`.
All scripts run on a cluster node.

### Create tokens for a new operator

1. Add the user to `aws/acl/users.json` (see [USER_TOKENS.md](USER_TOKENS.md))
2. SSH to a node and run:

```bash
export NOMAD_TOKEN=<management-token>
export CONSUL_HTTP_TOKEN=<management-token>
./create_user_tokens.sh
```

Tokens are appended to `~/acl/user-tokens-output.txt`. Transfer to the password manager and delete the file.

### Revoke tokens

```bash
export NOMAD_TOKEN=<management-token>
export CONSUL_HTTP_TOKEN=<management-token>
./revoke_nomad_user_tokens.sh <username>
./revoke_consul_user_tokens.sh <username>
```

### Change a user's roles

```bash
# Find the accessor ID
NOMAD_TOKEN=<mgmt> nomad acl token list -json | jq '.[] | select(.Name == "<username>")'

# Update
NOMAD_TOKEN=<mgmt> nomad acl token update -accessor-id=<id> -role-name=deployer -role-name=operator
CONSUL_HTTP_TOKEN=<mgmt> consul acl token update -id=<id> -role-name=readwrite
```

See [USER_TOKENS.md](USER_TOKENS.md) for the full procedure.

---

## Node management

### Add standard client nodes

Run from your local machine. Creates EC2 instances, installs Consul + Nomad client, mounts
EFS, and registers with the ALB target group.

```bash
./aws/bin/cluster/add_client_nodes.sh          # add 1 node
./aws/bin/cluster/add_client_nodes.sh 3        # add 3 nodes
```

Verify after completion:

```bash
nomad node status       # new node should appear (may take ~30 s)
consul members          # should include the new node
```

System jobs (`api-gateway`, `traefik-rewrite`, `nginx-rewrite`) are scheduled automatically on new nodes
because they are `system` type. If they don't start within a minute:

```bash
nomad job eval api-gateway
nomad job eval traefik-rewrite
nomad job eval nginx-rewrite
```

### Add isolated (sensitive) nodes

Isolated nodes run in a dedicated `sensitive-node-pool`. Jobs must opt in explicitly via
`node_pool = "sensitive-node-pool"` in the job spec — no other jobs are scheduled here.

```bash
./aws/bin/cluster/add_isolated_nodes.sh        # add 1 isolated node
./aws/bin/cluster/add_isolated_nodes.sh 2      # add 2 isolated nodes
```

The script also creates the `sensitive-node-pool` in Nomad if it does not exist yet.

To add an existing standard node to the sensitive node pool instead of creating a new one,
update its Nomad config and restart the agent:

```bash
ssh ec2-user@<node>

# Add node_pool and meta to the client block in /etc/nomad.d/nomad.hcl
sudo sed -i '/^client {/a\  node_pool = "sensitive-node-pool"\n\n  meta {\n    workload_type = "sensitive-workloads"\n  }' /etc/nomad.d/nomad.hcl

sudo systemctl restart nomad
```

Verify the node joined the correct pool:

```bash
nomad node pool list                            # sensitive-node-pool should be listed
nomad node status                              # check the Pool column for the node
```

Verify:

```bash
nomad node pool list                            # sensitive-node-pool should be listed
nomad node status                              # check the Pool column for new nodes
```

### Remove a node

Drain the node first so running allocations migrate gracefully, then terminate the instance.

```bash
# 1. Drain (waits for all allocations to move)
nomad node drain -enable -yes <node-id>

# 2. Deregister from Nomad (optional — Nomad marks it ineligible automatically after drain)
nomad node eligibility -disable <node-id>

# 3. Deregister from Consul (happens automatically when the agent stops)

# 4. Deregister from ALB target group
aws elbv2 deregister-targets \
  --target-group-arn <arn> \
  --targets Id=<instance-id>,Port=8443

# 5. Terminate the EC2 instance
aws ec2 terminate-instances --instance-ids <instance-id>
```

Get the ALB target group ARN:
```bash
aws elbv2 describe-target-groups --names nomad-target-group \
  --query 'TargetGroups[0].TargetGroupArn' --output text
```

> `terminate_instances.sh` terminates **all** instances — do not use it for removing a
> single node.

---

## Where things live

| What | Where |
|---|---|
| Nomad jobs | `services/<svc>/job.nomad.hcl`, `infrastructure/*/job.nomad.hcl` |
| Consul config entries | `services/<svc>/*.consul.hcl`, `infrastructure/api-gateway/gateway.consul.hcl` |
| ACL policies / roles | `aws/acl/` |
| Cluster scripts (run locally) | `aws/bin/cluster/` |
| Instance scripts (run on node) | `aws/bin/instance/` |

---

## Debugging

```bash
# Envoy (API Gateway) state — run on any node
curl http://localhost:19000/config_dump     # full Envoy config
curl http://localhost:19000/clusters        # upstream services
curl http://localhost:19000/listeners       # active listeners

# API Gateway logs
nomad alloc logs <alloc-id> api            # Envoy logs
nomad alloc logs <alloc-id> setup          # setup task / NWI login

# Consul service health
consul catalog services
curl -s http://localhost:8500/v1/health/service/<svc> | jq '.[].Checks[].Status'
```

See [CHEATSHEET.md](CHEATSHEET.md) for a full command reference.
