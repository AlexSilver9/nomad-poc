# File Service
#
# https://developer.hashicorp.com/nomad/docs/job-specification/volume
# Static: https://developer.hashicorp.com/nomad/docs/configuration/client#host_volume-block
# Dynamic: https://developer.hashicorp.com/nomad/docs/other-specifications/volume/host

# Serves static files from EFS-backed storage.
# The traffic flow:
# Client → :8080 → Ingress Gateway → Envoy Sidecar → file-service container
#
# Requires: EFS mounted on host (via host_volume "data" in Nomad client config)

job "file-service" {
  datacenters = ["dc1"]
  type = "service"

  group "files" {
    count = 2

    volume "data" {
      type   = "host"
      source = "data"
    }

    network {
      mode = "bridge"

      port "http" {
        to = 80
      }
    }

    # Service block must be at group level for Consul Connect
    service {
      name = "file-service"
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
            local_service_port = 80
          }
        }
      }
    }

    task "nginx" {
      driver = "docker"

      volume_mount {
        volume      = "data"
        destination = "/usr/share/nginx/html"
        read_only   = true
      }

      config {
        image = "nginx:alpine"
        ports = ["http"]
      }

      # Create a default index.html if EFS is empty
      template {
        data        = "<html><body><h1>File Service</h1><p>Serving files from EFS</p></body></html>"
        destination = "local/index.html"
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
