# Option B: one subset per instance ordinal (same pattern as hazelcast-mesh-service).
# Filters are evaluated against the SIDECAR registration - the ordinal tag is set on both the
# service and its sidecar_service (job.nomad.hcl).
# OnlyPassing: an unhealthy instance yields no endpoint → the gateway port of that instance
# rejects connections → nginx fails over to the other instance (proxy_next_upstream).
#
# Apply BEFORE resolver-instance-<N>.consul.hcl (they reference these subsets).
# Apply: consul config write services/sticky-https-service/resolver.consul.hcl

Kind          = "service-resolver"
Name          = "sticky-https-service"
DefaultSubset = "ordinal-0"

Subsets = {
  "ordinal-0" = {
    Filter      = "\"ordinal-0\" in Service.Tags"
    OnlyPassing = true
  }
  "ordinal-1" = {
    Filter      = "\"ordinal-1\" in Service.Tags"
    OnlyPassing = true
  }
}
