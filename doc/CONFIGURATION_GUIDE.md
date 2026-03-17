# Configuration Guide

This guide explains where to configure different aspects of the Nomad/Consul service mesh.

## Configuration Files Overview

| Configuration | File | When to Use |
|---|---|---|
| **API Gateway listeners** (ports, protocols) | `infrastructure/api-gateway/gateway.consul.hcl` | Add/remove listener ports (e.g. new TCP port for HTTPS-native service) |
| **HTTP routing** (hostname → service) | `services/<svc>/route.consul.hcl` | Add/update HTTP route for a service |
| **TCP routing** (port → service) | `services/<svc>/route.consul.hcl` | Add/update TCP route for an HTTPS-native service |
| **Service protocol** (http/tcp) | `services/<svc>/defaults.consul.hcl` | Required when adding a new service to the mesh |
| **Service authorization** (intentions) | `services/<svc>/intentions.consul.hcl` | Allow/deny which sources can send traffic to a service |
| **East-west path routing** | `services/<svc>/router.consul.hcl` | Route different paths to different service subsets (service-to-service only) |
| **URL rewrites** (regex with capture groups) | `infrastructure/nginx-rewrite/job.nomad.hcl` or `traefik-rewrite/job.nomad.hcl` | Complex URL transformations before hitting the API Gateway |
| **Service deployment** (containers, resources) | `services/<svc>/job.nomad.hcl` | Deploy/update application containers |


## Detailed Configuration

### API Gateway (`gateway.consul.hcl`)

Declares the listeners — which ports Envoy binds to and what protocol each uses. One HTTP listener handles all plain HTTP services (Host-header routing). One TCP listener per HTTPS-native service.

```hcl
Kind = "api-gateway"
Name = "api-gateway"

Listeners = [
  { Name = "http",           Port = 8080, Protocol = "http" },
  { Name = "https-service",  Port = 8082, Protocol = "tcp"  },
]
```

**Apply changes** (requires api-gateway job restart):
```bash
consul config write infrastructure/api-gateway/gateway.consul.hcl
nomad job stop api-gateway && nomad job run infrastructure/api-gateway/job.nomad.hcl
```


### HTTP Routes (`services/<svc>/route.consul.hcl`)

Routes HTTP traffic to a service based on Host header. Optionally rewrite the path.

```hcl
Kind      = "http-route"
Name      = "web-service"
Hostnames = ["web-service.example.com"]

Rules = [{ Services = [{ Name = "web-service" }] }]

Parents = [{ Kind = "api-gateway", Name = "api-gateway", SectionName = "http" }]
```

With a static path rewrite (full-path replacement — no regex, no suffix preservation):

```hcl
Rules = [{
  Matches  = [{ Path = { Match = "Prefix", Value = "/api" } }]
  Filters  = [{ Type = "URLRewrite", URLRewrite = { Path = { Type = "ReplaceFullPath", Value = "/business-service/api" } } }]
  Services = [{ Name = "business-service" }]
}]
```

**Apply changes** (no job restart needed — Envoy reloads automatically):
```bash
consul config write services/web-service/route.consul.hcl
```


### TCP Routes (`services/<svc>/route.consul.hcl`)

Routes TCP traffic by port (no Host header visibility at TCP level). One TCP listener + one TCP route per HTTPS-native service.

```hcl
Kind = "tcp-route"
Name = "https-service"

Services = [{ Name = "https-service" }]

Parents = [{ Kind = "api-gateway", Name = "api-gateway", SectionName = "https-service" }]
```

**Apply changes:**
```bash
consul config write services/https-service/route.consul.hcl
```


### Service Defaults (`defaults.consul.hcl`)

Declares the protocol for a service in the mesh. Must be applied **before** any route referencing the service, otherwise Consul rejects the route with an inconsistent-protocol error.

```hcl
Kind     = "service-defaults"
Name     = "web-service"
Protocol = "http"   # or "tcp" for HTTPS-native services
```

**Apply changes:**
```bash
consul config write services/web-service/defaults.consul.hcl
```


### Intentions (`intentions.consul.hcl`)

Controls which sources are allowed to send traffic to a service. `Name` is the destination (receiver); `Sources` lists who can connect.

```hcl
Kind = "service-intentions"
Name = "web-service"    # Destination: who receives traffic

Sources = [
  { Name = "api-gateway", Action = "allow" },   # Allow inbound from API Gateway
]
```

**Apply changes:**
```bash
consul config write services/web-service/intentions.consul.hcl
```


### Service Router (`router.consul.hcl`)

Routes east-west traffic (service-to-service) by path prefix to different service subsets. Applied by the Connect sidecar — **not** applied by the API Gateway. Use for internal routing only, not for north-south ingress.

```hcl
Kind = "service-router"
Name = "business-service"

Routes = [
  {
    Match       = { HTTP = { PathPrefix = "/business-service-api" } }
    Destination = { Service = "business-service-api" }
  }
]
```

**Apply changes:**
```bash
consul config write services/business-service/router.consul.hcl
```


### URL Rewrites (`nginx-rewrite/job.nomad.hcl` or `traefik-rewrite/job.nomad.hcl`)

The API Gateway's `URLRewrite` supports full-path replacement only — no regex, no capture groups, no query-param injection. For regex rewrites (e.g. `/download/abc123` → `/service/download.xhtml?token=abc123`), configure the rewriter (nginx or Traefik) that sits in front of the API Gateway.

nginx example (inside the `args` heredoc in `job.nomad.hcl`):
```nginx
location ~ ^/download/(.*)$ {
    rewrite ^/download/(.*)$ /business-service/download.xhtml?token=$1 break;
    proxy_pass http://api_gateway_http;
}
```

**Apply changes:**
```bash
nomad job stop nginx-rewrite
nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
# or
nomad job stop traefik-rewrite
nomad job run infrastructure/traefik-rewrite/job.nomad.hcl
```


## Adding a New Service

See [ADDING_A_SERVICE.md](ADDING_A_SERVICE.md) for the full checklist — infrastructure
implications, required files, apply order, and connection impact.


## Quick Reference Commands

```bash
# Consul config entries
consul config write <file>.hcl                   # Apply config
consul config read -kind <kind> -name <name>     # Read config
consul config delete -kind <kind> -name <name>   # Delete config
consul config list -kind <kind>                  # List configs

# API Gateway
consul config list -kind api-gateway
consul config list -kind http-route
consul config list -kind tcp-route

# Nomad jobs
nomad job run <file>.hcl                         # Deploy/update job
nomad job stop <job-name>                        # Stop job
nomad job stop -purge <job-name>                 # Stop and cleanup
nomad status                                     # List all jobs
nomad job status <job-name>                      # Job details

# Debugging Envoy (admin API on any node)
curl http://localhost:19000/config_dump           # Full Envoy config
curl http://localhost:19000/clusters              # Upstream clusters
curl http://localhost:19000/listeners             # Active listeners
nomad alloc logs <alloc-id> api                  # Envoy logs
nomad alloc logs <alloc-id> setup                # Setup task logs (NWI login, bootstrap)
```
