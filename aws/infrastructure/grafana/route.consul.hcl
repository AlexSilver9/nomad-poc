# HTTPRoute for Grafana — hostname-based routing through the API Gateway.
# Apply: consul config write infrastructure/grafana/route.consul.hcl
# Delete: consul config delete -kind http-route -name grafana

Kind      = "http-route"
Name      = "grafana"
Hostnames = ["grafana.example.com"]

Rules = [
  {
    Services = [{ Name = "grafana" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
