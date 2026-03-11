# Ingress Gateway with https-service enabled
# Adds a second TCP listener on port 8082 for https-service (TLS passthrough).
# The HTTP listener on 8080 handles all plain HTTP services as usual.
#
# Traffic flow for https-service:
# nginx:8443 (HTTPS upstream) → Envoy TCP:8082 → https-service sidecar → container:8443

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

      port "inbound-tls" {
        static = 8082
        to     = 8082
      }
    }

    service {
      name = "ingress-gateway"
      port = "inbound"

      connect {
        gateway {
          proxy {}

          ingress {
            # HTTP listener: routes by Host header to plain HTTP services
            listener {
              port     = 8080
              protocol = "http"

              service {
                name  = "business-service"
                hosts = ["business-service.example.com"]
              }

              service {
                name  = "web-service"
                hosts = ["web-service.example.com"]
              }
            }

            # TCP listener: TLS passthrough for services that speak HTTPS natively.
            # No host routing at this layer — nginx routes to this port only for https-service.
            listener {
              port     = 8082
              protocol = "tcp"

              service {
                name = "https-service"
              }
            }
          }
        }
      }
    }
  }
}
