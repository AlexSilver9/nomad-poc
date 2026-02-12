# Allow ingress-gateway to connect to rolling-update-service
# https://developer.hashicorp.com/consul/docs/secure-mesh/intention
#
# Apply: consul config write rolling-update-service-intentions.hcl

Kind = "service-intentions"
Name = "rolling-update-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
