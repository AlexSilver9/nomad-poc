# Consul sees web-service as a TCP service, but the ingress gateway expects HTTP.
# This happens because the service needs to explicitly declare its protocol in Consul.
# The service-defaults config entry tells Consul that web-service uses HTTP protocol,
# which allows the ingress gateway's HTTP listener to route to it properly.

# Apply this configuration to Consul before running the ingress gateway:
# `consul config write web-service-defaults.hcl`

Kind     = "service-defaults"
Name     = "web-service"
Protocol = "http"
