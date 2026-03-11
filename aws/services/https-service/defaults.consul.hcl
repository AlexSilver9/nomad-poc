# https-service uses TCP protocol at the Consul/Envoy layer because it speaks HTTPS natively.
# The ingress gateway uses a TCP listener (not HTTP) so it can pass the TLS stream through intact.
#
# Apply: consul config write defaults.consul.hcl

Kind     = "service-defaults"
Name     = "https-service"
Protocol = "tcp"
