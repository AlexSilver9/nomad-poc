# HTTPRoute for sensitive-service.
# Apply: consul config write services/sensitive-service/route.consul.hcl
# Delete: consul config delete -kind http-route -name sensitive-service

Kind      = "http-route"
Name      = "sensitive-service"
Hostnames = ["sensitive-service.example.com"]

Rules = [
  {
    Services = [{ Name = "sensitive-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
