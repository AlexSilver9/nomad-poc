# This file is a reference document only — it is NOT read by Consul.
# Roles have no HCL file format; they exist only as objects in the cluster's ACL state.
# The role described here is created at runtime by aws/bin/instance/create_user_tokens.sh.
#
# Role: readwrite
# Policies: operator-readwrite
# Assigned to: engineers managing service mesh configuration, KV, and service registrations
#
# Grants:
# - Read and write nodes, services, agents, and KV store
#
# Does NOT allow ACL management — use the management token for that.
