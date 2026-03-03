# This file is a reference document only — it is NOT read by Nomad.
# Roles have no HCL file format; they exist only as objects in the cluster's ACL state.
# The role described here is created at runtime by aws/bin/instance/create_user_tokens.sh.
#
# Role: nomad-readonly
# Policies: readonly
# Assigned to: monitoring systems, audit tools, read-only users
#
# Grants:
# - Read job status and allocation details
# - Read logs and filesystem
# - Read node pool, node, and agent information
#
# Does NOT allow any write operations.
