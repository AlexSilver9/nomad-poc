# List of useful Nomad commands

## Official Cheat Sheet
- https://hashicorp.github.io/nomad-cheatsheet/
- https://www.datocms-assets.com/2885/1650045163-kubernetes-to-nomad-cheat-sheet-v2.pdf

## Cluster Validation

List server members:
```shell
nomad server members
```

Show node status:
```shell
nomad node status
```

Show Raft info:
```shell
nomad operator raft list-peers
```

Run job:
```shell
nomad run <job-file>
# or 
nomad job run <job-file>
```

List Jobs:
```shell
nomad status
```

Job status:
```shell
nomad status <job-name>
# or
nomad job status <job-name>
```

Allocation Id:
`Job status → Allocations Tabelle → ID Spalte`

Allocations (inkl. ID) für Job:
```shell
nomad job allocs <job-name>
```

Allocation status (incl. Dynamic Port Mapping):
```shell
nomad alloc status <allocation-id>
```

Execute command or open shell on alloc:
```shell
nomad alloc exec -task=<task-name> <allocation-id> <command>
# e.g. `nomad alloc exec -task=app 79d50fcd /bin/bash`
```

Logs:
```shell
nomad logs -f <allocation-id>
# or when alloc has multiple tasks
nomad logs -f <allocation-id> <task-name>

# or
nomad alloc logs -f <allocation-id>
# or when alloc has multiple tasks
nomad alloc logs -f <allocation-id> <task-name>

# stderr logs
nomad alloc logs -stderr <allocation-id>
# or when alloc has multiple tasks
nomad alloc logs -stderr <allocation-id>  <task-name>
```

Stop job:
```shell
nomad stop <job-name>
# or
nomad job stop <job-name>
```

Cleanup:
```shell
nomad stop -purge <job-name>
# or
nomad job stop -purge <job-name>
```

Server members:
```shell
nomad server members
```

Dry rum Upgrade deployment:
```shell
nomad job plan <job-file>
```

Insect Upgrade deployment:
```shell
nomad status <job-name>
```

Show deployments:
```shell
nomad job deployments <job-name>
```

Deployment status:
```shell
nomad deployment status <deployment-id>
```

Get Allocation IP address (e.g. for Testing Canary alloc directly)
```shell
nomad alloc status <canary allocation-id> | grep -A5 'Allocation Addresses'
```

Fail deployment (Rollback Canary)
```shell
nomad deployment fail <deployment-id>
```

Promote deployment (Approve Canary for Rollout)
```shell
nomad deployment promote <deployment-id>
```

Job history:
```shell
nomad job history -p <job-name>
```

Garbage Collection
```shell
nomad system gc
```

Node Drain Enable
```shell
nomad node drain -enable -yes <node-id>
```

Node Drain Disable
```shell
nomad node drain -disable -yes <node-id>
```

## Consul — Service Health

Check health of a service (via HTTP API):
```shell
curl -s http://localhost:8500/v1/health/service/<service-name> | jq '.[].Checks[].Status'
```

## Consul — Config Entries

List config entries by kind:
```shell
consul config list -kind api-gateway
consul config list -kind http-route
consul config list -kind tcp-route
consul config list -kind service-router
consul config list -kind service-intentions
consul config list -kind service-defaults
```

Read a specific config entry:
```shell
consul config read -kind api-gateway -name api-gateway
```

## Nomad — System Job Troubleshooting

Re-evaluate a system job to schedule missing allocations (e.g. after node drain/re-enable):
```shell
nomad job eval <job-name>
```

Check node scheduling eligibility (ineligible nodes are skipped by system jobs):
```shell
nomad node status -self
nomad node status          # all nodes
nomad node eligibility -enable <node-id>
```

Read the consul.token written by a NWI login in a prestart task (useful to diagnose
"ACL not found" errors — check whether consul login produced a token at all):
```shell
find /opt/nomad/data/alloc -name "consul.token" 2>/dev/null \
  | xargs -I{} sh -c 'echo "=== {} ==="; cat {}; echo'
```

## Nomad — Signals

Send a signal to a task in a running alloc:
```shell
nomad alloc signal -s <SIGNAL> -task <task> <alloc-id>
```

Example: hot-reload nginx config without downtime (SIGHUP re-reads config,
gracefully drains old workers, no connections dropped):
```shell
nomad alloc signal -s HUP -task nginx <alloc-id>
```

## Consul — Service Registration

List services registered on the local agent:
```shell
curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/services | jq 'keys'
```

Show a specific registered service (useful to spot stale registrations):
```shell
curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/services \
  | jq '.[] | select(.ID | contains("<service-name>")) | {ID, Kind, Port}'
```

Deregister a stale service from the local agent:
```shell
curl -s -X PUT -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/service/deregister/<service-id>
```

## Consul — ACL

List all tokens:
```shell
consul acl token list
```

Check whether a specific token (SecretID) is valid and visible on this node:
```shell
curl -s "http://localhost:8500/v1/acl/token/self" \
  -H "X-Consul-Token: <secret-id>" | jq '.AccessorID // "NOT FOUND"'
```

