# This file is a reference document only — it is NOT read by Nomad.
# Roles have no HCL file format; they exist only as objects in the cluster's ACL state.
# The role described here is created at runtime by aws/bin/instance/create_user_tokens.sh.
#
# Role: nomad-deployer
# Policies: deployer
# Assigned to: CI/CD systems, engineers who deploy and manage jobs
#
# Grants:
# - Submit, dispatch, and stop jobs in all namespaces
# - Exec into running allocations
# - Read job logs and filesystem
# - Deploy to any node pool (node_pool write)
# - Read node and agent information
