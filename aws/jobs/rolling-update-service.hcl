# Service for testing rolling updates
# https://developer.hashicorp.com/nomad/docs/job-declare/strategy/rolling

# In Rolling Update old versions of running allocs are replaced by new versions
# in a fashion that a specific amount of old versions are undeployed
# only if a specific amount of new versions are deployed and healthy for a specific.
# Once all old versions are replaced by new versions, the deployment is successful.
#
# When auto_revert = true and a deployment fails, all allocations are rolled back
# to the previous job version - not just the unhealthy ones.

# 1. Nomad detects an allocation failed to become healthy within healthy_deadline
# 2. The entire deployment is marked as failed
# 3. Nomad automatically submits the previous job version as a new deployment
# 4. All allocations (incl. successfully upgraded) are replaced with the previous version

# To prevent automatic rollback e.g. for manually investigation of failed deployments, set auto_revert = false.
# The deployment will fail but allocations won't be changed automatically.

job "rolling-update-service" {

  datacenters = ["dc1"]
  type        = "service"
 
  # Update block to enable rolling updates of the service.
  # On job level it is inherited by all task groups in the job.
  # Can be overriden by task (merge with task level precedence precedence over job leve)
  update {
    max_parallel      = 1     # Number of allocs changing / deployments at a time
    min_healthy_time  = "10s" # Min duration an alloc must remain healthy before spawning next allocs
    healthy_deadline  = "1m"  # Time for a single alloc to become healthy, must be < progress_deadline
    progress_deadline = "5m"  # Overall deadline for deployment progress
    auto_revert       = true  # Rollback on failed deployments, otherwise deployment fails and no further placing happens
  }

  group "rolling-update-group" {
    count = 2

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "rolling-update-service"
      port = "http"

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

    task "rolling-update-task" {
      driver = "docker"

      config {
        #image = "traefik/whoami:v1.11.0"  # new image version
        image = "traefik/whoami:v1.10.0"  # old image version
        args  = ["--port=8080", "--name=rolling-update"]
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}