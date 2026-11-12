# Virtual service name for Hazelcast member 1. Not registered in the catalog - it only exists
# as this redirect to subset member-1 of hazelcast-mesh-service-hz.
# Upstream in job.nomad.hcl: hazelcast-mesh-service-hz-1 → 127.0.0.1:15701
#
# Apply: consul config write services/hazelcast-mesh-service/resolver-member-1.consul.hcl

Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz-1"

Redirect {
  Service       = "hazelcast-mesh-service-hz"
  ServiceSubset = "member-1"
}
