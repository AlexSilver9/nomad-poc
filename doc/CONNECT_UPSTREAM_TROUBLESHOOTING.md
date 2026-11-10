# Consul Connect East-West Upstream Troubleshooting

A service cannot reach another service via the Consul service mesh (east-west).
The application gets `Connection refused` on the local upstream port (e.g. `127.0.0.1:23010`).

## Architecture reminder

```
service-a (app task)
  └── 127.0.0.1:<upstream-port>  (local bind port declared in upstreams block)
        └── Envoy sidecar of service-a  (outbound upstream listener)
              └── Consul service mesh (mTLS)
                    └── Envoy sidecar of service-b  (public_listener)
                          └── service-b (app task)
```

Each layer can independently fail. Start from the inside out.

---

## Step 1 — Envoy: is the upstream listener present?

```bash
nomad alloc logs --stderr <alloc-id> connect-proxy-<service> 2>&1 | grep -E "lds|listener|upstream"
```

A healthy sidecar with an upstream shows two LDS entries:
```
lds: add/update listener 'public_listener:0.0.0.0:<port>'
lds: add/update listener 'outbound_listener:127.0.0.1:<upstream-port>'
```

If only `public_listener` appears and no `outbound_listener` — Consul never pushed the
upstream listener via xDS. This means the proxy was registered in Consul without upstreams.
Continue to step 2.

---

## Step 2 — Consul catalog: upstreams registered?

```bash
curl -s http://localhost:8500/v1/catalog/service/<service>-sidecar-proxy \
  | jq '.[].ServiceProxy.Upstreams'
```

If this returns `null`, Nomad registered the sidecar proxy without the upstreams block.
Consul has no upstream configuration to push to Envoy. Continue to step 3.

---

## Step 3 — Nomad: does the running job have upstreams?

```bash
nomad job inspect <service> | jq '.Job.TaskGroups[].Services[].Connect.SidecarService.Proxy.Upstreams'
```

If this returns `null`, the job submitted to Nomad does not define any upstreams — either
the upstreams block was missing from the HCL when the job was submitted, or the wrong
version of the file was used. Continue to step 4.

If this returns the expected upstream, the job spec is correct but the Consul registration
is stale. Stop and re-run the job to force re-registration (step 5).

---

## Step 4 — Job file: does it have the upstreams block?

```bash
grep -A5 "upstreams" <path-to>/services/<service>/job.nomad.hcl
```

If no output — the file is missing the upstreams block.

A correct upstreams block looks like:
```hcl
connect {
  sidecar_service {
    proxy {
      upstreams {
        destination_name = "<upstream-service>"
        local_bind_port  = <port>
      }
    }
  }
}
```

---

## Step 5 — Redeploy

After confirming the job file is correct:

```bash
nomad job run <path-to>/services/<service>/job.nomad.hcl
```

---

## Step 6 — Verify

**Upstreams in Consul registration (expect the upstream object, not null):**
```bash
curl -s http://localhost:8500/v1/catalog/service/<service>-sidecar-proxy \
  | jq '.[].ServiceProxy.Upstreams'
```

**Envoy upstream listener appeared:**
```bash
nomad alloc logs --stderr <new-alloc-id> connect-proxy-<service> 2>&1 | grep "lds"
```

Expect both `public_listener` and `outbound_listener:127.0.0.1:<upstream-port>`.

**Test the upstream port from inside the alloc:**
```bash
nomad alloc exec -task app <new-alloc-id> sh -c "nc -zv 127.0.0.1 <upstream-port>"
```

---

## Also check: intentions and service-defaults for the upstream service

The upstream service also needs:
- `service-defaults` with the correct protocol
- `service-intentions` allowing the calling service as a source

```bash
consul config read -kind service-defaults   -name <upstream-service>
consul config read -kind service-intentions -name <upstream-service>
```

The intentions must include:
```hcl
Sources = [{ Name = "<calling-service>", Action = "allow" }]
```
