# Nomad Workload Identity (NWI) with Consul

Nomad Workload Identity (NWI) lets Nomad tasks authenticate to Consul using short-lived,
automatically-rotated JWTs instead of static Consul tokens. This document covers how it is
used for the Consul API Gateway job and what was set up to make it work.

## Background: why NWI for the API Gateway

The Consul API Gateway runs as a custom Nomad job (two tasks: `setup` + `api`) because Nomad
has no native `connect { gateway { api {} } }` jobspec support — that block type does not exist
like `connect { sidecar_service {} }` in nomad jobs.
The `setup` task runs `consul connect envoy -gateway api -register`, which needs a
Consul token with `builtin/api-gateway` permissions to register the gateway and receive xDS
routing configuration.

Options considered:

| Approach | Token storage | Security | Job spec |
|---|---|---|---|
| Static token in Nomad Variables + template | Nomad Variables (encrypted at rest) | Token is long-lived | Template block (verbose) |
| **NWI** (chosen) | Never stored — generated per-allocation | Short-lived, scoped JWT | `identity` block (clean) |

NWI was chosen because it avoids storing any static Consul token and the job spec stays clean.

## How it works

```
Nomad (setup task starts)
  │
  ├─ mints a short-lived JWT signed by the Nomad cluster keyring
  │   audience: ["consul.io"]
  │   writes JWT to ${NOMAD_SECRETS_DIR}/consul_api_gateway
  │
  │   NOTE: Nomad does NOT automatically exchange the JWT for a Consul token for custom tasks.
  │   Automatic token injection only happens for Connect sidecars (managed by Nomad internally).
  │   For custom tasks like the setup task, the command must explicitly call consul acl login.
  │
  ├─ setup command calls consul acl login:
  │   consul acl login -method nomad-workloads
  │     -bearer-token-file ${NOMAD_SECRETS_DIR}/consul_api_gateway
  │     -token-sink-file ${NOMAD_ALLOC_DIR}/consul.token
  │   → Consul fetches Nomad's JWKS, validates JWT, applies binding rules, issues token
  │   → token written to consul.token file (|| true — graceful fallback when ACL not bootstrapped)
  │
  └─ Consul applies the api-gateway binding rule and issues a Consul ACL token:
      • api-gateway rule → builtin/api-gateway (service-write + read all services/nodes)
        selector: "nomad_service" not in value and value.nomad_job_id=="api-gateway"

The setup command reads the token from the file and passes it to consul connect envoy:
  export CONSUL_HTTP_TOKEN=$(cat ${NOMAD_ALLOC_DIR}/consul.token 2>/dev/null || echo '')
  consul connect envoy -gateway api ...
  (if consul.token is empty — ACL not bootstrapped — anonymous access works in allow mode)
```

## What builtin/api-gateway grants

`builtin/api-gateway` is a Consul built-in templated policy. When instantiated with
`Name=api-gateway`, it grants:

```hcl
service "api-gateway" { policy = "write" }   # self-registration
node_prefix ""          { policy = "read"  }  # xDS: read node info for routing
service_prefix ""       { policy = "read"  }  # xDS: read all services for routing
```

No custom Consul policy file is needed — `builtin/api-gateway` is built into Consul 1.15+.

## Graceful no-ACL behaviour

The `identity` block is always present in the job spec. When ACL has not been bootstrapped:

- No `nomad-workloads` auth method exists → Nomad cannot exchange the JWT → `CONSUL_TOKEN`
  is not injected → `CONSUL_HTTP_TOKEN=$CONSUL_TOKEN` resolves to an empty string
- Consul's `default_policy = "allow"` accepts anonymous (empty-token) access
- The gateway starts normally

Once `bootstrap_acl.sh` is run and then `enforce_acl.sh` switches to `default_policy = "deny"`,
the token must be present. NWI supplies it automatically on the next allocation start.

## Setup: what bootstrap_acl.sh does (Phase 4)

Phase 4 runs inside Phase 3's success block (both Consul and Nomad management tokens available):

**Step 1 — `nomad setup consul`**

```bash
CONSUL_HTTP_TOKEN=<consul-mgmt> NOMAD_TOKEN=<nomad-mgmt> \
  nomad setup consul -y -jwks-url http://127.0.0.1:4646/.well-known/jwks.json
```

