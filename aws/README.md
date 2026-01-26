# AWS Nomad Cluster

Deploy a Nomad cluster on AWS EC2 instances.

## Quick Install

SSH into an EC2 instance and run:

```shell
curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/setup_nomad_aws_ami.sh | sh
```

This installs the Nomad agent in both server and client mode, along with Docker.

## Scripts

| Script | Description |
|--------|-------------|
| `bin/create_instances.sh` | Create 3 EC2 instances (nomad1, nomad2, nomad3) |
| `bin/describe_running_instances.sh` | List all instances with IPs and network info |
| `bin/terminate_instances.sh` | Terminate ALL EC2 instances (use with caution) |
| `bin/setup_nomad_aws_ami.sh` | Install Nomad + Docker on Amazon Linux |

## Setup Workflow

1. Create instances:
   ```shell
   ./bin/create_instances.sh
   ```

2. SSH into each instance and run the setup script:
   ```shell
   ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<public-dns>
   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/setup_nomad_aws_ami.sh | sh
   ```

3. After setup, update `/etc/nomad.d/nomad.hcl` on each node with the internal IPs of all 3 instances (use `ip a | grep inet` to find them).

4. Restart Nomad:
   ```shell
   sudo systemctl restart nomad
   ```

5. Verify cluster:
   ```shell
   nomad server members
   nomad node status
   ```

## Requirements

- AWS CLI configured with appropriate credentials
- `jq` for JSON parsing
- EC2 key pair named `nomad-keypair`


## VPC-ID

- vpc-ec926686

# Security Groups

- sg-77476f14 (default)
- sg-09aa7199da65ed0e3 (HTTP)
- sg-0beaa6c98d73ebd3b (HTTPS)
- sg-07fee22cbcdad4c58 (SSH)