# HTTPRoute for rolling-update-service.
# Apply: consul config write services/rolling-update-service/route.consul.hcl
# Delete: consul config delete -kind http-route -name rolling-update-service

Kind      = "http-route"
Name      = "rolling-update-service"
Hostnames = ["rolling-update-service.example.com"]

Rules = [
  {
    Services = [{ Name = "rolling-update-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
