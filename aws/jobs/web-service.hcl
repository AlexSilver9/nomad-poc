job "web-service" {
  datacenters = ["dc1"]
  type = "service"

  group "web" {
    count = 3

    network {
      port "http" {
        to = 8080
      }
    }

    task "web" {
      driver = "docker"
      config {
        image = "hashicorp/http-echo"
        args  = ["-text=hello world"]
        ports = ["http"]
      }

      service {
        name = "web"
        port = "http"
        check {
          type     = "http"
          path     = "/health"
          interval = "10s"
          timeout  = "2s"
        }
        connect {
          # Discovery über Ingress Gateway
          sidecar_service {}
        }
      }
    }
  }
}
