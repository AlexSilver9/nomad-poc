job "ingress-gateway" {
  datacenters = ["dc1"]

  # Runs on all nodes for HA (or use type = "service" with count = 3 for specific replica count)
  type = "system"

  group "ingress" {
    network {
      # Required for Consul Connect via CNI bridge (required nomad running as root)
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

              # IMPORTANT: More specific hosts must come before wildcards
              service {
                name  = "business-service"
                hosts = ["business-service"]
              }

              service {
                name  = "web-service"
                hosts = ["web-service"]
              }

              # Wildcard: any service reachable via Host: <service-name>
              # Requires service-defaults (protocol=http) and intentions
              #  to be configured before new services are deployed
              service {
                name  = "*"
                hosts = ["*"]
              }
            }
          }
        }
      }
    }
  }
}