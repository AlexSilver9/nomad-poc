# The traffic flow:
# Client → :8080 → Ingress Gateway → Envoy Sidecar → web-service container

job "web-service" {
  datacenters = ["dc1"]
  type = "service"

  group "web" {
    count = 3

    network {
      mode = "bridge"

      port "http" {
        to = 8080
      }
    }

    # Service block must be at group level for Consul Connect
    service {
      name = "web-service"
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

    task "web" {
      driver = "docker"

      config {
        image = "hashicorp/http-echo"
        args  = ["-text=hello world", "-listen=:8080"]
        ports = ["http"]
      }
    }
  }
}
