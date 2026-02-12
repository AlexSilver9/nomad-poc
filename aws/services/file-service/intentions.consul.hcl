# Allow ingress-gateway to connect to file-service
# https://developer.hashicorp.com/consul/docs/secure-mesh/intention

# `consul config write intentions.consul.hcl`

Kind = "service-intentions"
Name = "file-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
