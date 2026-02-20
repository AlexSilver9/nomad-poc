# Consul Policy for Nomad Server/Client
# Applied to: Token used in Nomad's consul{} block
#
# This policy allows Nomad to:
# - Read agent and node information
# - Register and manage services (task groups, Connect sidecars)
# - Create tokens for Connect sidecar proxies (acl = "write")

agent_prefix "" {
  policy = "read"
}

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "write"
}

# Required for Consul Connect - Nomad creates tokens for Envoy sidecars
acl = "write"
