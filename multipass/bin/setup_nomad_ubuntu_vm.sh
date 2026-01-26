#!/usr/bin/bash

# Install and configure Nomad on Ubuntu (Multipass VM).
# Sets up Nomad server+client, Docker driver, and systemd service.
# Usage: ./setup_nomad_ubuntu_vm.sh

# Config
NOMAD_VERSION=1.11.1

# Functions

# Function to ask yes/no questions, returns 1 for yes and 0 for no
ask_user() {
  local question="$1"
  local answer

  while true; do
    read -r -p "$question (y/N): " answer </dev/tty
    case "$answer" in
      [y]) return 0 ;;  # Yes
      [N]) return 1 ;;  # No
      *) echo "Please answer y or N." ;;
    esac
  done
}

# Setup System
sudo apt update && sudo apt upgrade -y
sudo apt install unzip -y
sudo apt autoremove

# Get Host IP
ip a | grep inet

# Verify Nomad prequisites
cat /sys/fs/cgroup/cgroup.controllers | grep cpuset
cat /sys/fs/cgroup/cgroup.controllers | grep cpu
cat /sys/fs/cgroup/cgroup.controllers | grep io
cat /sys/fs/cgroup/cgroup.controllers | grep memory
cat /sys/fs/cgroup/cgroup.controllers | grep pids

# Create Nomad user
sudo useradd --system --home /etc/nomad.d --shell /bin/false nomad

# Create Nomad dirs
sudo mkdir -p /opt/nomad            # Nomad state (raft logs, job metadata)
sudo mkdir -p /opt/alloc_mounts     # Mounts for job allocations (Nomad puts bind mounts and ephemeral volume directories for jobs here)
sudo mkdir -p /etc/nomad.d          # Config files

# Give Nomad ownership of it's dirs
sudo chown -R nomad:nomad /opt/nomad 
sudo chown -R nomad:nomad /opt/alloc_mounts
sudo chown -R nomad:nomad /etc/nomad.d
sudo chmod 750 /opt/nomad 
sudo chmod 750 /opt/alloc_mounts
sudo chmod 750 /etc/nomad.d

# Download Nomad binary
cd ${HOME}
wget https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip
unzip nomad_${NOMAD_VERSION}_linux_amd64.zip
sudo mv nomad /usr/local/bin/
sudo chown -R root:root /usr/local/bin/nomad

# Create Nomad systemd unit
sudo sh -c "cat > /etc/systemd/system/nomad.service" <<-EOF
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs
After=network-online.target
Wants=network-online.target

[Service]
User=nomad
Group=nomad
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create Nomad config
sudo sh -c "cat > /etc/nomad.d/nomad.hcl" <<-EOF
data_dir = "/opt/nomad"
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
    retry_join = [
      "172.17.45.133:4648",
      "172.17.34.232:4648",
      "172.17.34.232:4648"
    ]
  }
}

client {
  enabled = true

  servers = [
    "172.17.45.133:4647",
    "172.17.34.232:4647",
    "172.17.34.232:4647"
  ]
}
EOF

# TODO: REMOVE
# Create manual Nomad start script
# sh -c "cat > ${HOME}/nomad/start.sh" <<-EOF
# #!/bin/sh
# ./nomad agent -config=/etc/nomad.d/nomad.hcl
# EOF
# chmod ug+x start.sh

# Setup Docker Engine
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# Configure Nomad to access Docker 
sudo usermod -aG docker nomad
sudo systemctl restart docker

# Start Nomad systemd unit
echo "Reloading Docker daemon"
sudo systemctl daemon-reload
echo "Starting Nomad daemon"
sudo systemctl enable --now nomad

# Configure current user to access Docker and relogin (optional)
if ask_user "Do you want to add the current user ${LOGNAME} to docker group to enable running docker commands?"; then
  echo "Adding ${LOGNAME} to docker group..."
  sudo usermod -aG docker ${LOGNAME}
  newgrp docker
  # User info
  echo "If 'docker ps' shows 'permission denied' then you may need to run 'newgrp docker' manually or restart your shell."
else
  echo "Skipping adding ${LOGNAME} to docker group."
fi
