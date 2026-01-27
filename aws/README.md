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
| `bin/get_public_dns_names.sh` | Output public DNS names (one per line) |
| `bin/terminate_instances.sh` | Terminate ALL EC2 instances (use with caution) |
| `bin/setup_consul_aws_ami.sh` | Install Consul on Amazon Linux |
| `bin/setup_nomad_aws_ami.sh` | Install Nomad + Docker on Amazon Linux |

## Setup Workflow

### Create AWS EC2 instances

1. Create instances:
   ```shell
   ./bin/create_instances.sh
   ```

2. Get public DNS names of all instances:
   ```shell
   ./bin/get_public_dns_names.sh
   ```

### Setup Consul (Optional)

For service mesh capabilities, install Consul before Nomad:

1. SSH into each instance and run the setup:
   ```shell
   ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<public-dns>
   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/setup_consul_aws_ami.sh | sh
   ```

2. Paste the public DNS names of all instances from previously called `get_public_dns_names.sh`

3. Verify Consul cluster:
   ```shell
   consul members
   ```

### Setup Nomad

1. SSH into each instance and run the setup:
   ```shell
   ssh -i ~/workspace/nomad/nomad-keypair.pem ec2-user@<public-dns>
   curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/bin/setup_nomad_aws_ami.sh | sh
   ```

2. Paste the public DNS names of all instances from previously called `get_public_dns_names.sh`

3. Verify cluster:
   ```shell
   nomad server members
   nomad node status
   nomad node status -self -verbose | grep cni
   ```

## Ingress-Gateway & Web-Service 

1. SSH into any instance and download the Nomad job definitions
   ```shell
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-gateway.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service-defaults.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service.hcl
   ```

2. Configure Consul to know that the Web-Service is of type HTTP rather than TCP
   ```shell
   consul config write web-service-defaults.hcl
   ```

3. Start the Ingress-Gateway
   ```shell
   nomad job run ingress-gateway.hcl
   ```

3. Start the Web-Service
   ```shell
   nomad job run web-service.hcl
   ```


## Requirements

- AWS CLI configured with appropriate credentials
- `jq` for JSON parsing
- EC2 key pair named `nomad-keypair`


## Current VPC-ID

- vpc-ec926686

# Current Security Groups

- sg-77476f14 (default)
- sg-09aa7199da65ed0e3 (HTTP)
- sg-0beaa6c98d73ebd3b (HTTPS)
- sg-07fee22cbcdad4c58 (SSH)