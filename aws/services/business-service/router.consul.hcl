# WORKAROUND: Consul http-route (API Gateway HCL config entry) does not support
# prefix-preserving path rewrites. URLRewrite.Path is a full-path replacement —
# /legacy-download/<token> would become /business-service/download.xhtml with the
# token lost. Confirmed on Consul 1.22.3 (latest).
#
# The Kubernetes CRD supports ReplacePrefixMatch, but the HCL config entry does not.
# Until HashiCorp aligns the HCL and CRD feature sets, this service-router is kept
# alongside the API Gateway to handle path routing with suffix preservation.
#
# DEPRECATION STATUS: service-router is NOT deprecated (verified in Consul 1.22.x docs).
# Only the ingress-gateway was deprecated (replaced by api-gateway for north-south traffic).
# service-router handles east-west traffic within the mesh and remains fully supported
# alongside service-splitter and service-resolver.
#
# The API Gateway routes all business-service.example.com traffic to business-service.
# This service-router then applies path-based routing and prefix rewrites internally.
#
# Apply: consul config write router.consul.hcl
# Delete: consul config delete -kind service-router -name business-service

Kind = "service-router"
Name = "business-service"

Routes = [
  # /legacy-business-service/* -> business-service-api
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

  # /legacy-download/<token> -> /business-service/download.xhtml/<token>
  # PrefixRewrite replaces only the matched prefix; the token suffix is preserved.
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

  # Default: all other paths -> business-service
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
