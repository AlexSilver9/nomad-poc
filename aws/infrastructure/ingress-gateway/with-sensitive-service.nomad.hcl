# Ingress Gateway with sensitive-service enabled
# Adds sensitive-service routing alongside existing services

job "ingress-gateway" {
  datacenters = ["dc1"]

  type      = "system"
  node_pool = "all"

  group "ingress" {
    network {
      mode = "bridge"

      port "inbound" {
        static = 8080
        to     = 8080
      }
    }

    service {
      name = "ingress-gateway"
      port = "inbound"

      connect {
        gateway {
          proxy {}

          ingress {
            listener {
              port     = 8080
              protocol = "http"

              service {
                name  = "business-service"
                hosts = ["business-service.example.com"]
              }

              service {
                name  = "sensitive-service"
                hosts = ["sensitive-service.example.com"]
              }

              service {
                name  = "web-service"
                hosts = ["web-service.example.com"]
              }
            }
          }
        }
      }
    }
  }
}
