# This file is a reference document only — it is NOT read by Consul.
# Roles have no HCL file format; they exist only as objects in the cluster's ACL state.
# The role described here is created at runtime by aws/bin/instance/create_user_tokens.sh.
#
# Role: consul-readonly
# Policies: operator-readonly
# Assigned to: monitoring systems, audit tools, read-only users
#
# Grants:
# - Read nodes, services, agents, and KV store
#
# Does NOT allow any write operations or ACL management.
