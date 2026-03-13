# TCPRoute for https-service.
# TCP has no Host header visibility, so this service requires its own dedicated listener
# port (8082) defined in gateway.consul.hcl. See gateway.consul.hcl for the rationale.
#
# Apply: consul config write routes/https-service.consul.hcl
# Delete: consul config delete -kind tcp-route -name https-service

Kind = "tcp-route"
Name = "https-service"

Services = [{ Name = "https-service" }]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "https-service"
  }
]
