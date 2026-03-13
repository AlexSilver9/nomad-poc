# Consul API Gateway configuration entry.
# Declares the gateway listeners. Routes are defined separately in routes/*.consul.hcl.
#
# Apply: consul config write gateway.consul.hcl
#
# Docs: https://developer.hashicorp.com/consul/docs/reference/config-entry/api-gateway

Kind = "api-gateway"
Name = "api-gateway"

Listeners = [
  # HTTP listener — all HTTP services share this single port.
  # Envoy routes by Host header; no per-service port needed.
  {
    Name     = "http"
    Port     = 8080
    Protocol = "http"
  },

  # TCP listener for https-service.
  # TCP has no Host header visibility, so one port per HTTPS-native service is required.
  # Next HTTPS service: add a new listener here and a new port in job.nomad.hcl.
  {
    Name     = "https-service"
    Port     = 8082
    Protocol = "tcp"
  }
]
