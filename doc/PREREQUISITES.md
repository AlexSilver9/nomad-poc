# AWS Prerequisites

This document lists everything that must exist in AWS **before** running any setup script. The setup scripts (`setup_cluster.sh`, `create_instances.sh`, etc.) assume these resources are in place — they do not create or verify them.

---

## What the scripts do NOT create

| Resource | Who must create it | Notes |
|---|---|---|
| VPC | AWS admin | Hard-coded in scripts: `vpc-ec926686` |
| Subnets | AWS admin | Two subnets in different AZs required (for ALB): `subnet-3ee53954`, `subnet-5eafa423` |
| Security groups | AWS admin | Max five SGs hard-coded in `create_instances.sh` and `create_alb.sh` — see below |
| EC2 key pair | AWS admin | Name `nomad-keypair` hard-coded in `create_instances.sh` |
| Private key file | Operator | Expected at `~/workspace/nomad/nomad-keypair.pem` or `$SSH_KEY` |
| EFS security group | AWS admin | EFS mount target must accept TCP 2049 (NFS) from EC2 nodes |
| AWS credentials | Operator | `aws-cli` must be configured with permissions to create EC2, ELB, EFS resources |
| DNS records | AWS admin | Scripts use ALB DNS name directly; no Route53 setup is done |
| ACM certificate | AWS admin | Required for HTTPS on the ALB listener — not created by scripts |
| Docker registry credentials | Operator | For private registries — not configured by scripts |

---

## Security groups

Five security groups are hard-coded in `create_instances.sh` and `create_alb.sh`. They must exist with the rules below.

### EC2 nodes — required inbound rules

The `NOMAD-CONSUL` security group (e.g. `sg-08e51d2a581377e0b`) must allow the ports that Consul, Nomad, and the ingress layer need. The other four SGs cover SSH, HTTP, HTTPS, and the AWS default.

| Port(s) | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Operator IPs | SSH — setup scripts and operations |
| 4646 | TCP | Operator IPs, ALB SG | Nomad HTTP API and UI |
| 4647 | TCP | EC2 nodes (self) | Nomad RPC (server-to-server, client-to-server) |
| 4648 | TCP + UDP | EC2 nodes (self) | Nomad Serf gossip (cluster membership) |
| 8080 | TCP | EC2 nodes (self) | Consul API Gateway HTTP listener (nginx → gateway via loopback — no SG rule strictly required) |
| 8081 | TCP | ALB SG, operator IPs | nginx/Traefik HTTP rewriter (ALB target port) |
| 8082 | TCP | EC2 nodes (self) | Consul API Gateway TCP listener (nginx → gateway via loopback — no SG rule strictly required; additional HTTPS-native services add 8083, 8084, … also loopback-only) |
| 8300 | TCP | EC2 nodes (self) | Consul RPC (server-to-server) |
| 8301 | TCP + UDP | EC2 nodes (self) | Consul Serf LAN gossip (cluster membership) |
| 8443 | TCP | Operator IPs | nginx/Traefik HTTPS rewriter (direct node access, not via ALB in POC) |
| 8500 | TCP | Operator IPs | Consul HTTP API and UI |
| 8502 | TCP | EC2 nodes (self) | Consul gRPC (plain) — target of Nomad's unix socket proxy (`alloc/tmp/consul_grpc.sock`); `grpc_address` in `/etc/nomad.d/consul.hcl` must be `NODE_IP:8502`, not `127.0.0.1:8502` (see CONNECT_SIDECAR_PITFALLS.md #1) |
| 8503 | TCP | EC2 nodes (self) | Consul gRPC TLS — auto-enabled by Consul 1.22.3 when ACLs are active; the consul CLI switches to this port when it detects TLS is required, deriving the endpoint from `grpc_address` (host stays the same, port becomes 8503) |
| 19000 | TCP | EC2 nodes (self) | Envoy admin API (API Gateway — only needed for debugging) |
| 20000–32000 | TCP | EC2 nodes (self) | Dynamic Nomad allocation ports (Envoy sidecars, service health checks) |

All outbound traffic should be allowed (unrestricted egress).

