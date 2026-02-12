# Allow ingress-gateway to connect to sensitive-service
# https://developer.hashicorp.com/consul/docs/secure-mesh/intention
#
# Apply: consul config write sensitive-service-intentions.hcl

Kind = "service-intentions"
Name = "sensitive-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
