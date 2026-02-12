# Tell Consul that file-service uses HTTP protocol,
# which allows the ingress gateway's HTTP listener to route to it.

# `consul config write defaults.consul.hcl`

Kind     = "service-defaults"
Name     = "file-service"
Protocol = "http"
