#!/bin/bash
set -euo pipefail

# Install Consul in CLIENT-ONLY mode on Amazon Linux (AWS EC2).
# Joins existing cluster without being a server.
# Run this BEFORE setup_nomad_client.sh for Nomad-Consul integration.
# Usage with arguments (non-interactive):
#   ./setup_consul_client.sh <server1> <server2> <server3>
# Usage interactive:
#   ./setup_consul_client.sh  (prompts for server addresses)
# Usage from repo:
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/instance/setup_consul_client.sh | sh

# Read server node addresses from arguments or interactively
nodes=()

if [[ $# -gt 0 ]]; then
  # Non-interactive: nodes passed as arguments
  nodes=("$@")
else
  # Interactive: read from tty
  echo "Enter server node addresses (one per line, empty line to finish):"
  while IFS= read -r line </dev/tty; do
    [[ -z "$line" ]] && break
    nodes+=("$line")
  done
fi

if [[ ${#nodes[@]} -eq 0 ]]; then
  echo "Error: No server node addresses provided"
  echo "Usage: $0 <server1> <server2> <server3> ..."
  echo "   or: $0  (interactive mode)"
  exit 1
fi

echo "Joining Consul cluster via: ${nodes[*]}"

# Build retry_join array
retry_join=""
for node in "${nodes[@]}"; do
    retry_join+="  \"${node}\",\n"
done
retry_join=$(echo -e "$retry_join" | sed '$ s/,$//')

# Install dependencies
sudo yum update -y
sudo yum install -y yum-utils

# Install Consul
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y consul

# Create data directory
sudo mkdir -p /opt/consul/data
sudo chown -R consul:consul /opt/consul
sudo chmod 750 /opt/consul

# Create client-only config
sudo tee /etc/consul.d/consul.hcl > /dev/null <<EOF
datacenter = "dc1"
data_dir = "/opt/consul/data"
bind_addr = "0.0.0.0"
client_addr = "0.0.0.0"

# Client-only mode
server = false

retry_join = [
${retry_join}
]

# Connect (service mesh) configuration
connect {
  enabled = true
}

ports {
  grpc = 8502
}
EOF

sudo chown consul:consul /etc/consul.d/consul.hcl
sudo chmod 640 /etc/consul.d/consul.hcl

# Start Consul
sudo systemctl daemon-reload
sudo systemctl enable --now consul

echo "Done. Consul client started."
echo "Verify: consul members"
