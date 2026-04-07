# HTTPRoute for Prometheus — hostname-based routing through the API Gateway.
# Apply: consul config write infrastructure/prometheus/route.consul.hcl
# Delete: consul config delete -kind http-route -name prometheus

Kind      = "http-route"
Name      = "prometheus"
Hostnames = ["prometheus.example.com"]

Rules = [
  {
    Services = [{ Name = "prometheus" }]
  }
]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "http"
  }
]
