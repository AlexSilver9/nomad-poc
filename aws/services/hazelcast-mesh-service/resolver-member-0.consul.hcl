# Virtual service name for Hazelcast member 0. Not registered in the catalog - it only exists
# as this redirect to subset member-0 of hazelcast-mesh-service-hz.
# Upstream in job.nomad.hcl: hazelcast-mesh-service-hz-0 → 127.0.0.1:15700
#
# Apply: consul config write services/hazelcast-mesh-service/resolver-member-0.consul.hcl

Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz-0"

Redirect {
  Service       = "hazelcast-mesh-service-hz"
  ServiceSubset = "member-0"
}
