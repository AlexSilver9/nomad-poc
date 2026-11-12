# One subset per Hazelcast member ordinal. The job tags each instance (service AND sidecar)
# with hz-ordinal-<NOMAD_ALLOC_INDEX>. Filters are evaluated against the sidecar registration.
# OnlyPassing: during a rolling update the replacement alloc only receives traffic once its
# Hazelcast health check passes.
#
# The number of subsets must match var.members in job.nomad.hcl.
#
# Apply: consul config write services/hazelcast-mesh-service/resolver.consul.hcl

Kind = "service-resolver"
Name = "hazelcast-mesh-service-hz"

DefaultSubset = "member-0"

Subsets = {
  "member-0" = {
    Filter      = "\"hz-ordinal-0\" in Service.Tags"
    OnlyPassing = true
  }
  "member-1" = {
    Filter      = "\"hz-ordinal-1\" in Service.Tags"
    OnlyPassing = true
  }
  "member-2" = {
    Filter      = "\"hz-ordinal-2\" in Service.Tags"
    OnlyPassing = true
  }
}
