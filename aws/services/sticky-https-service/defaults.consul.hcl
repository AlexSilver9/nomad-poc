# HTTPS-native service: TCP at the Consul/Envoy layer (like Payara in production).
# Apply: consul config write services/sticky-https-service/defaults.consul.hcl

Kind     = "service-defaults"
Name     = "sticky-https-service"
Protocol = "tcp"
