# Service for testing canary deployments
# https://developer.hashicorp.com/nomad/docs/job-specification/update#canary

# In a Canary Deployment, new versions are deployed alongside existing versions.
# The canary allocations receive traffic but can be tested before promoting.
# If canaries are healthy and approved, the deployment is promoted and old allocs are stopped.
# If canaries fail or are rejected, they are rolled back without affecting existing allocs.
#
# Key differences from Rolling Update:
# - Canary allocs run IN ADDITION to existing allocs (not replacing them)
# - Requires manual promotion (unless auto_promote = true)

# Workflow:
# 1. Submit job with new version
# 2. Nomad deploys `canary` number of new allocations
# 3. Both old and new versions run simultaneously
# 4. Test/verify the canary allocations
# 5. Promote deployment: nomad deployment promote <deployment-id>
#    OR rollback: nomad deployment fail <deployment-id>
# 6. After promotion, old allocations are replaced with new version

job "canary-update-service" {

  datacenters = ["dc1"]
  type        = "service"

  # Update block with canary configuration
  update {
    max_parallel      = 1     # How many allocs to update at a time AFTER promotion
    canary            = 1     # Number of canary allocs to deploy before promotion
    min_healthy_time  = "10s" # Min duration an alloc must remain healthy
    healthy_deadline  = "1m"  # Time for a single alloc to become healthy
    progress_deadline = "5m"  # Overall deadline for deployment progress
    auto_revert       = true  # Rollback canaries on failure
    auto_promote      = false # Require manual promotion (set true for auto-promote after healthy_deadline)
  }

  group "canary-update-group" {
    count = 2

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "canary-update-service"
      port = "http"

      # Canary tag helps identify canary allocations in Consul
      # Can be used for for weighted routing or debugging
      canary_tags = ["canary"]

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 8080
          }
        }
      }
    }

    task "canary-update-task" {
      driver = "docker"

      config {
        #image = "traefik/whoami:v1.11.0"  # new image version
        image = "traefik/whoami:v1.10.0"  # old image version
        args  = ["--port=8080", "--name=canary-update"]
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}
