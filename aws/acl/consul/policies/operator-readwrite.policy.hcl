# Consul Operator Read-Write Policy
# Applied to: Engineers who need to register services, modify KV, or configure
#             the service mesh (e.g., intentions, routes, service defaults)
#
# Grants read-write access to nodes, services, agent info, KV store, intentions,
# and mesh-scope config entries (http-route, tcp-route, api-gateway).
# Does NOT grant ACL management — use the management token for that.
#
# https://developer.hashicorp.com/consul/docs/secure/acl/rule

node_prefix "" {
  policy = "write"
}

service_prefix "" {
  policy     = "write"
  intentions = "write"
}

# Required for consul config write on mesh-scope entries:
# http-route, tcp-route, api-gateway.
mesh = "write"

agent_prefix "" {
  policy = "write"
}

key_prefix "" {
  policy = "write"
}
