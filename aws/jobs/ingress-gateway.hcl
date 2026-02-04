job "ingress-gateway" {
  datacenters = ["dc1"]

  # Runs on all nodes for HA (or use type = "service" with count = 3 for specific replica count)
  type = "system"

  group "ingress" {
    network {
      # Required for Consul Connect
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

          # Ingress routing is defined in Consul config entry (ingress-gateway-config.hcl)
          # Do NOT define 'ingress' block here - it would overwrite the Consul config
          ingress {}
        }
      }
    }
  }
}