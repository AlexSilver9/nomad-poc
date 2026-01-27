#!/usr/bin/bash
set -euo pipefail

# Install and configure HashiCorp Consul on Amazon Linux (AWS EC2).
# Sets up Consul server+client and systemd service.
# Run this BEFORE setup_nomad_aws_ami.sh for Nomad-Consul integration.
# Usage local:
#   echo -e "<host1>\n<host2>\n<host3>" | ./setup_consul_aws_ami.sh
# Usage on EC2:
#   ./get_public_dns_names.sh | ssh ec2-user@<host> 'bash -s' < ./setup_consul_aws_ami.sh
# Usage from repo:
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/setup_consul_aws_ami.sh | sh

# Variables
CONSUL_SYSTEMD_CONFIG="/usr/lib/systemd/system/consul.service"

# Read cluster node addresses (one per line, empty line to finish)
echo "Enter cluster node addresses (one per line, empty line to finish):"
nodes=()
while IFS= read -r line </dev/tty; do
  [[ -z "$line" ]] && break
  nodes+=("$line")
done

if [[ ${#nodes[@]} -eq 0 ]]; then
  echo "Error: No node addresses provided"
  exit 1
fi

echo "Using initial cluster nodes:"
printf '  %s\n' "${nodes[@]}"

# Build retry_join array for Consul (port 8301 for Serf LAN)
retry_join=""
for node in "${nodes[@]}"; do
  retry_join+="  \"${node}\",\n"
done
# Remove trailing comma and newline
retry_join=$(echo -e "$retry_join" | sed '$ s/,$//')

# Setup System
sudo yum update -y
sudo yum upgrade -y
sudo yum install -y unzip
sudo yum install -y yum-utils
sudo yum install -y shadow-utils

# Print Host IP (for reference)
echo "Host IP addresses:"
ip a | grep inet

# Download and install Consul
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y consul

# Test if Consul systemd unit exists
if [[ ! -f "${CONSUL_SYSTEMD_CONFIG}" ]]; then
  echo "Error: Consul systemd config not found at ${CONSUL_SYSTEMD_CONFIG}"
  exit 1
fi

# Create Consul data directory
sudo mkdir -p /opt/consul/data
sudo chown -R consul:consul /opt/consul
sudo chmod 750 /opt/consul

# Create Consul config
sudo tee /etc/consul.d/consul.hcl > /dev/null <<EOF
datacenter = "dc1"
data_dir = "/opt/consul/data"
bind_addr = "0.0.0.0"
client_addr = "0.0.0.0"

# Cluster configuration
server = true
bootstrap_expect = ${#nodes[@]}

retry_join = [
${retry_join}
]

# UI enabled
ui_config {
  enabled = true
}

# Connect (service mesh) configuration
connect {
  enabled = true
}

# Performance tuning
performance {
  raft_multiplier = 1
}
EOF

# Set proper ownership
sudo chown consul:consul /etc/consul.d/consul.hcl
sudo chmod 640 /etc/consul.d/consul.hcl

# Reload systemd and start Consul
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting Consul daemon..."
sudo systemctl enable --now consul

echo ""
echo "Done"
echo "Check Consul systemd status:  sudo systemctl status consul"
echo "Check Consul log:             journalctl -u consul.service"
echo "Follow recent Consul log:     journalctl -u consul.service -f"
echo "Check Consul members:         consul members"
echo "Consul UI:                    http://<instance>:8500"
