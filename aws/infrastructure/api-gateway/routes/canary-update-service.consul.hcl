# HTTPRoute for canary-update-service.
# Apply: consul config write routes/canary-update-service.consul.hcl
# Delete: consul config delete -kind http-route -name canary-update-service

Kind      = "http-route"
Name      = "canary-update-service"
Hostnames = ["canary-update-service.example.com"]

Rules = [
  {
    Services = [{ Name = "canary-update-service" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
