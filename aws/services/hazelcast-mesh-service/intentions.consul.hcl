# Only Hazelcast members of this service may connect to each other (incl. a member to itself
# via its own upstream). Intentions are evaluated against the redirect target, so this single
# intention covers all virtual member names hazelcast-mesh-service-hz-<N>.
# Every other source - including Hazelcast members of other services - is denied by default.
#
# Apply: consul config write services/hazelcast-mesh-service/intentions.consul.hcl

Kind = "service-intentions"
Name = "hazelcast-mesh-service-hz"

Sources = [
  {
    Name   = "hazelcast-mesh-service-hz"
    Action = "allow"
  }
]