Create a quick test token to verify ACL reachability:
```shell
NEW_TOKEN=$(consul acl token create -description "test" \
  -service-identity="test" -format=json | jq -r '.SecretID')
curl -s -H "X-Consul-Token: $NEW_TOKEN" http://localhost:8500/v1/agent/self \
  | jq '.Config.NodeName // "ACL NOT FOUND"'
consul acl token delete -id "$NEW_TOKEN" 2>/dev/null || true
```

List configured auth methods:
```shell
consul acl auth-method list
```

Read an auth method (e.g. to verify JWKS URL and token locality):
```shell
consul acl auth-method read -name nomad-workloads
```

List NWI (Nomad Workload Identity) binding rules:
```shell
consul acl binding-rule list -method nomad-workloads
consul acl binding-rule list -method nomad-workloads -format json
```

## Consul — Raft

Show Raft peer status (leader, commit index, replication lag):
```shell
consul operator raft list-peers
```

Identify the current leader:
```shell
consul operator raft list-peers | grep leader
```

## Envoy — Bootstrap JSON Inspection

Nomad's `envoy_bootstrap` prestart hook generates a bootstrap JSON at alloc start time.
Inspecting it reveals what `local_agent` address Envoy was given — the most common
source of xDS gRPC connection failures.

Find the file for a running alloc:
```shell
find /opt/nomad/data/alloc -name envoy_bootstrap.json 2>/dev/null
```

Pretty-print and inspect the `local_agent` cluster address:
```shell
cat /opt/nomad/data/alloc/<alloc-id>/alloc/envoy_bootstrap.json \
  | python3 -m json.tool \
  | grep -A5 "local_agent"
```

The address should be `<NODE_IP>:8502` (plain gRPC). If it shows `:8503` (TLS gRPC),
Envoy will fail with `DeltaAggregatedResources gRPC config stream to local_agent closed: 14,
connection termination`. See [CONNECT_SIDECAR_PITFALLS.md](CONNECT_SIDECAR_PITFALLS.md).

Read node-level Consul attributes reported to Nomad (includes gRPC port):
```shell
nomad node status -self -verbose | grep -i consul
```

## Envoy — Admin API

Envoy exposes an admin HTTP endpoint on port 19000 inside the container. Use this to
inspect what listeners and clusters Envoy has actually loaded from xDS.

From the host, if the alloc's network is in host mode:
```shell
curl -s http://localhost:19000/listeners
curl -s http://localhost:19000/clusters
curl -s http://localhost:19000/config_dump | python3 -m json.tool | less
```

If the task uses bridge/CNI networking, enter the container's network namespace first
(see nsenter section below) or use `nomad alloc exec`:
```shell
nomad alloc exec -task connect-proxy-<service> <alloc-id> \
  sh -c 'wget -qO- http://localhost:19000/listeners'
```

A healthy api-gateway or sidecar shows `public_listener` and any upstream listeners
in `/listeners`. Empty or stale config (no listeners from xDS) means the gRPC xDS
stream to Consul is broken.

## Low-Level Network Debugging

List listening TCP ports — quickly confirm which Consul ports are active on the node:
```shell
ss -tlnp | grep -E "850[0-9]"
```

Expected output for a Consul node with ACL:
```
LISTEN  0  128  0.0.0.0:8500  ...   # HTTP
LISTEN  0  128  0.0.0.0:8502  ...   # gRPC (plain)
LISTEN  0  128  0.0.0.0:8503  ...   # gRPC+TLS
```

Show all listening TCP ports with owning process:
```shell
ss -tlnp
```

Show established connections to a specific port (e.g. 8502):
```shell
ss -tnp dst :8502
```

## Docker / Container Debugging (Nomad docker driver)

When Nomad uses the `docker` task driver, containers are visible via `docker` commands.

List running containers (Nomad-managed containers have names based on alloc/task):
```shell
docker ps --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}'
```

Get full container metadata (mounts, network, env — useful to verify bind mounts):
```shell
docker inspect <container-id>
```

Follow container logs directly (same as `nomad alloc logs` but lower-level):
```shell
docker logs -f <container-id>
```

Get the host PID of the container's init process (needed for `nsenter`):
```shell
docker inspect <container-id> --format '{{.State.Pid}}'
```

## nsenter — Enter a Container's Namespace

`nsenter` runs a command inside a container's Linux namespace without going through
Docker exec or Nomad exec. Useful when those aren't available or when you need raw
network access (e.g. querying Envoy admin on a non-exposed port).

Enter the **network** namespace of a container (e.g. to curl Envoy admin):
```shell
sudo nsenter -t <container-pid> -n -- curl -s http://localhost:19000/listeners
```

Enter both network and mount namespaces:
```shell
sudo nsenter -t <container-pid> -n -m -- sh
```

Full workflow — find PID and enter in one step:
```shell
PID=$(docker inspect <container-id> --format '{{.State.Pid}}')
sudo nsenter -t "$PID" -n -- curl -s http://localhost:19000/clusters | python3 -m json.tool
```

`nsenter` flags:
| Flag | Namespace |
|------|-----------|
| `-n` | network (interfaces, routing, ports) |
| `-m` | mount (filesystem mounts) |
| `-p` | PID |
| `-u` | UTS (hostname) |
| `-i` | IPC |