Creates in Consul:
- JWT auth method `nomad-workloads` pointing to Nomad's JWKS endpoint
- ACL role `nomad-default-tasks` with read-only permissions for Nomad tasks
- Default binding rules for Nomad services and tasks

`-y` makes it non-interactive. The command is idempotent — safe to re-run.

**Step 2 — api-gateway binding rule**

```bash
CONSUL_HTTP_TOKEN=<consul-mgmt> consul acl binding-rule create \
  -method nomad-workloads \
  -bind-type templated-policy \
  -bind-name builtin/api-gateway \
  -bind-vars 'Name=${value.nomad_job_id}' \
  -selector '"nomad_service" not in value and value.nomad_job_id=="api-gateway"'
```

Selector breakdown:
- `"nomad_service" not in value` — matches tasks only (not Connect sidecar service registrations)
- `value.nomad_job_id=="api-gateway"` — scoped to the api-gateway job specifically

`Name=${value.nomad_job_id}` passes the job name (`api-gateway`) to the templated policy,
instantiating `builtin/api-gateway` with `service "api-gateway" { policy = "write" }`.

## Job spec

The relevant parts of `aws/infrastructure/api-gateway/job.nomad.hcl`:

```hcl
task "setup" {
  # ...

  identity {
    name = "consul_api_gateway"
    aud  = ["consul.io"]
    ttl  = "1h"
  }

  config {
    image   = "hashicorp/consul:1.22.3"
    command = "/bin/sh"
    args = [
      "-c",
      join(" && ", [
        "consul acl login -method nomad-workloads -bearer-token-file ${NOMAD_SECRETS_DIR}/consul_api_gateway -token-sink-file ${NOMAD_ALLOC_DIR}/consul.token 2>/dev/null || true",
        "export CONSUL_HTTP_TOKEN=$(cat ${NOMAD_ALLOC_DIR}/consul.token 2>/dev/null || echo '')",
        "consul connect envoy -gateway api -register ... -bootstrap > ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json"
      ])
    ]
  }

  env {
    CONSUL_HTTP_ADDR = "http://${attr.unique.network.ip-address}:8500"
    CONSUL_GRPC_ADDR = "${attr.unique.network.ip-address}:8502"
  }
}
```

`$CONSUL_TOKEN` (no curly braces) is a shell variable — Nomad only interpolates `${...}`,
so it reaches the container's shell as a runtime env var expansion. `${attr...}` and
`${NOMAD_JOB_NAME}` use curly braces and are interpolated by Nomad before the container starts.

## Operational notes

**After running bootstrap_acl.sh**: no immediate restart needed. Consul still runs with
`default_policy = "allow"` — the gateway works without a token. The restart is only required
**before running `enforce_acl.sh`** (which switches to deny mode). At that point the running
allocation was started before NWI existed and has no Consul token, so it would lose its xDS
connection once anonymous access is blocked.

```bash
# Run this right before enforce_acl.sh, not after bootstrap_acl.sh:
nomad job stop api-gateway
nomad job run infrastructure/api-gateway/job.nomad.hcl
```

**Regular workloads** (web-service, business-service, etc.) do not need `identity` blocks.
Their Connect sidecars are automatically handled by Nomad using the default binding rules
created by `nomad setup consul`.

**Adding a new node**: `onboard_node.sh` does not need changes — NWI is cluster-wide
(configured in Consul and Nomad server state, not per-node).

**Verify NWI is configured**:

```bash
# Should list 'nomad-workloads'
CONSUL_HTTP_TOKEN=<mgmt> consul acl auth-method list

# Should list binding rules including the api-gateway rule
CONSUL_HTTP_TOKEN=<mgmt> consul acl binding-rule list -method nomad-workloads
```

**If bootstrap_acl.sh was already run without Phase 4** (e.g. first run was on main branch):
run the two commands manually on any cluster node, with both management tokens set.

## Token lifetime

The JWT TTL is set to `1h` in the `identity` block. The `setup` task is a prestart task that
runs for a few seconds (bootstrap config generation), so the token lifetime is not a concern.
If the cluster is under sustained load and prestart tasks queue for over an hour, the JWT
would expire before being used — increase the TTL if this ever becomes an issue.

## Relation to ACL documentation

See [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md) for the full ACL bootstrap procedure.
NWI is Phase 4 of `bootstrap_acl.sh` and must run before `enforce_acl.sh`.
