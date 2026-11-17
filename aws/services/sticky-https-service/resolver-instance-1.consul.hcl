# Option B: virtual service sticky-https-service-1 (not registered in the catalog) → instance 1.
# The tcp-route route-instance-1.consul.hcl sends gateway listener :8084 here.
# Apply: consul config write services/sticky-https-service/resolver-instance-1.consul.hcl

Kind = "service-resolver"
Name = "sticky-https-service-1"

Redirect {
  Service       = "sticky-https-service"
  ServiceSubset = "ordinal-1"
}
