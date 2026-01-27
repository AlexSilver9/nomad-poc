# Consul ingress gateway configuration entry
# This tells Consul how the ingress gateway should route traffic
# Apply with: consul config write ingress-gateway-config.hcl

Kind = "ingress-gateway"
Name = "ingress-gateway"

Listeners = [
  {
    Port     = 8080
    Protocol = "http"
    Services = [
      {
        Name  = "web-service"
        Hosts = ["*"]
      }
    ]
  }
]
