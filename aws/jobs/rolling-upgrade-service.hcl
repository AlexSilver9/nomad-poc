# Service for testing rolling updates
# https://developer.hashicorp.com/nomad/docs/job-declare/strategy/rolling

job "rolling-upgrade-job" {

  datacenters = ["dc1"]
  type        = "service"
 
  # Update block to enable rolling updates of the service.
  # On job level it is inherited by all task groups in the job.
  # Can be overriden by task (merge with task level precedence precedence over job leve)
  update {
    max_parallel     = 1      # number of allocations changing / deployments at a time
    min_healthy_time = "10s"  # require healthy state before deploy more versions of the new group
    healthy_deadline = "10m"
    auto_revert      = true   # rollback on failed deployments, otherwise deployment fails and no further placing happens
  }

  group "rolling-upgrade-group" {
    count = 1

    network {
      mode = "bridge"
      port "http" {
        to = 80
      }
    }

    service {
      name = "rolling-upgrade-service"
      port = "http"

      check {
        type     = "http"
        path     = "/health"
        interval = "5s"
        timeout  = "2s"
      }

      connect {
        sidecar_service {
          proxy {
            local_service_port = 80
          }
        }
      }
    }

    task "rolling-upgrade-task" {
      driver = "docker"

      config {
        #image = "traefik/whoami:v1.11.0"  # new image version
        image = "traefik/whoami:v1.10.0"  # old image version
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}