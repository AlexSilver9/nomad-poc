# HTTPRoute for business-service — hostname routing and static path rewrites.
#
# NOTE: URLRewrite.Path is a full-path replacement only — it cannot preserve URL suffixes.
# Suffix-preserving regex rewrite (e.g. /legacy-download/<token>) is handled upstream by
# Traefik before the request reaches the API Gateway. By the time the API Gateway sees
# the request, the path is already rewritten.
#
# Rewrite responsibility by layer:
#   Traefik (port 8081):    regex + capture groups  → /download/abc123 → /business-service/download.xhtml?token=abc123
#   API Gateway (here):     full-path replacement   → /api → /business-service/api
#   service-router:         prefix + suffix kept    → east-west only (not applied by API Gateway)
#
# Apply: consul config write services/business-service/route.consul.hcl
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
