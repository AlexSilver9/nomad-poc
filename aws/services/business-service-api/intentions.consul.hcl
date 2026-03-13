# Allow api-gateway to connect to business-service-api
# Apply: consul config write intentions.consul.hcl

Kind = "service-intentions"
Name = "business-service-api"

Sources = [
  {
    Name   = "api-gateway"
    Action = "allow"
  }
]
