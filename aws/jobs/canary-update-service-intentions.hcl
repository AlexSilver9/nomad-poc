# Allow ingress-gateway to connect to canary-update-service
# https://developer.hashicorp.com/consul/docs/secure-mesh/intention
#
# Apply: consul config write canary-update-service-intentions.hcl

Kind = "service-intentions"
Name = "canary-update-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
