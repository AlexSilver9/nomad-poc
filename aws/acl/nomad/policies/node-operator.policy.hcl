# Nomad Node Operator Policy
#
# https://developer.hashicorp.com/nomad/docs/other-specifications/acl-policy
#
# Applied to: operators performing AWS AMI / Linux kernel upgrades
#
# This policy allows:
# - Drain and re-enable nodes (node write)
# - Stop, start, and restart jobs in all namespace
# - Read job status, logs, and filesystem
#
# This policy does NOT allow:
# - Submitting new jobs or modifying job definitions
# - Changing node pool membership
# - Access to Nomad agent or server configuration

# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#namespace-rules
namespace "default" {
  policy = "write"

  capabilities = [
    "submit-job",      # required to re-enable a stopped job after drain
    "read-logs",
    "read-fs",
    "alloc-lifecycle", # stop/restart allocations
  ]
}

# Read access to node pools (no pool reassignment)
# https://developer.hashicorp.com/nomad/docs/other-specifications/acl-policy#node-pools-rules
node_pool "*" {
  policy = "read"
}

# Write access allows draining and toggling node eligibility
# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#node-rules
node {
  policy = "write"
}

# Read agent information (needed for node status checks)
# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#agent-rules
agent {
  policy = "read"
}
