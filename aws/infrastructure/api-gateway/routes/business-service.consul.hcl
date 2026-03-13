# HTTPRoute for business-service.
# Path-based routing for the business-service
#
# Apply: consul config write routes/business-service.consul.hcl
# Delete: consul config delete -kind http-route -name business-service

Kind      = "http-route"
Name      = "business-service"
Hostnames = ["business-service.example.com"]

Rules = [
  # /legacy-business-service/* -> business-service-api (legacy path redirect)
  {
    Matches = [{ Path = { Match = "prefix", Value = "/legacy-business-service" } }]
    Services = [{ Name = "business-service-api" }]
  },

  # /legacy-download/* -> business-service with path rewrite
  # Rewrites prefix: /legacy-download/token -> /business-service/download.xhtml/token
  {
    Matches = [{ Path = { Match = "prefix", Value = "/legacy-download" } }]
    Filters = [{
      Type = "URLRewrite"
      URLRewrite = {
        Path = {
          Type               = "ReplacePrefixMatch"
          ReplacePrefixMatch = "/business-service/download.xhtml"
        }
      }
    }]
    Services = [{ Name = "business-service" }]
  },

  # Default: all other paths -> business-service
  {
    Matches  = [{ Path = { Match = "prefix", Value = "/" } }]
    Services = [{ Name = "business-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
