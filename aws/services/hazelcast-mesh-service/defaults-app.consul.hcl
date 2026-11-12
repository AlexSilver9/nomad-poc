# Dummy app service (stands in for Payara). Not routed via api-gateway in this POC.
#
# Apply: consul config write services/hazelcast-mesh-service/defaults-app.consul.hcl

Kind     = "service-defaults"
Name     = "hazelcast-mesh-service"
Protocol = "http"
