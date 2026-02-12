# Service defaults for sensitive-service
# Tells Consul the service uses HTTP protocol for proper ingress gateway routing
#
# Apply: consul config write sensitive-service-defaults.hcl

Kind     = "service-defaults"
Name     = "sensitive-service"
Protocol = "http"
