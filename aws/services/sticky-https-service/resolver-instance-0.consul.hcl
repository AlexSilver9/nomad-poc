# Option B: virtual service sticky-https-service-0 (not registered in the catalog) → instance 0.
# The tcp-route route-instance-0.consul.hcl sends gateway listener :8083 here.
# Apply: consul config write services/sticky-https-service/resolver-instance-0.consul.hcl

Kind = "service-resolver"
Name = "sticky-https-service-0"

Redirect {
  Service       = "sticky-https-service"
  ServiceSubset = "ordinal-0"
}
