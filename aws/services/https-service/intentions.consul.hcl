# Allow ingress-gateway to connect to https-service
#
# Apply: consul config write intentions.consul.hcl

Kind = "service-intentions"
Name = "https-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
