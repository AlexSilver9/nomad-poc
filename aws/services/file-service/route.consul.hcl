# HTTPRoute for file-service.
# Apply: consul config write services/file-service/route.consul.hcl
# Delete: consul config delete -kind http-route -name file-service

Kind      = "http-route"
Name      = "file-service"
Hostnames = ["file-service.example.com"]

Rules = [
  {
    Services = [{ Name = "file-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
