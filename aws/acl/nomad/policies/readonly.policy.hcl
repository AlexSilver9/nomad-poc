# Nomad Read-Only Policy
# Applied to: Monitoring systems, audit tools, read-only users
#
# This policy allows:
# - Read job status and allocation details
# - Read logs
# - No write operations

namespace "default" {
  policy = "read"

  capabilities = [
    "read-logs",
    "read-fs"
  ]
}

# Read-only access to node pools
node_pool "*" {
  policy = "read"
}

# Read node information
node {
  policy = "read"
}

# Read agent information
agent {
  policy = "read"
}
