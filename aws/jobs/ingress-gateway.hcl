job "ingress-gateway" {
  datacenters = ["dc1"]
  type = "service"

  group "ingress" {
    count = 3

    network {
      port "http" {
        static = 8080
      }
    }

    task "ingress" {
      driver = "docker"

      config {
        image = "hashicorp/consul-envoy"
        ports = ["http"]
      }

      service {
        name = "ingress-gateway"
        port = "http"
        connect {
          gateway {
            ingress {}
          }
        }
      }
    }
  }
}