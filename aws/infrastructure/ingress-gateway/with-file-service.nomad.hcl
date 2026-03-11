# Ingress Gateway with file-service enabled
# This is a temporary config used during the file-service demo
# After the demo, restore the original ingress-gateway.hcl

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
                name  = "file-service"
                hosts = ["file-service.example.com"]
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
