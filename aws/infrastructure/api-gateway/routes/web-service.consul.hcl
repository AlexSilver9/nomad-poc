# HTTPRoute for web-service.
# Apply: consul config write routes/web-service.consul.hcl
# Delete: consul config delete -kind http-route -name web-service

Kind      = "http-route"
Name      = "web-service"
Hostnames = ["web-service.example.com"]

Rules = [
  {
    Services = [{ Name = "web-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
