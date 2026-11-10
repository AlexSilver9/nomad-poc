# api-gateway: "ACL not found" on setup task (Raft follower nodes)

## Symptom

After deploying or redeploying the api-gateway job, allocations on some nodes fail.
The `setup` prestart task log shows:

```
Error checking dual stack: Unexpected response code: 403 (ACL not found)
Error checking dual stack: Unexpected response code: 403 (ACL not found)
Error checking dual stack: Unexpected response code: 403 (ACL not found)
```

The `api` task never starts (envoy_bootstrap.json is empty / not written).

## Affected nodes

Consul/Nomad **server nodes that are Raft followers** (not the current leader).
Client-only nodes are not affected.

## Root cause

The setup task calls `consul login` to exchange the NWI JWT for a Consul ACL token.
The login request is forwarded to the Consul leader, which commits the new token to Raft
and responds. On follower nodes the local ACL state machine may not have applied the new
Raft entry by the time `consul connect envoy -bootstrap` immediately uses the token in the
same shell command — so the local Consul agent returns "ACL not found".

**Why only follower nodes:**
- **Leader node**: creates the token, applies it locally before responding → immediately visible.
- **Client-only nodes**: forward ACL validation RPCs to a server that already has the entry → never see stale state.
- **Follower server nodes**: validate ACL tokens against their local state machine, which may lag the leader by a few milliseconds after a write.

The root cause is a race between Raft commit acknowledgment and state machine application
on the follower. The window is tiny (milliseconds) but consistent under normal load.

## Fix

Add `sleep 2` between `consul login` and `consul connect envoy` in the setup task's
command. This gives Raft replication and state machine application time to complete on
follower nodes before the token is used.

In the job's `args` (HCL `join(" && ", [...])` pattern):

```hcl
join(" && ", [
  "... consul login ... -token-sink-file ${NOMAD_ALLOC_DIR}/consul.token || true",
  "export CONSUL_HTTP_TOKEN=$(cat ${NOMAD_ALLOC_DIR}/consul.token || echo '')",
  "sleep 2",
  "consul connect envoy -gateway api -register ... -bootstrap > ${NOMAD_ALLOC_DIR}/envoy_bootstrap.json"
])
```

## Diagnostic approach

**Step 1 — Identify the failing alloc and read its stderr.**
```bash
nomad job allocs api-gateway
nomad alloc logs --stderr <alloc-id> setup
```

**Step 2 — Check node scheduling eligibility.**
After many failures Nomad may mark a node ineligible and stop scheduling on it.
```bash
nomad node status -self
nomad node status           # all nodes
# If Eligibility = ineligible:
nomad node eligibility -enable <node-id>
nomad job eval api-gateway
```

**Step 3 — Read the consul.token file from the failed alloc.**
This tells you whether `consul login` succeeded and what token it produced.
```bash
find /opt/nomad/data/alloc -name "consul.token" 2>/dev/null \
  | xargs -I{} sh -c 'echo "=== {} ==="; cat {}; echo'
```

**Step 4 — Check whether those tokens are valid in Consul right now.**
```bash
curl -s "http://localhost:8500/v1/acl/token/self" \
  -H "X-Consul-Token: <token-from-file>" | jq '.AccessorID // "NOT FOUND"'
```
- **NOT FOUND now** → token was never replicated or was immediately cleaned up; different issue.
- **AccessorID present now** → token is valid now but was not visible at the moment of use:
  confirms Raft timing. The `sleep 2` fix addresses this.

**Step 5 — Check who the Consul leader is.**
```bash
consul operator raft list-peers | grep -E 'leader|Node'
```
If the leader is on a different node, follower nodes are susceptible to this race.

**Step 6 — Check for stale Consul service registrations.**
A stale api-gateway registration left by a previously crashed alloc can interfere.
```bash
curl -s -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/services \
  | jq '.[] | select(.Kind == "api-gateway" or (.ID | contains("api-gateway"))) | {ID, Kind, Port}'
# If a stale entry appears, deregister it:
curl -s -X PUT -H "X-Consul-Token: $CONSUL_HTTP_TOKEN" \
  http://localhost:8500/v1/agent/service/deregister/api-gateway
```

**Step 7 — Check NWI auth method and binding rules.**
```bash
consul acl auth-method read -name nomad-workloads
consul acl binding-rule list -method nomad-workloads -format json
```
Verify the `builtin/api-gateway` templated-policy binding rule is present with selector
`"nomad_service" not in value and value.nomad_job_id=="api-gateway"`.

**Step 8 — Verify ACL token visibility on this node** (sanity check).
```bash
NEW_TOKEN=$(consul acl token create -description "test" \
  -service-identity="test" -format=json | jq -r '.SecretID')
curl -s -H "X-Consul-Token: $NEW_TOKEN" http://localhost:8500/v1/agent/self \
  | jq '.Config.NodeName // "NOT FOUND"'
consul acl token delete -id "$NEW_TOKEN" 2>/dev/null || true
```
If this also returns NOT FOUND immediately, the node has a broader ACL replication problem.

**Step 9 — Check Consul logs on the failing node.**
```bash
journalctl -u consul | grep -iE "acl|login|nomad-workloads" | tail -30
```
