# Service that runs exclusively on the sensitive node pool.
# Requires: sensitive-node-pool created via `nomad node pool apply sensitive-node-pool.hcl`
# Requires: isolated nodes added via add_isolated_nodes.sh

job "sensitive-service" {

  datacenters = ["dc1"]
  type        = "service"
  node_pool   = "sensitive-node-pool"

  update {
    max_parallel      = 1
    min_healthy_time  = "10s"
    healthy_deadline  = "1m"
    progress_deadline = "5m"
    auto_revert       = true
  }

  group "sensitive-group" {
    count = 1

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    service {
      name = "sensitive-service"
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

    task "sensitive-service-task" {
      driver = "docker"

      config {
        image = "traefik/whoami:v1.10.0"
        args  = ["--port=8080", "--name=sensitive-service"]
        ports = ["http"]
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }
  }
}
