# Nomad Workload Identity (NWI) with Consul

Nomad Workload Identity (NWI) lets Nomad tasks authenticate to Consul using short-lived,
automatically-rotated JWTs instead of static Consul tokens.

For the overall API Gateway architecture and route configuration, see [API_GATEWAY.md](API_GATEWAY.md).

## What is NWI

When a Nomad allocation starts, the Nomad server mints a signed JWT for each task that has
an `identity` block. The JWT is signed with the Nomad cluster keyring and scoped to a
specific audience (e.g. `consul.io`). The task can then present this JWT to Consul's auth
method to receive a scoped Consul ACL token — without any static token ever being stored
anywhere.

| Approach | Token storage | Security | Job spec |
|---|---|---|---|
| Static token in Nomad Variables + template | Nomad Variables (encrypted at rest) | Token is long-lived | Template block (verbose) |
| **NWI** (chosen) | Never stored — generated per-allocation | Short-lived, scoped JWT | `identity` block (clean) |

## When to use NWI

Use NWI for any task that needs to call the Consul API directly and requires a scoped token:

- **Custom gateway tasks** (e.g. the Consul API Gateway `setup` task) that must register
  themselves and receive xDS routing configuration
- Any task that needs Consul KV, catalog, or ACL operations beyond what a Connect sidecar
  provides automatically

**Regular workloads** (services with Connect sidecars) do not need `identity` blocks. Their
sidecar proxies receive tokens automatically — Nomad handles this internally using the
default binding rules created by `nomad setup consul`.

## How NWI works

```
Nomad server (task starts)
  │
  ├─ mints a short-lived JWT signed by the Nomad cluster keyring
  │   audience:  ["consul.io"]  (set in the identity block)
  │   ttl:       1h             (set in the identity block)
  │
  │   NOTE: Nomad does NOT automatically exchange the JWT for a Consul token for custom tasks.
  │   Automatic token injection only happens for Connect sidecars managed by Nomad internally.
  │   Custom tasks must explicitly call consul login to exchange the JWT.
  │
  ├─ JWT is exposed to the task via env var (requires env = true in the identity block):
  │   NOMAD_TOKEN_<identity-name>
  │
  └─ Task calls consul login to exchange the JWT for a Consul ACL token:
      echo "$NOMAD_TOKEN_<name>" > nwi.jwt
      consul login -method nomad-workloads \
        -bearer-token-file nwi.jwt \
        -token-sink-file consul.token
      → Consul fetches Nomad's JWKS at /.well-known/jwks.json, validates the JWT signature
      → Consul applies matching binding rules and issues a scoped ACL token
      → token written to consul.token
      export CONSUL_HTTP_TOKEN=$(cat consul.token || echo '')
```

### identity block fields

```hcl
identity {
  name        = "<name>"       # arbitrary; becomes NOMAD_TOKEN_<name> env var
  aud         = ["consul.io"]  # must match the Consul auth method's bound audiences
  ttl         = "1h"           # JWT lifetime — sufficient for prestart tasks
  env         = true           # exposes JWT as env var (required — file = true unreliable in Nomad 1.11.2)
  change_mode = "restart"      # silences Nomad warning for env=true; no-op for prestart tasks
}
```

### HCL interpolation note

In Nomad job spec `args`, use `$VAR` (no curly braces) for shell variables that should be
expanded at runtime inside the container. Nomad only interpolates `${...}` — curly-brace
forms are evaluated by Nomad before the container starts and will fail if the variable is
not a Nomad attribute or metadata key.

## Setup: bootstrap_acl.sh Phase 4

NWI requires two one-time setup steps run by `bootstrap_acl.sh` Phase 4:

**Step 1 — `nomad setup consul`**

```bash
CONSUL_HTTP_TOKEN=<consul-mgmt> NOMAD_TOKEN=<nomad-mgmt> \
  nomad setup consul -y -jwks-url http://127.0.0.1:4646/.well-known/jwks.json
```

Creates in Consul:
- JWT auth method `nomad-workloads` pointing to Nomad's JWKS endpoint
- ACL role `nomad-default-tasks` with read-only permissions for general Nomad tasks
- Default binding rules for Nomad services and tasks

The command is idempotent — safe to re-run.

**Step 2 — per-job binding rules**

Each job using NWI needs a binding rule that maps its JWT claims to a Consul policy.
Example for the api-gateway (see the API Gateway section below):

```bash
CONSUL_HTTP_TOKEN=<consul-mgmt> consul acl binding-rule create \
  -method nomad-workloads \
  -bind-type templated-policy \
  -bind-name builtin/api-gateway \
  -bind-vars 'Name=${value.nomad_job_id}' \
  -selector '"nomad_service" not in value and value.nomad_job_id=="api-gateway"'
```

Selector breakdown:
- `"nomad_service" not in value` — matches tasks (not Connect sidecar service registrations)
- `value.nomad_job_id=="api-gateway"` — scoped to this job only

**Verify NWI is configured**:

```bash
CONSUL_HTTP_TOKEN=<mgmt> consul acl auth-method list
# Should list 'nomad-workloads'

CONSUL_HTTP_TOKEN=<mgmt> consul acl binding-rule list -method nomad-workloads
# Should list default rules + any job-specific rules
```

