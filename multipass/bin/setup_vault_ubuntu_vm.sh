#!/bin/bash

# Install and configure HashiCorp Vault on Ubuntu (Multipass VM).
# Sets up Vault server with Raft storage and systemd service.
# Usage: ./setup_vault_ubuntu_vm.sh

# Config
VAULT_VERSION=1.15.6

# Setup System
sudo apt update && sudo apt upgrade -y
sudo apt install unzip -y
sudo apt autoremove

# Get Host IP
ip a | grep inet

# Create Vault user
sudo useradd --system --home /etc/vault.d --shell /bin/false vault

# Create Vault dirs
sudo mkdir -p /opt/vault/data       # Vault state
sudo mkdir -p /etc/vault.d          # Config files

# Give Vault ownership of it's dirs
sudo chown -R vault:vault /opt/vault
sudo chown -R vault:vault /etc/vault.d
sudo chmod 750 /opt/vault
sudo chmod 750 /etc/vault.d

# Download Vault binary
cd ${HOME}
curl -Lo vault.zip https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip
unzip vault.zip
sudo mv vault /usr/local/bin/
sudo chown -R root:root /usr/local/bin/vault

# Create Vault systemd unit
sudo sh -c "cat > /etc/systemd/system/vault.service" <<-EOF
[Unit]
Description=Vault
Documentation=https://www.vaultproject.io/docs
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

# Security hardening
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_IPC_LOCK
AmbientCapabilities=CAP_IPC_LOCK
LockPersonality=yes
MemoryDenyWriteExecute=yes

[Install]
WantedBy=multi-user.target
EOF

# Create Vault config
sudo sh -c "cat > /etc/vault.d/vault.hcl" <<-EOF
ui = true

# TODO: TLS is strongly recommended for production
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "raft" {
  path = "/opt/vault/data"
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
EOF

# Start Vault systemd unit
echo "Starting Vault daemon"
sudo systemctl daemon-reload
sudo systemctl enable vault
sudo systemctl start vault

