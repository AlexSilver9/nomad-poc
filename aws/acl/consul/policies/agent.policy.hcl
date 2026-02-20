# Consul Agent Policy
# Applied to: Consul agent tokens (used by each Consul agent for node registration)
#
# This policy allows Consul agents to:
# - Register and manage their own node
# - Perform health checks on local services

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy = "write"
}
