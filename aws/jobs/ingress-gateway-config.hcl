# Consul ingress gateway configuration entry
# This tells Consul how the ingress gateway should route traffic
# Apply with: consul config write ingress-gateway-config.hcl
#
# This ingress gateway routes to backend services based on host/path.

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
      },
      {
        Name  = "business-service"
        Hosts = ["business-service"]
        # The X-Forwarded-Proto header tells the backend service whether the original client request was HTTP or HTTPS.
        # The AWS ALB typically sets X-Forwarded-Proto automatically, so Traefik should be forwarding it already.
        # The Consul config entry here is adding it as a fallback/override in case it's missing.
        # Configure it if business-service has protocol-aware logic, e.g.:
        # - Generates URLs (links, redirects)
        # - Sets secure cookies
        #
        # RequestHeaders = {
        #  Add = {
        #    "X-Forwarded-Proto" = "https"
        #  }
        #}        
      }
    ]
  }
]
