#!/bin/bash
set -euo pipefail

# Install Nomad in CLIENT-ONLY mode on Amazon Linux (AWS EC2).
# Joins existing cluster without being a server.
# Usage with arguments (non-interactive):
#   ./setup_nomad_client.sh <server1> <server2> <server3>
# Usage interactive:
#   ./setup_nomad_client.sh  (prompts for server addresses)
# Usage from repo:
#   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/instance/setup_nomad_client.sh | sh

CNI_VERSION="v1.4.0"
ADD_USER_TO_DOCKER="${ADD_USER_TO_DOCKER:-}"  # Set to "yes" for non-interactive mode

# Function to ask yes/no questions, returns 0 for yes and 1 for no
ask_user() {
  local question="$1"
  local answer=""

  # Skip interactive prompt if /dev/tty is not available (piped execution)
  [[ -t 0 ]] || [[ -e /dev/tty ]] || return 1

  while true; do
    read -r -p "$question (y/N): " answer </dev/tty || return 1
    case "$answer" in
      [Yy]) return 0 ;;  # Yes
      [Nn]|'') return 1 ;;  # No (default)
      *) echo "Please answer y or n." ;;
    esac
  done
}

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

echo "Joining Nomad cluster via: ${nodes[*]}"

# Build servers array
servers=""
for node in "${nodes[@]}"; do
    servers+="    \"${node}:4647\",\n"
done
servers=$(echo -e "$servers" | sed '$ s/,$//')

# Install dependencies
sudo yum install -y unzip docker

# Install Nomad
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y nomad

# Create directories
sudo mkdir -p /opt/nomad/alloc_mounts

# Configure Nomad-Consul integration
NOMAD_SYSTEMD_CONFIG="/usr/lib/systemd/system/nomad.service"
consul_config=""
if systemctl list-unit-files consul.service &>/dev/null; then
    echo "Consul detected, enabling integration..."
    sudo sed -i 's/^#Wants=consul.service/Wants=consul.service/' $NOMAD_SYSTEMD_CONFIG
    sudo sed -i 's/^#After=consul.service/After=consul.service/' $NOMAD_SYSTEMD_CONFIG
    consul_config='
consul {
  address = "127.0.0.1:8500"
}'

    # Install CNI plugins
    sudo mkdir -p /opt/cni/bin
    curl -sSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
        | sudo tar -xz -C /opt/cni/bin
    sudo chown -R root:root /opt/cni
fi

# TODO: Use AWS EFS
# Create data dir as surrogate of AWS EFS
sudo mkdir /data
sudo chmod a+r /data

# Create a index html file in data dir to be used by file-service
sudo tee /data/index.html > /dev/null <<EOF
<head>
</head>
<body
  <h1>Hello Cluster</h1>
</body>
EOF
sudo chmod a+r /data/*


# Create client-only config
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

# Client-only mode (no server)
client {
  enabled = true

  servers = [
${servers}
  ]

  host_volume "data" {
    path      = "/data"
    read_only = false
  }
}
EOF

# Start Docker
sudo systemctl enable --now docker

# Start Nomad
sudo systemctl daemon-reload
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

echo "Done. Nomad client started."
echo "Verify: nomad node status"
