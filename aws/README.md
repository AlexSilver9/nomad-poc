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
| `create_instances.sh` | Create 3 EC2 instances (nomad1, nomad2, nomad3) |
| `describe_running_instances.sh` | List all instances with IPs and network info |
| `terminate_instances.sh` | Terminate ALL EC2 instances (use with caution) |
| `get_public_dns_names.sh` | Output public DNS names (one per line) |
| `setup_consul_aws_ami.sh` | Install Consul on Amazon Linux |
| `setup_nomad_aws_ami.sh` | Install Nomad + Docker on Amazon Linux |
| `create_target_group.sh` | Create ALB target group for ingress gateway |
| `create_alb.sh` | Create Application Load Balancer |
| `delete_target_group.sh` | Delete target group(s) |
| `delete_alb.sh` | Delete ALB(s) |


## Setup Workflow

Lifecycle Overview:
1. Create instances and get public DNS names
2. Setup Consul in AWS EC2 instances
3. Setup Nomad in AWS EC2 instances
4. Download Nomad jobs & service-defaults & ingress-intentions
5. Configure Consul for HTTP Web-Service service-defaults & ingress-intentions
6. Run Ingress-Gateway job
7. Run Web-Service job
8. Create AWS target group
9. Create AWS load balancer
10. Terminate AWS EC2 intances
11. Delete AWS target group
12. Delete AWS load balancer

### Create AWS EC2 instances

1. Go to bin dir:
   ```shell
   cd ./bin
   ```

2. Create instances:
   ```shell
   ./create_instances.sh
   ```

3. Get public DNS names of all instances:
   ```shell
   ./get_public_dns_names.sh
   ```

### Setup Consul

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
   nomad node status -self -verbose | grep consul
   ```

## Ingress-Gateway & Web-Service 

1. SSH into any instance and download the Nomad job definitions, service-defaults & ingress-intentions
   ```shell
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-gateway.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service-defaults.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-intentions.hcl
   ```

2. Configure Consul Web-Service service-defaults & ingress-intentions
   ```shell
   consul config write web-service-defaults.hcl
   # Check with: consul config read -kind service-defaults -name web-service
   consul config write ingress-intentions.hcl
   # Check with: consul config read -kind service-intentions -name web-service
   ```

3. Start the Ingress-Gateway
   ```shell
   nomad job run ingress-gateway.hcl
   ```

4. Start the Web-Service
   ```shell
   nomad job run web-service.hcl
   ```

5. Check Ingress-Gateway
   ```shell
   curl -v http://localhost:8080/
   ```

## AWS Application Load Balancer

Create an ALB to route external traffic to the ingress gateway:

1. Create a target group (registers all running instances on port 8080):
   ```shell
   ./create_target_group.sh nomad-target-group
   ```

2. Create the ALB with the target group ARN from previous step:
   ```shell
   target_group_arn=$(aws elbv2 describe-target-groups --names nomad-target-group --query 'TargetGroups[0].TargetGroupArn' --output text)
   ./create_alb.sh $target_group_arn nomad-alb
   ```

3. Check/Wait for targets become healthy:
   ```shell
   aws elbv2 describe-target-health --target-group-arn $target_group_arn
   ```

4. Test the ALB (after targets become healthy):
   ```shell
   curl http://<alb-dns-name>/
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