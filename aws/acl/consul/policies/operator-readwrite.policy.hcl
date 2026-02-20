# Consul Operator Read-Write Policy
# Applied to: Engineers who need to register services, modify KV, or configure
#             the service mesh (e.g., intentions, service defaults)
#
# Grants read-write access to nodes, services, agent info, and KV store.
# Does NOT grant ACL management — use the management token for that.

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy = "write"
}

agent_prefix "" {
  policy = "write"
}

key_prefix "" {
  policy = "write"
}
