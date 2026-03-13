# HTTPRoute for business-service — hostname routing only.
#
# NOTE: Path-based routing is intentionally PARTIALLY handled here.
# It is delegated to services/business-service/router.consul.hcl (Consul service-router).
#
# Reason: Consul http-route URLRewrite.Path is a full-path replacement string and cannot
# preserve the URL suffix (e.g. /legacy-download/<token> → token is lost). The HCL config
# entry does not support ReplacePrefixMatch despite the docs describing it for the Kubernetes
# CRD. Confirmed on Consul 1.22.3. The service-router's PrefixRewrite does preserve the
# suffix and is used as a workaround. See router.consul.hcl for the path routing rules.
#
# Apply: consul config write routes/business-service.consul.hcl
# Delete: consul config delete -kind http-route -name business-service

Kind      = "http-route"
Name      = "business-service"
Hostnames = ["business-service.example.com"]

Rules = [
  # Example: simple full-path URLRewrite.
  # /api -> /business-service/api
  #
  # This works cleanly because the rewritten path is static — there is no dynamic
  # suffix to preserve. URLRewrite.Path replaces the entire request path with the
  # given string, regardless of what the Matches prefix was.
  #
  # Contrast with the service-router workaround in router.consul.hcl:
  # /legacy-download/<token> cannot be handled here because the token suffix would
  # be dropped. The service-router's PrefixRewrite preserves the suffix.
  {
    Matches = [{ Path = { Match = "prefix", Value = "/api" } }]
    # NOTE: No "Type" field inside Filters — the filter type is identified by the block
    # name alone (URLRewrite, RequestHeaderModifier, etc.). The Kubernetes CRD uses a
    # "type: URLRewrite" discriminator field, but the HCL config entry does not. Adding
    # Type = "URLRewrite" causes: invalid config key "Rules[x].Filters.Type".
    Filters = [{
      URLRewrite = {
        Path = "/business-service/api"
      }
    }]
    Services = [{ Name = "business-service" }]
  },

  # Default: all other paths -> business-service (path routing handled by service-router)
  {
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
