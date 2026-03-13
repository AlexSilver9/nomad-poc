# Allow api-gateway to connect to business-service
# Apply: consul config write intentions.consul.hcl

Kind = "service-intentions"
Name = "business-service"

Sources = [
  {
    Name   = "api-gateway"
    Action = "allow"
  }
]
