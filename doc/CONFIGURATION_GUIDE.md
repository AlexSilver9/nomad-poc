# Configuration Guide

This guide explains where to configure different aspects of the Nomad/Consul service mesh.

## Configuration Files Overview

| Configuration | File | When to Use |
|--------------|------|-------------|
| **Ingress Gateway routing** (hosts, services) | `aws/jobs/ingress-gateway.hcl` | Add/remove services exposed through the gateway |
| **Service protocol** (http/tcp/grpc) | `aws/jobs/*-defaults.hcl` | When adding a new service to the mesh |
| **Service-to-service routing** (path-based) | `aws/jobs/*-router.hcl` | Route different paths to different service subsets |
| **Service authorization** (intentions) | `aws/jobs/ingress-intentions.hcl` | Allow/deny traffic between services |
| **URL rewrites** (regex transforms) | `aws/jobs/traefik-rewrite.hcl` | Complex URL transformations before hitting Envoy |
| **Service deployment** (containers, resources) | `aws/jobs/*-service.hcl` | Deploy/update application containers |


## Detailed Configuration

### Ingress Gateway (`ingress-gateway.hcl`)

Defines which services are exposed through the gateway and how they're routed based on Host headers.

```hcl
ingress {
  listener {
    port     = 8080
    protocol = "http"

    # IMPORTANT: More specific hosts must come before wildcards
    service {
      name  = "business-service"
      hosts = ["business-service"]
    }

    service {
      name  = "web-service"
      hosts = ["*"]
    }
  }
}
```

**Apply changes:** `nomad job run ingress-gateway.hcl`


### Service Defaults (`*-defaults.hcl`)

Defines the protocol for a service in the mesh. Required for Consul Connect to know how to proxy traffic.

```hcl
Kind     = "service-defaults"
Name     = "my-service"
Protocol = "http"  # or "tcp", "grpc"
```

**Apply changes:** `consul config write my-service-defaults.hcl`


### Service Router (`*-router.hcl`)

Routes traffic within a service based on path prefixes to different service subsets.

```hcl
Kind = "service-router"
Name = "business-service"

Routes = [
  {
    Match {
      HTTP {
        PathPrefix = "/legacy-business-service"
      }
    }
    Destination {
      Service = "business-service-api"
    }
  }
]
```

**Apply changes:** `consul config write business-service-router.hcl`


### Intentions (`ingress-intentions.hcl`)

Controls which services can communicate with each other (authorization).

```hcl
Kind = "service-intentions"
Name = "web-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
```

**Apply changes:** `consul config write ingress-intentions.hcl`


### URL Rewrites (`traefik-rewrite.hcl`)

Traefik handles complex URL transformations before traffic reaches Envoy.

```yaml
http:
  routers:
    download-rewrite:
      rule: "HostRegexp(`business-service`) && PathPrefix(`/download`)"
      middlewares:
        - download-rewrite
      service: ingress-gateway

  middlewares:
    download-rewrite:
      replacePathRegex:
        regex: "^/download/(.*)$"
        replacement: "/business-service/download.xhtml?token=$1"
```

**Apply changes:** `nomad job run traefik-rewrite.hcl`


### Service Deployment (`*-service.hcl`)

Nomad job that runs the actual application containers with Consul Connect sidecars.

```hcl
job "web-service" {
  group "web" {
    network {
      mode = "bridge"
      port "http" { to = 80 }
    }

    service {
      name = "web-service"
      port = "http"

      connect {
        sidecar_service {}
      }
    }

    task "web" {
      driver = "docker"
      config {
        image = "my-image:latest"
      }
    }
  }
}
```

**Apply changes:** `nomad job run web-service.hcl`


## Adding a New Service

1. **Create service-defaults** (Consul config entry)
   ```bash
   # Create new-service-defaults.hcl
   consul config write new-service-defaults.hcl
   ```

2. **Create Nomad job** (service deployment with sidecar)
   ```bash
   # Create new-service.hcl
   nomad job run new-service.hcl
   ```

3. **Add to ingress gateway** (if externally accessible)
   ```bash
   # Edit ingress-gateway.hcl, add service block
   nomad job run ingress-gateway.hcl
   ```

4. **Update intentions** (if needed for authorization)
   ```bash
   # Edit ingress-intentions.hcl or create new-service-intentions.hcl
   consul config write ingress-intentions.hcl
   ```


## Note on Ingress Gateway Configuration

Ingress gateway routing (host → service mapping) is defined directly in the Nomad job (`ingress-gateway.hcl`) rather than a separate Consul config entry. This avoids conflicts where Nomad would overwrite the Consul config on job deployment.


## Quick Reference Commands

```bash
# Consul config entries
consul config write <file>.hcl          # Apply config
consul config read -kind <kind> -name <name>  # Read config
consul config delete -kind <kind> -name <name>  # Delete config
consul config list -kind <kind>         # List configs

# Nomad jobs
nomad job run <file>.hcl               # Deploy/update job
nomad job stop <job-name>              # Stop job
nomad job stop -purge <job-name>       # Stop and cleanup
nomad status                           # List all jobs
nomad job status <job-name>            # Job details

# Debugging
consul catalog services                 # List registered services
consul connect envoy -gateway=ingress -register  # Debug gateway
nomad alloc logs <alloc-id>            # View task logs
```
