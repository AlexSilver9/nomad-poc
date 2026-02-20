# Consul Operator Read-Only Policy
# Applied to: Engineers and monitoring systems that need UI/CLI read access
#
# Grants read access to nodes, services, agent info, and KV store.
# Does NOT grant ACL management — use the management token for that.

node_prefix "" {
  policy = "read"
}

service_prefix "" {
  policy = "read"
}

agent_prefix "" {
  policy = "read"
}

key_prefix "" {
  policy = "read"
}
