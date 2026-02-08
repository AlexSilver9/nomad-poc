# Canary Traffic Isolation in Consul OSS

This document describes approaches to prevent canary allocations from receiving production traffic during testing, without requiring Consul Enterprise.

## The Challenge

In Consul Enterprise, you can use `Filter` in a service-resolver to exclude canary-tagged instances:

```hcl
# Consul Enterprise only
Kind = "service-resolver"
Name = "my-service"
Filter = "\"canary\" not in Service.Tags"
```

In Consul OSS, this field is not available. All healthy service instances receive traffic proportionally.

## Option 1: Separate Service Name for Canary

Register the canary under a different service name that's not configured in the ingress gateway.

### Concept

- Stable instances register as `my-service` (in ingress gateway)
- Canary instances register as `my-service-preview` (not in ingress gateway)
- Only `my-service` receives production traffic

### Limitation

Nomad doesn't support changing the service name via `canary_meta`. You would need to use a template that reads an environment variable to conditionally set the service name, which adds complexity.

## Option 2: Two Task Groups (Recommended)

Use separate task groups within the same job - one for stable traffic and one for canary testing.

### Job Structure

```hcl
job "my-service" {
  datacenters = ["dc1"]
  type        = "service"

  # Stable group - receives production traffic via ingress gateway
  group "stable" {
    count = 2

    network {
      mode = "bridge"
      port "http" { to = 8080 }
    }

    service {
      name = "my-service"  # This name is in the ingress gateway
      port = "http"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {}
      }
    }

    task "app" {
      driver = "docker"
      config {
        image = "myapp:v1.0.0"  # Current stable version
        ports = ["http"]
      }
    }
  }

  # Canary group - isolated from production traffic
  group "canary" {
    count = 0  # Start with 0, scale up when testing

    network {
      mode = "bridge"
      port "http" { to = 8080 }
    }

    service {
      name = "my-service-preview"  # NOT in ingress gateway
      port = "http"

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {}
      }
    }

    task "app" {
      driver = "docker"
      config {
        image = "myapp:v1.1.0"  # New canary version
        ports = ["http"]
      }
    }
  }
}
```

### Workflow

```bash
# 1. Deploy the job (stable group runs, canary group has count=0)
nomad job run my-service.hcl

# 2. Scale up canary group for testing
nomad job scale my-service canary 1

# 3. Test the canary via direct IP or internal service mesh
#    Find the canary allocation:
nomad job allocs my-service
#    Get the IP:
nomad alloc status <canary-alloc-id> | grep -A5 "Allocation Addresses"
#    Or via Consul DNS (if configured):
curl my-service-preview.service.consul:8080/

# 4a. If canary is good: Update stable group's image, scale canary to 0
#     Edit the job file to update stable group's image
nomad job run my-service.hcl
nomad job scale my-service canary 0

# 4b. If canary is bad: Scale canary to 0
nomad job scale my-service canary 0
```

### Advantages

- Clear separation between stable and canary
- No production traffic to canary until explicitly enabled
- Works with Consul OSS
- Easy to understand and operate

### Disadvantages

- Not using Nomad's built-in canary deployment feature
- Manual process to promote (update image in stable group)
- Two places to update the image version

## Option 3: Traefik with Weighted Routing

Use Traefik (which is already in the stack for URL rewriting) with Consul Catalog provider and weighted tags.

### Concept

Traefik can read service tags from Consul and apply weighted load balancing. Canary instances get weight=0 initially.

### Job Configuration

```hcl
job "my-service" {
  group "app" {
    count = 3

    service {
      name = "my-service"
      port = "http"

      # Stable instances get full weight
      tags = [
        "stable",
        "traefik.enable=true",
        "traefik.http.services.my-service.loadbalancer.server.weight=100"
      ]

      # Canary instances get zero weight
      canary_tags = [
        "canary",
        "traefik.enable=true",
        "traefik.http.services.my-service.loadbalancer.server.weight=0"
      ]

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }

    update {
      canary       = 1
      auto_promote = false
    }

    task "app" {
      driver = "docker"
      config {
        image = "myapp:v1.0.0"
      }
    }
  }
}
```

### Traefik Configuration

Configure Traefik to use Consul Catalog as a provider:

```yaml
providers:
  consulCatalog:
    endpoint:
      address: "127.0.0.1:8500"
    exposedByDefault: false
    connectAware: true
```

### Workflow

1. Deploy with new image version - canary starts with weight=0
2. Test canary via direct IP
3. To shift traffic: update canary_tags weight (e.g., to 10 for 10% traffic)
4. Promote when ready: `nomad deployment promote <deployment-id>`

### Advantages

- Uses Nomad's built-in canary feature
- Gradual traffic shifting possible
- Single job file

### Disadvantages

- Requires Traefik in front of your services (bypasses Envoy ingress)
- More complex routing setup
- Tag-based weight may not work with all Traefik versions

## Option 4: Disable Service Registration for Canary

Don't register the canary with Consul until ready for traffic.

### Concept

Use Nomad's `enable_tag_override` or a custom script to control when the canary registers with Consul.

### Job Configuration

```hcl
job "my-service" {
  group "app" {
    service {
      name = "my-service"
      port = "http"

      # Canary uses a failing health check initially
      canary_tags = ["canary"]

      check {
        name     = "http"
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      # Additional check that fails for canaries
      check {
        name     = "canary-gate"
        type     = "script"
        command  = "/bin/sh"
        args     = ["-c", "test -f /tmp/enable-traffic || exit 1"]
        interval = "5s"
        timeout  = "2s"
      }
    }

    task "app" {
      driver = "docker"

      config {
        image = "myapp:v1.0.0"
      }

      # Template that creates the gate file when ENABLE_TRAFFIC=true
      template {
        data        = "{{ if eq (env \"ENABLE_TRAFFIC\") \"true\" }}enabled{{ end }}"
        destination = "local/traffic-gate"
        change_mode = "script"
        change_script {
          command = "/bin/sh"
          args    = ["-c", "[ -s local/traffic-gate ] && touch /tmp/enable-traffic || rm -f /tmp/enable-traffic"]
        }
      }

      env {
        ENABLE_TRAFFIC = "true"  # Set to "false" for canary via canary_meta if supported
      }
    }
  }
}
```

### Limitation

Nomad doesn't support `canary_meta` for environment variables in all contexts. This approach requires workarounds.

## Comparison

| Approach | Complexity | Traffic Isolation | Uses Nomad Canary | Gradual Rollout |
|----------|------------|-------------------|-------------------|-----------------|
| Option 1: Separate Service Name | Medium | Full | No | No |
| Option 2: Two Task Groups | Low | Full | No | No |
| Option 3: Traefik Weights | High | Configurable | Yes | Yes |
| Option 4: Disable Registration | High | Full | Yes | No |

## Recommendation

**For Consul OSS, use Option 2 (Two Task Groups)** because:

1. Simple to understand and operate
2. Full traffic isolation without complex configuration
3. Works reliably with Consul OSS
4. Clear separation of concerns

If you need gradual traffic shifting (true canary with percentage-based rollout), consider:

- Upgrading to Consul Enterprise, or
- Implementing Option 3 with Traefik, or
- Using a service mesh like Linkerd that supports traffic splitting in OSS

## See Also

- [Rolling Update Demo](../aws/bin/rolling_update.sh) - Rolling update without traffic isolation
- [Canary Update Demo](../aws/bin/canary_update.sh) - Canary update (traffic goes to all instances in OSS)
- [Nomad Update Stanza](https://developer.hashicorp.com/nomad/docs/job-specification/update)
- [Consul Service Resolver](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-resolver)
