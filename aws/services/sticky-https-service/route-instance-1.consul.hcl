# Option B: API Gateway TCP listener sticky-https-service-1 (:8084) → instance 1 only.
# nginx addresses each instance via its own gateway port and does the stickiness itself.
# Apply: consul config write services/sticky-https-service/route-instance-1.consul.hcl
# Delete: consul config delete -kind tcp-route -name sticky-https-service-1

Kind = "tcp-route"
Name = "sticky-https-service-1"

Services = [{ Name = "sticky-https-service-1" }]

Parents = [
  {
    Kind        = "api-gateway"
    Name        = "api-gateway"
    SectionName = "sticky-https-service-1"
  }
]
