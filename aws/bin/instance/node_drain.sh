#!/usr/bin/bash
set -euo pipefail

# Demonstrates Nomad node drain: gracefully migrates allocations off a node.
#
# https://developer.hashicorp.com/nomad/commands/node/drain
#
# Use cases: maintenance, OS patching, scaling down, replacing nodes.
# Nomad moves allocations to other eligible nodes before marking the node
# as ineligible for new placements.
#
# Requires: at least 2 nodes in the target pool so allocations can migrate.
#
# Each step pauses for verification in the Nomad UI before proceeding.
#
# Usage: ./node_drain.sh [node-id]
#   If no node-id is given, lists nodes and prompts for selection.

# Step 1: Select node to drain
echo "=== STEP 1: Select node to drain ==="

if [[ $# -gt 0 ]]; then
    NODE_ID="$1"
    echo "Using node: $NODE_ID"
else
    echo "Current nodes:"
    echo ""
    nomad node status
    echo ""
    read -p "Enter the Node ID (or prefix) to drain: " NODE_ID
fi

if [[ -z "$NODE_ID" ]]; then
    echo "Error: No node ID provided"
    exit 1
fi

# Resolve full node ID and show current status
echo ""
echo "Node details before drain:"
nomad node status "$NODE_ID"

read -p "Press Enter to show allocations on this node..."

# Step 2: Show allocations on the node
echo "=== STEP 2: Allocations on node $NODE_ID ==="
nomad node status -verbose "$NODE_ID" | { grep -A 100 "^Allocations" || echo "(no allocations)"; }

echo ""
echo "=============================================="
echo "These allocations will be migrated to other nodes."
echo "=============================================="

read -p "Press Enter to enable drain on this node..."

# Step 3: Enable node drain
echo "=== STEP 3: Enable node drain ==="
nomad node drain -enable -yes "$NODE_ID"
echo ""
echo "Drain enabled. Nomad is migrating allocations off this node."
echo "The node is now ineligible for new placements."

read -p "Press Enter to check drain and migration status..."

# Step 4: Verify drain status
echo "=== STEP 4: Drain and migration status ==="
echo ""
echo "Node status:"
nomad node status "$NODE_ID" | { head -20 || true; }
echo ""
echo "Allocations (should show migrated/stopped allocs):"
nomad node status -verbose "$NODE_ID" | { grep -A 100 "^Allocations" || echo "(no allocations)"; }

echo ""
echo "=============================================="
echo "Verify in the Nomad UI:"
echo "  - The drained node should show 'ineligible' status"
echo "  - Allocations should have migrated to other nodes"
echo "  - Jobs should still be running and healthy"
echo ""
echo "Check all nodes:  nomad node status"
echo "Check job status: nomad status"
echo "=============================================="

read -p "Press Enter to disable drain (re-enable the node)..."

# Step 5: Disable drain
echo "=== STEP 5: Disable drain (re-enable node) ==="
nomad node drain -disable -yes "$NODE_ID"
echo ""
echo "Drain disabled. Node is now eligible for new placements again."
echo ""

read -p "Press Enter to verify the node is back to normal..."

# Step 6: Verify node is eligible again
echo "=== STEP 6: Verify node status ==="
nomad node status "$NODE_ID" | { head -20 || true; }

echo ""
echo "=============================================="
echo "Node $NODE_ID is eligible again."
echo "New allocations can now be placed on this node."
echo ""
echo "Note: Existing allocations that migrated away will NOT"
echo "automatically move back. To rebalance, you can:"
echo "  - Drain another node to force migration back"
echo "  - Stop and restart the job"
echo "=============================================="

echo ""
echo "Done"
