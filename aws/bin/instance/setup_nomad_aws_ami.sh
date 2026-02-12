#!/usr/bin/bash
set -euo pipefail

# Install and configure Nomad on Amazon Linux (AWS EC2).
# Sets up Nomad server+client, Docker driver, and systemd service.
# Usage with arguments (non-interactive):
#   ./setup_nomad_aws_ami.sh <node1> <node2> <node3>
# Usage interactive:
#   ./setup_nomad_aws_ami.sh  (prompts for node addresses)
# Usage from repo:
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/instance/setup_nomad_aws_ami.sh | sh

# Variables
NOMAD_SYSTEMD_CONFIG="/usr/lib/systemd/system/nomad.service"
CNI_VERSION="v1.4.0"
ADD_USER_TO_DOCKER="${ADD_USER_TO_DOCKER:-}"  # Set to "yes" for non-interactive mode

# Read cluster node addresses from arguments or interactively
nodes=()

if [[ $# -gt 0 ]]; then
  # Non-interactive: nodes passed as arguments
  nodes=("$@")
else
  # Interactive: read from tty
  echo "Enter cluster node addresses (one per line, empty line to finish):"
  while IFS= read -r line </dev/tty; do
    [[ -z "$line" ]] && break
    nodes+=("$line")
  done
fi

if [[ ${#nodes[@]} -eq 0 ]]; then
  echo "Error: No node addresses provided"
  echo "Usage: $0 <node1> <node2> <node3> ..."
  echo "   or: $0  (interactive mode)"
  exit 1
fi

echo "Using initial cluster nodes:"
printf '  %s\n' "${nodes[@]}"

# Build client retry_join array and servers array
retry_join=""
servers=""
for node in "${nodes[@]}"; do
  retry_join+="      \"${node}:4648\",\n"
  servers+="    \"${node}:4647\",\n"
done
# Remove trailing comma and newline
retry_join=$(echo -e "$retry_join" | sed '$ s/,$//')
servers=$(echo -e "$servers" | sed '$ s/,$//')

# Function to ask yes/no questions, returns 0 for yes and 1 for no
ask_user() {
  local question="$1"
  local answer

  while true; do
    read -r -p "$question (y/N): " answer </dev/tty
    case "$answer" in
      [Yy]) return 0 ;;  # Yes
      [Nn]|'') return 1 ;;  # No (default)
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Setup System
sudo yum update -y
sudo yum upgrade -y
sudo yum install -y unzip
sudo yum install -y yum-utils
sudo yum install -y shadow-utils

# Print Host IP (for reference)
ip a | grep inet

# Verify Nomad cgroup v2 pre-requisites (same check — assuming cgroup v2 environment)
echo "Checking cgroup controllers (should show cpuset, cpu, io, memory, pids):"
cat /sys/fs/cgroup/cgroup.controllers | grep -E 'cpuset|cpu|io|memory|pids' || echo "Warning: Some controllers missing — check kernel config"

# Create Nomad directories
sudo mkdir -p /opt/nomad/alloc_mounts     # Mounts for job allocations

# Download and install Nomad binary
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y nomad

# Test if Nomad systemd unit can be modified
if [[ ! -f "${NOMAD_SYSTEMD_CONFIG}" ]]; then
  echo "Error: Nomad systemd config not found or modifyable at ${NOMAD_SYSTEMD_CONFIG}"
  exit 1
fi

# Integrate Nomad with Consul if consul.service exists
consul_config=""
nomad_user=""
nomad_group=""
if systemctl list-unit-files consul.service &>/dev/null; then
  echo "Consul detected, enabling Nomad-Consul integration"

  # To integrate Consul with Nomad via CNI bridge network
  # nomad must run as root to configure iptables for the network namespace
  nomad_user="root"
  nomad_group="root"

  # Modify Nomad systemd unit to depend on Consul
  sudo sed -i 's/^#Wants=consul.service/Wants=consul.service/' ${NOMAD_SYSTEMD_CONFIG}
  sudo sed -i 's/^#After=consul.service/After=consul.service/' ${NOMAD_SYSTEMD_CONFIG}

  # Prepare Consul config block for Nomad config
  consul_config='
consul {
  address = "127.0.0.1:8500"
}
'

  # Install CNI plugins (required for Consul Connect bridge networking)
  # https://developer.hashicorp.com/nomad/docs/networking/cni
  # CNI plugins must be owned by root - they run with elevated privileges
  echo "Installing CNI plugins ${CNI_VERSION}..."
  sudo mkdir -p /opt/cni/bin
  curl -sSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
    | sudo tar -xz -C /opt/cni/bin
  # Nomad runs network namespace operations as root (even if the main process runs as nomad)
  sudo chown -R $nomad_user:$nomad_group /opt/cni
  sudo chmod -R 755 /opt/cni

else
  # Without Consul integration Nomad can run as user nomad
  nomad_user="nomad"
  nomad_group="nomad"

  # Modify Nomad systemd unit
  echo "Modifying systemd service config at: ${NOMAD_SYSTEMD_CONFIG}"
  sudo sed -i 's/^User=root/User='$nomad_user'/' ${NOMAD_SYSTEMD_CONFIG}
  sudo sed -i 's/^Group=root/Group='$nomad_group'/' ${NOMAD_SYSTEMD_CONFIG}
fi

# Set ownership and permissions
sudo chown -R $nomad_user:$nomad_group /opt/nomad/alloc_mounts
sudo chmod 750 /opt/nomad/alloc_mounts

# Create Nomad config
sudo tee /etc/nomad.d/nomad.hcl > /dev/null <<EOF
data_dir = "/opt/nomad/data"
bind_addr = "0.0.0.0"

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
  }
}

${consul_config}

server {
  enabled          = true
  bootstrap_expect = ${#nodes[@]}

  server_join {
    retry_join = [
${retry_join}
    ]
  }
}

client {
  enabled = true

  servers = [
${servers}
  ]
}
EOF

# Setup Docker
sudo yum install -y docker

# Start & enable Docker
sudo systemctl enable --now docker

# Configure Nomad to access Docker (double check with: `groups nomad` or `groups root`)
sudo usermod -aG docker $nomad_group

# Reload systemd and start Nomad
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting Nomad daemon..."
sudo systemctl enable --now nomad

# Optional: Add current user to docker group
add_to_docker=false
if [[ "$ADD_USER_TO_DOCKER" == "yes" ]]; then
  add_to_docker=true
elif [[ -z "$ADD_USER_TO_DOCKER" ]] && ask_user "Do you want to add the current user ${LOGNAME} to docker group in order to enable running docker commands without sudo?"; then
  add_to_docker=true
fi

if $add_to_docker; then
  echo "Adding ${LOGNAME} to docker group..."
  sudo usermod -aG docker "${LOGNAME}"
  echo "Group added. For immediate effect run: \`newgrp docker\`"
  echo "Or log out and back in."
fi

echo "Done"
echo "Check Nomad systems status:   sudo systemctl status nomad"
echo "Check Docker systemd status:  sudo systemctl status docker"
echo "Check Nomad log:              journalctl -u nomad.service"
echo "Follow recent Nomad log:      journalctl -u nomad.service -f"
echo "Check Nomad server cluster:   nomad server members"
echo "Check Nomad jobs status:      nomad status"
echo "Check Nomad node status:      nomad node status -self -verbose"
echo "Check Nomad cni status:       nomad node status -self -verbose | grep cni"
echo "Check Nomad-Consul gRP port:  nomad node status -self -verbose | grep consul"
echo "Nomad UI (if server):         http://<instance>:4646"
