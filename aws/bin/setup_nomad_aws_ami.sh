#!/bin/bash

# Install and configure Nomad on Amazon Linux (AWS EC2).
# Sets up Nomad server+client, Docker driver, and systemd service.
# Usage: ./setup_nomad_aws_ami.sh

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
sudo yum install -y unzip
sudo yum install -y yum-utils
sudo yum install -y shadow-utils

# Get Host IP (just for info)
ip a | grep inet

# Verify Nomad cgroup v2 pre-requisites (same check — assuming cgroup v2 environment)
echo "Checking cgroup controllers (should show cpuset, cpu, io, memory, pids):"
cat /sys/fs/cgroup/cgroup.controllers | grep -E 'cpuset|cpu|io|memory|pids' || echo "Warning: Some controllers missing — check kernel config"

# Create Nomad directories
sudo mkdir -p /opt/nomad/alloc_mounts     # Mounts for job allocations

# Set ownership and permissions
sudo chown -R nomad:nomad /opt/nomad/alloc_mounts
sudo chmod 750 /opt/nomad/alloc_mounts

# Download and install Nomad binary
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y nomad

# Modify Nomad systemd unit for Consul
SYSTEMD_CONFIG="/usr/lib/systemd/system/nomad.service"
if ask_user "Will Consul be installed along with Nomad?"; then
  echo "Enabling Consul in systemd service config at: ${SYSTEMD_CONFIG}"
  sudo sed -i 's/^#Wants=consul.service/Wants=consul.service/' ${SYSTEMD_CONFIG}
  sudo sed -i 's/^#After=consul.service/After=consul.service/' ${SYSTEMD_CONFIG}
fi

# Modify Nomad systemd unit
echo "Modyfing systemd service config at: ${SYSTEMD_CONFIG}"
sudo sed -i 's/^User=root/User=nomad/' ${SYSTEMD_CONFIG}
sudo sed -i 's/^Group=root/Group=nomad/' ${SYSTEMD_CONFIG}

# Create Nomad config (same as original)
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

server {
  enabled          = true
  bootstrap_expect = 3

  server_join {
    # Use AWS EC2 instance internal ips (from: ip a | grep inet)
    retry_join = [
      "172.31.31.203:4648",
      "172.31.25.19:4648",
      "172.31.16.100:4648"
    ]
  }
}

client {
  enabled = true

  # Use AWS EC2 instance internal ips (from: ip a | grep inet)
  servers = [
    "172.31.31.203:4647",
    "172.31.25.19:4647",
    "172.31.16.100:4647"
  ]
}
EOF

# Setup Docker
sudo yum install -y docker

# Start & enable Docker
sudo systemctl enable --now docker

# Configure Nomad to access Docker (double check with: groups nomad)
sudo usermod -aG docker nomad

# Reload systemd and start Nomad
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Starting Nomad daemon..."
sudo systemctl enable --now nomad

# Optional: Add current user to docker group
if ask_user "Do you want to add the current user ${LOGNAME} to docker group to enable running docker commands without sudo?"; then
  echo "Adding ${LOGNAME} to docker group..."
  sudo usermod -aG docker "${LOGNAME}"
  echo "Group added. For immediate effect run:  newgrp docker"
  echo "Or log out and back in."
else
  echo "Skipping adding ${LOGNAME} to docker group."
fi

echo "Done"
echo "Check nomad systems status:   sudo systemctl status nomad"
echo "Check docker systemd status:  sudo systemctl status docker"
echo "Check nomad log:              journalctl -u nomad.service"
echo "Follow recent nomad log:      journalctl -u nomad.service -f"
echo "Check nomad server cluster:   nomad server members"
echo "Check nomad jobs status:      nomad status"
echo "Nomad UI (if server):         http://<instance-ip>:4646"