### ALB — required inbound rules

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 80 | TCP | 0.0.0.0/0 | HTTP — POC ALB listener (forwards to EC2 :8081) |
| 443 | TCP | 0.0.0.0/0 | HTTPS — production ALB listener (not active in POC) |

The ALB also needs outbound to the EC2 nodes on port 8081 (health checks + traffic forwarding).

### EFS mount targets

| Port | Protocol | Source | Purpose |
|---|---|---|---|
| 2049 | TCP | EC2 node SG | NFS — EFS mount from EC2 instances |

---

## EC2 instance requirements

| Requirement | Value | Notes |
|---|---|---|
| AMI | Amazon Linux 2 (`amzn2-ami-hvm-x86_64-gp2`) | Looked up automatically from SSM parameter |
| Instance type | `t3.micro` (POC) | Hard-coded in `create_instances.sh`; increase for production |
| Root volume | Default (8 GiB gp2) | Sufficient for POC; increase if running many containers |
| IMDSv2 | Required | Set in `create_instances.sh` (`HttpTokens=required`) |
| Public IP | Yes | Instances get public IPs for SSH and ALB routing |
| Key pair | `nomad-keypair` | Hard-coded name; key file must be available locally |

---

## What the scripts hardcode

The following values are specific to the POC AWS account and must be updated if deploying to a different account or region:

| Script | Hardcoded value | What it is |
|---|---|---|
| `create_instances.sh` | `subnet-3ee53954` | Subnet for EC2 instances |
| `create_instances.sh` | Five `sg-*` IDs | Security groups for EC2 instances |
| `create_target_group.sh` | `vpc-ec926686` | VPC for the target group |
| `create_alb.sh` | `subnet-3ee53954`, `subnet-5eafa423` | Subnets for ALB (2 AZs) |
| `create_alb.sh` | Five `sg-*` IDs | Security groups for ALB |
| `setup_cluster.sh` | GitHub raw URL (`AlexSilver9/nomad-poc`, `api-gateway` branch) | Source for scripts and job files downloaded to nodes |

---

## What is set up by the scripts but not in the Nomad/Consul layer

| Item | Script | Notes |
|---|---|---|
| EC2 instances (3×) | `create_instances.sh` | `t3.micro`, Amazon Linux 2, tagged `nomad1/2/3` |
| EFS file system | `create_efs.sh` | Named `nomad-efs`; mount targets are **not** created — the EFS must be reachable from EC2 nodes via an existing mount target in the subnet |
| ALB + listener | `create_alb.sh` | HTTP:80 → EC2:8081; HTTPS listener not created in POC |
| ALB target group | `create_target_group.sh` | HTTP:8081, health check on `/` |
| Consul install + config | `setup_consul_aws_ami.sh` | Binary install, systemd, `consul.hcl` |
| Nomad install + config | `setup_nomad_aws_ami.sh` | Binary install, systemd, `nomad.hcl`, CNI plugins, Docker |
| Nomad jobs + Consul config entries | `setup_cluster.sh` steps 6–7 | Downloaded from GitHub and applied |
| ACL (optional) | `bootstrap_acl.sh` + `enforce_acl.sh` | Day-2 operation — see [ACL_IMPLEMENTATION.md](ACL_IMPLEMENTATION.md) |

### EFS mount

`setup_cluster.sh` creates the EFS file system but the actual mounting on instances is commented out (the `wait_for_instances` step has the mount loop disabled). Mounting must be done manually or activated in the script after ensuring EFS mount targets exist in the correct subnet:

```bash
ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<NODE>
curl -sSf <GITHUB_RAW_BASE>/bin/instance/mount_efs.sh | bash -s -- <EFS_ID>
```

---

## Local machine requirements

| Tool | Purpose |
|---|---|
| `aws-cli` | EC2, ELB, EFS management — must be configured (`aws configure`) |
| `jq` | JSON parsing in cluster scripts |
| `ssh` | Node access — with key at `~/workspace/nomad/nomad-keypair.pem` or `$SSH_KEY` |
| Outbound HTTPS | Setup scripts download Consul, Nomad, CNI plugins, and Docker from the internet on the EC2 instances |

For the full setup procedure, see [SETUP.md](SETUP.md).
