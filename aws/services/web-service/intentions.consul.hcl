# Allow api-gateway to connect to web-service
# https://developer.hashicorp.com/consul/docs/secure-mesh/intention

# `consul config write web-service-intentions.hcl`

Kind = "service-intentions"
Name = "web-service"

Sources = [
  {
    Name   = "api-gateway"
    Action = "allow"
  }
]
