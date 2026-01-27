# Allow ingress-gateway to connect to web-service
# `consul config write ingress-intentions.hcl`

Kind = "service-intentions"
Name = "web-service"

Sources = [
  {
    Name   = "ingress-gateway"
    Action = "allow"
  }
]
