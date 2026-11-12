# Hazelcast member protocol is binary TCP. Protocol must be tcp for the mesh to proxy it.
#
# Apply: consul config write services/hazelcast-mesh-service/defaults.consul.hcl

Kind     = "service-defaults"
Name     = "hazelcast-mesh-service-hz"
Protocol = "tcp"
