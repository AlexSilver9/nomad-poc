# Consul service-router configuration entry
# This handles path-based routing for the business-service
# Apply with: consul config write business-service-router.hcl

Kind = "service-router"
Name = "business-service"

Routes = [
  # /legacy-business-service/* -> route to new business-service-api service
  {
    Match = {
      HTTP = {
        PathPrefix = "/legacy-business-service"
      }
    }
    Destination = {
      Service = "business-service-api"
    }
  },

  # /legacy-download/* -> route to business-service with path rewrite
  # Rewrites: /legacy-download/* -> /business-service/download.xhtml
  {
    Match = {
      HTTP = {
        PathPrefix = "/legacy-download"
      }
    }
    Destination = {
      Service       = "business-service"
      PrefixRewrite = "/business-service/download.xhtml"
    }
  },

  # Default: / -> route to business-service
  {
    Match = {
      HTTP = {
        PathPrefix = "/"
      }
    }
    Destination = {
      Service = "business-service"
    }
  }
]
