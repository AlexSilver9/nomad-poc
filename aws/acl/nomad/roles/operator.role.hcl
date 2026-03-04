# This file is a reference document only — it is NOT read by Nomad.
# Roles have no HCL file format; they exist only as objects in the cluster's ACL state.
# The role described here is created at runtime by aws/bin/instance/create_user_tokens.sh.
#
# Role: operator
# Policies: node-operator
# Assigned to: operators performing AWS AMI / Linux kernel upgrades
#
# Grants:
# - Drain and re-enable nodes
# - Stop, restart, and re-submit jobs after a drain
# - Read job logs and filesystem
# - Read node pool information (no pool reassignment)
#
# Does NOT allow:
# - Submitting arbitrary new jobs or modifying job definitions
# - Changing node pool membership
# - Access to Nomad agent or server configuration
