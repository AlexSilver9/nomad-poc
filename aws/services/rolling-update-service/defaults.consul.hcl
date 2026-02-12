# Service defaults for rolling-update-service
# Tells Consul the service uses HTTP protocol for proper ingress gateway routing
#
# Apply: consul config write rolling-update-service-defaults.hcl

Kind     = "service-defaults"
Name     = "rolling-update-service"
Protocol = "http"
