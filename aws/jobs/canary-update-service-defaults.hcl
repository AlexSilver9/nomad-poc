# Service defaults for canary-update-service
# Tells Consul the service uses HTTP protocol for proper ingress gateway routing
#
# Apply: consul config write canary-update-service-defaults.hcl

Kind     = "service-defaults"
Name     = "canary-update-service"
Protocol = "http"
