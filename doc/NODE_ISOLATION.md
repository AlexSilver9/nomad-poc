# Node Isolation in Nomad

This document describes how to configure dedicated nodes where only specific jobs can run, and how to manage maintenance (e.g., kernel updates) with graceful workload migration.

## Use Cases

- Dedicated nodes for sensitive workloads

## Approach: Node Pools + Constraints

### 1. Create a Node Pool

Node pools provide first-class isolation. Jobs in one pool won't schedule on nodes in another pool.

```bash
# Create the node pool
nomad node pool apply - <<EOF
name        = "isolated-workloads"
description = "Dedicated nodes for sensitive workloads"
EOF
```

### 2. Configure the Isolated Node

On each isolated node, update the Nomad client configuration:

```hcl
# /etc/nomad.d/nomad.hcl
client {
  enabled    = true
  node_pool  = "isolated-workloads"

  # Optional: additional metadata for finer control
  meta {
    workload_type = "sensitive-workloads"
    az            = "eu-central-1a"
  }
}
```

Restart Nomad after configuration changes:
```bash
sudo systemctl restart nomad
```

### 3. Configure Jobs for Isolated Nodes

Jobs that should run on isolated nodes:

```hcl
job "sensitive-service" {
  node_pool = "sensitive-workloads"

  # Optional: additional constraints
  constraint {
    attribute = "${meta.workload_type}"
    value     = "sensitive-workload"
  }

  group "sensitive-group" {
    count = 2

    # Spread across availability zones for HA
    spread {
      attribute = "${meta.az}"
      weight    = 100
    }

    # Configure migration behavior for node drain
    migrate {
      max_parallel     = 1
      health_check     = "checks"
      min_healthy_time = "10s"
      healthy_deadline = "5m"
    }

    # ... task configuration
  }
}
```

### 4. Prevent Other Jobs from Running on Isolated Nodes

Jobs in the `default` pool won't schedule on `isolated-workloads` nodes automatically.

For extra safety, add an explicit exclusion to all regular jobs:

```hcl
job "regular-service" {
  # Explicitly use default pool (optional, this is the default)
  node_pool = "default"

  # ... rest of job configuration
}
```

## Maintenance: Kernel Updates with Node Drain

### Prerequisites for HA During Maintenance

- At least 2 nodes in the isolated pool
- Jobs configured with `count >= 2` and `spread` across nodes/AZs
- Proper `migrate` block configuration

### Maintenance Procedure

```bash
# 1. Get node ID
nomad node status

# 2. Drain the node (gracefully migrates allocations)
#    -deadline: max time to wait for allocations to migrate
#    Allocations will move to other eligible nodes in the same pool
nomad node drain -enable -deadline 5m <node-id>

# 3. Monitor drain progress
nomad node status <node-id>

# 4. Verify allocations migrated
nomad job status <job-name>

# 5. Perform maintenance (SSH into the node)
ssh <node> "sudo yum update -y kernel && sudo reboot"

# 6. Wait for node to come back online
# Check node status
nomad node status <node-id>

# 7. Disable drain mode
nomad node drain -disable <node-id>

# 8. Optionally rebalance workloads
#    Jobs with spread constraints will rebalance on next deployment
#    Or force a redeployment:
nomad job eval <job-name>
```

### Automated Maintenance Script

```bash
#!/bin/bash
set -euo pipefail

NODE_ID="$1"
DRAIN_DEADLINE="5m"

echo "Starting maintenance for node: $NODE_ID"

# Enable drain
echo "Enabling drain mode..."
nomad node drain -enable -deadline "$DRAIN_DEADLINE" "$NODE_ID"

# Wait for drain to complete
echo "Waiting for drain to complete..."
while true; do
    status=$(nomad node status -json "$NODE_ID" | jq -r '.DrainStrategy')
    if [[ "$status" == "null" ]]; then
        echo "Drain complete"
        break
    fi
    echo "Still draining..."
    sleep 10
done

# Perform maintenance
echo "Performing kernel update..."
ssh "$NODE_ID" "sudo yum update -y kernel && sudo reboot" || true

# Wait for node to come back
echo "Waiting for node to come back online..."
sleep 60
while ! nomad node status "$NODE_ID" &>/dev/null; do
    echo "Waiting..."
    sleep 10
done

# Disable drain
echo "Disabling drain mode..."
nomad node drain -disable "$NODE_ID"

echo "Maintenance complete for node: $NODE_ID"
```

## Summary

| Feature | Purpose |
|---------|---------|
| **Node Pool** | Hard isolation - jobs can only run in their assigned pool |
| **Node Class** | Soft grouping - use with constraints (pre-1.6) |
| **Constraints** | Restrict where jobs CAN or CAN'T run |
| **Spread** | Distribute allocations across nodes/AZs for HA |
| **Migrate block** | Control behavior during node drain |
| **`nomad node drain`** | Gracefully move workloads for maintenance |

## Best Practices

1. **Use node pools** (Nomad 1.6+) for hard isolation
2. **Have 2+ nodes** in each isolated pool for HA during maintenance
3. **Use spread constraints** to distribute across nodes/AZs
4. **Configure migrate blocks** for graceful drain behavior
5. **Test drain procedure** before production maintenance windows
6. **Monitor during drain** to ensure allocations migrate successfully
