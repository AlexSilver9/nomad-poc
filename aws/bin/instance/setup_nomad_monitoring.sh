#!/bin/bash
set -euo pipefail

# Opt-in Nomad monitoring setup for an existing cluster node.
# Writes telemetry and host volume config as separate drop-in files,
# then restarts Nomad. Does not modify nomad.hcl.
#
# Run this script on each cluster node before deploying the Prometheus job.
# setup_monitoring.sh (cluster-level) calls this script via SSH on all nodes.

# Write telemetry config
sudo tee /etc/nomad.d/telemetry.hcl > /dev/null <<'EOF'
telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
  prometheus_metrics         = true
}
EOF

# Write host volumes for Prometheus and Grafana data persistence (backed by EFS /data)
sudo tee /etc/nomad.d/monitoring-volumes.hcl > /dev/null <<'EOF'
client {
  host_volume "prometheus-data" {
    path      = "/data/prometheus"
    read_only = false
  }
  host_volume "grafana-data" {
    path      = "/data/grafana"
    read_only = false
  }
}
EOF

# Create data directories on EFS
sudo mkdir -p /data/prometheus /data/grafana

# Restart Nomad to pick up the new config files
echo "Restarting Nomad..."
sudo systemctl restart nomad

# Wait for Nomad to be ready
echo "Waiting for Nomad agent to be ready..."
for i in $(seq 1 15); do
  if nomad node status -self &>/dev/null; then
    echo "Nomad agent ready"
    break
  fi
  sleep 2
done

echo "Done"
echo "Verify telemetry: curl -s http://localhost:4646/v1/metrics?format=prometheus | head -5"
