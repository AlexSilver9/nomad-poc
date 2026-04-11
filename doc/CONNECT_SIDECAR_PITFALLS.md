# Consul Connect Sidecar Pitfalls

Issues discovered during ACL activation and monitoring deployment on the POC cluster.
All of these must be addressed before deploying Connect sidecars or monitoring in production.

---

## 1. `grpc_address` in `consul.hcl` must be the node IP, not 127.0.0.1

**Symptom**: All Connect sidecar proxies fail to connect to Consul xDS with:
```
DeltaAggregatedResources gRPC config stream to local_agent closed: 14,
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

**Root cause**: Nomad creates a unix socket (`alloc/tmp/consul_grpc.sock`) as a plain TCP proxy
to the `grpc_address` configured in `consul.hcl`. Envoy sidecars connect through this socket.
The socket is accessed from *inside* the bridge network namespace, where `127.0.0.1` is the
container's own loopback — not the host. Consul is not listening there.

**Fix**: Use the node's primary IP:
```hcl
consul {
  grpc_address = "<NODE_IP>:8502"
}
```

In scripts, resolve at install time:
```bash
NODE_IP="$(/sbin/ip route get 1 | awk '{print $7; exit}')"
```

**Affects**: `setup_nomad.sh` / `setup_nomad_aws_ami.sh`, `bootstrap_acl.sh`, `apply_acl_config.sh`

**Does NOT affect**: The api-gateway job — it uses `CONSUL_GRPC_ADDR` env var which is passed
directly to the `consul` CLI, which handles the connection itself outside of Nomad's proxy.

---

## 2. `grpc_address` must use port 8502 (plain gRPC), not 8503 (TLS gRPC)

**Symptom**: Same connection termination as above, even after fixing the IP.

**Root cause**: Nomad's unix socket proxy is a plain TCP forwarder — it does not negotiate TLS.
Port 8503 is Consul's TLS gRPC port (required by Consul 1.14+). Connecting to it without TLS
causes immediate connection termination.

**Fix**: `grpc_address` in `consul.hcl` stays on port 8502 (plain gRPC).

**Port summary**:
| Config location | Port | Reason |
|---|---|---|
| `consul.hcl` → `grpc_address` (Nomad's proxy) | **8502** | Plain TCP proxy, no TLS |
| api-gateway job → `CONSUL_GRPC_ADDR` (consul CLI) | **8503** | CLI handles TLS itself |

**Affects**: `setup_nomad.sh` / `setup_nomad_aws_ami.sh`, `bootstrap_acl.sh`, `apply_acl_config.sh`

---

## 3. api-gateway `CONSUL_GRPC_ADDR` must use port 8503

**Symptom**: api-gateway `setup` task fails to generate Envoy bootstrap config:
```
consul connect envoy -gateway api -register ... -bootstrap: exit status 1
```

**Root cause**: In Consul 1.22, the plain gRPC port (8502) no longer accepts the xDS protocol.
The `consul connect envoy -bootstrap` CLI requires TLS gRPC on port 8503.

**Fix**:
```hcl
env {
  CONSUL_GRPC_ADDR = "${attr.unique.network.ip-address}:8503"
}
```

Note: Must use `attr.unique.network.ip-address` (node IP), not `127.0.0.1`, for the same
bridge namespace reason as above.

**Affects**: `infrastructure/api-gateway/job.nomad.hcl`

---

## 4. After `bootstrap_acl.sh`, running jobs must be restarted to pick up NWI tokens

**Symptom**: api-gateway stops routing traffic immediately after ACL enforcement is switched
to `default_policy = "deny"`, even though `bootstrap_acl.sh` succeeded.

**Root cause**: The api-gateway allocation running before ACL was bootstrapped has no NWI token.
Once deny mode is active, its anonymous xDS connection is rejected by Consul.

**Fix**: Restart the api-gateway after `bootstrap_acl.sh` and before `enforce_acl.sh`:
```bash
nomad job stop api-gateway
NOMAD_TOKEN=<mgmt> nomad job run infrastructure/api-gateway/job.nomad.hcl
```

Similarly, all Connect sidecar jobs (web-service, business-service, etc.) should be restarted
to pick up service identity tokens.

---

## 5. `nomad job run` and `consul config write` silently pass empty tokens without ACL

**Symptom**: Jobs fail with `403 Permission denied` or `403 ACL not found` when called from
scripts that use `${NOMAD_TOKEN:-}` or `${CONSUL_HTTP_TOKEN:-}` without the variables being set.

**Root cause**: The `:-` fallback substitutes an empty string, which is passed to the CLI.
The CLI then makes an unauthenticated request which is rejected in enforce mode.

**Fix**:
1. Always `export NOMAD_TOKEN=<secret-id>` and `export CONSUL_HTTP_TOKEN=<secret-id>` before
   running any cluster script when ACL is enforced.
2. Scripts should verify tokens are valid (not just non-empty) before proceeding:
   ```bash
   curl -s -o /dev/null -w '%{http_code}' \
     -H "X-Nomad-Token: $NOMAD_TOKEN" http://localhost:4646/v1/jobs
   # Expect 200, not 403
   ```

---

## 6. Consul ACL detection: do not use `/v1/catalog/services`

**Symptom**: Script reports "Consul ACL not enforced" even when ACL is enabled.

**Root cause**: `GET /v1/catalog/services` returns HTTP 200 even with ACL enabled (anonymous
read is allowed by the catalog endpoint even in deny mode for some versions).

**Fix**: Use an endpoint that is always protected:
```bash
curl -s -o /dev/null -w '%{http_code}' http://localhost:8500/v1/acl/tokens
# Returns 403 when ACL is enforced, 200 when not
```

---

## 7. Bcrypt hashes cannot be passed via `-var=` in shell

**Symptom**: Nomad job fails with `crypto/bcrypt: hashedSecret too short`.

**Root cause**: Bcrypt hashes contain `$` (e.g. `$2b$12$...`). Passing via
`-var=hash=$2b$12$...` causes the shell to expand `$2b`, `$12` as empty variables,
corrupting the hash.

**Fix**: Base64-encode the value locally, then decode and write a var-file on the remote node
using Python (which has no shell expansion issues):
```bash
hash_b64=$(echo -n "$hash" | base64)
ssh node python3 <<PYEOF
import base64
val = base64.b64decode('${hash_b64}').decode()
open('/tmp/vars.hcl', 'w').write('hash = "%s"\n' % val)
PYEOF
nomad job run -var-file=/tmp/vars.hcl job.nomad.hcl
```

---

## 8. Grafana admin password is only applied on first init

**Symptom**: After redeploying Grafana with a different `GF_SECURITY_ADMIN_PASSWORD`, the old
password still works.

**Root cause**: Grafana writes its admin password to `grafana.db` (SQLite) on first start.
`GF_SECURITY_ADMIN_PASSWORD` is only applied when the database does not exist. On EFS-backed
deployments the database persists across redeploys.

**Fix**: Change the admin password via the Grafana API or UI. To reset from scratch, delete
`/data/grafana/grafana.db` on EFS before redeploying.

---

## 9. Grafana enforces 8-character minimum password

**Symptom**: Tech user creation silently fails or returns HTTP 400.

**Root cause**: Grafana 11 rejects passwords shorter than 8 characters.

**Fix**: Enforce length in the setup script before attempting creation:
```bash
[[ ${#password} -ge 8 ]] || { echo "Password must be at least 8 characters"; exit 1; }
```

---

## Production checklist

Before enabling ACL and deploying monitoring in production, verify:

- [ ] `grpc_address` in `consul.hcl` uses `<NODE_IP>:8502` (not `127.0.0.1`, not 8503)
- [ ] api-gateway job uses `CONSUL_GRPC_ADDR = "<NODE_IP>:8503"`
- [ ] After `bootstrap_acl.sh`: restart api-gateway and all Connect sidecar jobs
- [ ] `NOMAD_TOKEN` and `CONSUL_HTTP_TOKEN` are exported before running any cluster script
- [ ] Consul config entries (service-defaults, intentions, routes) applied before deploying jobs
- [ ] Grafana passwords are at least 8 characters
- [ ] `consul config write` calls prefix `CONSUL_HTTP_TOKEN=$CONSUL_HTTP_TOKEN`
- [ ] `nomad job run` calls prefix `NOMAD_TOKEN=$NOMAD_TOKEN`
