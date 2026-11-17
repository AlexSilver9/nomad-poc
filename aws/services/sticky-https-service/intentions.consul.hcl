# Allow api-gateway to connect to sticky-https-service (Option B).
# Intentions apply to the real service, also when reached via the virtual names
# sticky-https-service-<N> (redirects).
# Apply: consul config write services/sticky-https-service/intentions.consul.hcl

Kind = "service-intentions"
Name = "sticky-https-service"

Sources = [
  {
    Name   = "api-gateway"
    Action = "allow"
  }
]
