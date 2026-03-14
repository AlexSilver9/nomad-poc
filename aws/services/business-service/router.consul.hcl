# NOTE: This service-router handles east-west (service-to-service) routing within the
# Consul service mesh. It is NOT applied for north-south traffic coming through the
# Consul API Gateway — the API Gateway applies its own http-route rules and bypasses
# the service-router entirely. The PrefixRewrite below therefore has NO effect on
# requests arriving via the API Gateway.
#
# The API Gateway's http-route URLRewrite.Path is a full-path replacement and cannot
# preserve URL suffixes (e.g. /legacy-download/<token> → token is lost). The Kubernetes
# CRD supports ReplacePrefixMatch, but the HCL config entry does not (confirmed Consul 1.22.3).
#
# Options for prefix-preserving rewrite through the API Gateway:
#   1. Modify business-service to accept /legacy-download/<token> directly (cleanest).
#   2. Add a thin nginx rewriter job between the API Gateway and business-service.
#   3. Wait for HashiCorp to align the HCL config entry with the CRD feature set.
#
# DEPRECATION STATUS: service-router is NOT deprecated (verified in Consul 1.22.x docs).
# Only the ingress-gateway was deprecated. service-router handles east-west traffic and
# remains fully supported alongside service-splitter and service-resolver.
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
  # NOTE: Only effective for east-west (service-to-service) calls. North-south traffic
  # from the Consul API Gateway bypasses this rule — the API Gateway applies its own
  # http-route and never consults the service-router (see header comment above).
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
