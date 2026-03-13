job "api-gateway" {
  datacenters = ["dc1"]

  # Runs on all nodes for HA
  type      = "system"
  node_pool = "all"

  group "api-gateway" {
    network {
      # Required for Consul Connect via CNI bridge
      mode = "bridge"

      # HTTP listener — all HTTP services share this port (routed by Host header)
      port "http" {
        static = 8080
        to     = 8080
      }

      # TCP listener — one port per HTTPS-native service (no Host header routing at TCP level)
      # https-service: 8082
      port "https-service" {
        static = 8082
        to     = 8082
      }
    }

    service {
      name = "api-gateway"
      port = "http"

      connect {
        gateway {
          api {}
        }
      }
    }
  }
}
