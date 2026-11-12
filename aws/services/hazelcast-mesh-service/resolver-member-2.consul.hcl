# Virtual service name for Hazelcast member 2. Not registered in the catalog - it only exists
# as this redirect to subset member-2 of hazelcast-mesh-service-hz.
# Upstream in job.nomad.hcl: hazelcast-mesh-service-hz-2 → 127.0.0.1:15702
#
# Apply: consul config write services/hazelcast-mesh-service/resolver-member-2.consul.hcl

Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz-2"

Redirect {
  Service       = "hazelcast-mesh-service-hz"
  ServiceSubset = "member-2"
}
