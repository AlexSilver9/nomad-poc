# Nomad Deployer Policy
#
# https://developer.hashicorp.com/nomad/docs/other-specifications/acl-policy
#
# Applied to: CI/CD systems, engineers who deploy and manage jobs
#
# This policy allows:
# - Submit, stop, and manage jobs in the default namespace
# - Read job logs and filesystem
# - Deploy to any node pool

# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#namespace-rules
namespace "default" {
  policy = "write"

  capabilities = [
    "submit-job",
    "dispatch-job",
    "read-logs",
    "read-fs",
    "alloc-exec",
    "alloc-lifecycle"
  ]
}

# Allow deployment to any node pool
# https://developer.hashicorp.com/nomad/docs/other-specifications/acl-policy#node-pools-rules
node_pool "*" {
  policy = "write"
}

# Allow reading node information
# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#node-rules
node {
  policy = "read"
}

# Allow reading agent information
# https://developer.hashicorp.com/nomad/docs/secure/acl/policies#agent-rules
agent {
  policy = "read"
}
