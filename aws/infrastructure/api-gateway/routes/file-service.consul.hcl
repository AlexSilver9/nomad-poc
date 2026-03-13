# HTTPRoute for file-service.
# Apply: consul config write routes/file-service.consul.hcl
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