**If bootstrap_acl.sh was already run without Phase 4**: run the two commands above manually
on any cluster node, with both management tokens set.

## Graceful behaviour before ACL is bootstrapped

The `identity` block can be present in the job spec from the start. Before `bootstrap_acl.sh`
is run, the `consul login` call falls back gracefully (`|| true`) because the `nomad-workloads`
auth method does not exist yet:

- `consul login` fails → `consul.token` is empty → `CONSUL_HTTP_TOKEN=""` → anonymous access
- Consul's `default_policy = "allow"` accepts anonymous access
- The task works normally

Once `enforce_acl.sh` switches to `default_policy = "deny"`, the token must be present — NWI
supplies it automatically on the next allocation start.

## Token lifetime

The JWT TTL is set in the `identity` block (`ttl = "1h"`). For prestart tasks that run for a
few seconds, the lifetime is not a concern. If tasks queue for over an hour under sustained
cluster load, increase the TTL.

---

## Example: Consul API Gateway

The api-gateway is the primary use of NWI in this cluster. Its `setup` task must call
`consul connect envoy -gateway api -register` which requires a Consul token with
`builtin/api-gateway` permissions to self-register and receive xDS routing configuration.

### Why NWI (not a static token)

The `setup` task runs `consul connect envoy -gateway api -register`. It needs a Consul token
with write permission on the `api-gateway` service and read access to all services and nodes
(for xDS routing). Storing a static token for this purpose would be long-lived and require
secure distribution. NWI provides a per-allocation, short-lived token with no storage needed.

### What builtin/api-gateway grants

`builtin/api-gateway` is a Consul built-in templated policy.
When instantiated with `Name=api-gateway` it grants:

```hcl
service "api-gateway" { policy = "write" }   # self-registration
node_prefix ""          { policy = "read"  }  # xDS: read node info for routing
service_prefix ""       { policy = "read"  }  # xDS: read all services for routing
```

No custom Consul policy file is needed.

### Job spec

```hcl
task "setup" {
  lifecycle { hook = "prestart"; sidecar = false }

  identity {
    name        = "consul_api_gateway"
    aud         = ["consul.io"]
    ttl         = "1h"
    env         = true
    change_mode = "restart"
  }

  config {
    image   = "hashicorp/consul:1.22.3"
    command = "/bin/sh"
    args = ["-c", join(" && ", [
      "echo \"$NOMAD_TOKEN_consul_api_gateway\" > ${NOMAD_SECRETS_DIR}/nwi.jwt && consul login -method nomad-workloads -bearer-token-file ${NOMAD_SECRETS_DIR}/nwi.jwt -token-sink-file ${NOMAD_ALLOC_DIR}/consul.token || true",
      "export CONSUL_HTTP_TOKEN=$(cat ${NOMAD_ALLOC_DIR}/consul.token || echo '')",
      "consul connect envoy -gateway api -register -deregister-after-critical 10s -service ${NOMAD_JOB_NAME} -admin-bind 0.0.0.0:19000 -ignore-envoy-compatibility -bootstrap > ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json"
    ])]
  }

  env {
    # Node IP required — bridge networking containers cannot reach the host loopback
    CONSUL_HTTP_ADDR = "http://${attr.unique.network.ip-address}:8500"
    CONSUL_GRPC_ADDR = "${attr.unique.network.ip-address}:8503"
  }
}
```

### Operational notes

**Before enforce_acl.sh**: restart the api-gateway so the new allocation starts with a NWI
token (the allocation running before bootstrap_acl.sh was run has no token and will lose its
xDS connection the moment deny mode is activated):

```bash
nomad job stop api-gateway
nomad job run infrastructure/api-gateway/job.nomad.hcl
```

**Adding a new node**: no changes needed — NWI is configured in Consul and Nomad server
state, not per-node.

---

## Future improvement: agent-level task_identity

The current approach uses a job-level `identity` block + explicit `consul login` in the task
command. Nomad 1.7+ supports an alternative: `task_identity` in the Nomad agent's `consul {}`
stanza, which makes Nomad automatically derive a Consul token for every task and inject it as
`CONSUL_HTTP_TOKEN` — no `identity` block or `consul login` needed in the job spec.

```hcl
# /etc/nomad.d/consul.hcl (written by bootstrap_acl.sh)
consul {
  task_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }
}
```

**Why not done yet:** `task_identity` issues tokens to all tasks, which requires additional
binding rules in `bootstrap_acl.sh` to scope permissions correctly. The current per-job
`identity` approach is more surgical and easier to audit. Worth adopting if more jobs need
direct Consul API access in the future.

## Relation to ACL documentation

See [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md) for the full ACL bootstrap procedure.
NWI is Phase 4 of `bootstrap_acl.sh` and must run before `enforce_acl.sh`.

## References

- https://github.com/hashicorp-guides/consul-api-gateway-on-nomad — primary reference for NWI + api-gateway pattern
- https://developer.hashicorp.com/nomad/docs/concepts/workload-identity — NWI concept, identity block fields
- https://developer.hashicorp.com/nomad/tutorials/integrate-consul/deploy-api-gateway-on-nomad — step-by-step tutorial
- https://developer.hashicorp.com/nomad/api-docs/operator/keyring — Nomad keyring and JWKS endpoint
