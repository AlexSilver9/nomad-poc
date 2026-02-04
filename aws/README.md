# AWS Nomad Cluster

Deploy a full featured Nomad cluster on AWS EC2 instances.


## Architecture

```
AWS ALB:443 → Traefik:8081 (URL Rewrite) → Consul Envoy:8080 (Ingress) → Sidecars → Services
```

- **Traefik**: Handles regex URL rewrites (e.g., `/download/123` → `/business-service/download.xhtml?token=123`)
- **Envoy Ingress Gateway**: Consul Connect ingress, routes to mesh services
- **Envoy Sidecars**: mTLS between services


## Scripts

| Script                            | Run in/on    | Description                                      |
|-----------------------------------|--------------|--------------------------------------------------|
| `setup_cluster.sh`                | Setup Shell  | **Full automated setup** (creates instances, installs Consul/Nomad, configures services, creates ALB) |
| `create_instances.sh`             | Setup Shell  | Create 3 EC2 instances (nomad1, nomad2, nomad3)  |
| `describe_running_instances.sh`   | Setup Shell  | List all instances with IPs and network info     |
| `terminate_instances.sh`          | Setup Shell  | Terminate ALL EC2 instances                      |
| `get_public_dns_names.sh`         | Setup Shell  | Print public DNS names (one per line)            |
| `create_target_group.sh`          | Setup Shell  | Create ALB target group for ingress gateway      |
| `create_alb.sh`                   | Setup Shell  | Create Application Load Balancer                 |
| `delete_target_group.sh`          | Setup Shell  | Delete target group(s)                           |
| `delete_alb.sh`                   | Setup Shell  | Delete ALB(s)                                    |
| `setup_consul_aws_ami.sh`         | EC2 Instance | Install Consul on Amazon Linux                   |
| `setup_nomad_aws_ami.sh`          | EC2 Instance | Install Nomad + Docker on Amazon Linux           |


## Quick Start (Automated)

Run the full cluster setup with a single command:

```shell
cd ./bin
./setup_cluster.sh
```

This script automates the entire setup workflow:
1. Creates 3 EC2 instances (nomad1, nomad2, nomad3)
2. Waits for instances to be accessible via SSH
3. Installs Consul on all nodes and forms the cluster
4. Installs Nomad on all nodes and forms the cluster
5. Configures Consul service mesh (service-defaults, router, ingress-gateway, intentions)
6. Runs Nomad jobs (Traefik, ingress-gateway, web-service, business-service)
7. Tests internal routing
8. Creates AWS target group and Application Load Balancer
9. Waits for targets to be healthy and tests ALB endpoints

At the end, you'll get the ALB DNS name, UI links, ssh commands and test commands.

**Requirements:**
- SSH key at `~/workspace/nomad/nomad-keypair.pem` (or set `SSH_KEY` env var)
- AWS CLI configured with appropriate credentials


## Setup Workflow (Manual)

Lifecycle:

| Action | Run in/on         | Description                                                               |
|--------|-------------------|---------------------------------------------------------------------------|
| 1.     | Setup Shell       | Create instances and get public DNS names                                 |
| 2.     | All EC2 Instances | Setup Consul                                                              |
| 3.     | All EC2 Instances | Setup Nomad                                                               |
| 4.     | All EC2 Instances | Download Nomad jobs & Consul config entries                               |
| 5.     | Any EC2 Instance  | Configure Consul (service-defaults, router, ingress-gateway, intentions)  |
| 6.     | Any EC2 Instance  | Run Traefik-Rewrite job                                                   |
| 7.     | Any EC2 Instance  | Run Ingress-Gateway job                                                   |
| 8.     | Any EC2 Instance  | Run Web-Service job                                                       |
| 9.     | Setup Shell       | Create AWS target group (port 8081 for Traefik)                            |
| 10.    | Setup Shell       | Create AWS load balancer                                                  |
| 11.    | Setup Shell       | Terminate AWS EC2 instances                                               |
| 12.    | Setup Shell       | Delete AWS load balancer                                                  |
| 13.    | Setup Shell       | Delete AWS target group                                                   |

### Create AWS EC2 instances

1. Open a shell for setup and go to bin dir:
   ```shell
   cd ./bin
   ```

2. Create EC2 instances:
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

1. SSH into any instance and download the Nomad job definitions and Consul config entries
   ```shell
   # Nomad jobs
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/traefik-rewrite.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/nginx-rewrite.hcl # optional for nginx instead Traefik
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-gateway.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/business-service.hcl

   # Consul config entries
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-gateway-config.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/web-service-defaults.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/ingress-intentions.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/business-service-defaults.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/business-service-api-defaults.hcl
   wget https://raw.githubusercontent.com/AlexSilver9/nomad-poc/refs/heads/main/aws/jobs/business-service-router.hcl
   ```

2. Configure Consul config entries (service-defaults, ingress-gateway, intentions, router)
   ```shell
   consul config write web-service-defaults.hcl
   consul config write business-service-defaults.hcl
   consul config write business-service-api-defaults.hcl
   consul config write business-service-router.hcl
   consul config write ingress-gateway-config.hcl
   consul config write ingress-intentions.hcl

   # Verify:
   consul config read -kind service-defaults -name web-service
   consul config read -kind service-defaults -name business-service
   consul config read -kind service-router -name business-service
   consul config read -kind ingress-gateway -name ingress-gateway
   consul config read -kind service-intentions -name web-service
   ```

3. Start the Traefik URL rewrite layer (runs on all nodes)
   ```shell
   nomad job run traefik-rewrite.hcl
   ```

4. Start the Ingress-Gateway (runs on all nodes)
   ```shell
   nomad job run ingress-gateway.hcl
   ```

5. Start the Web-Service
   ```shell
   nomad job run web-service.hcl
   ```

6. Start the Business-Service (deploys both business-service and business-service-api)
   ```shell
   nomad job run business-service.hcl
   ```

7. Test the routing

   Check Ingress-Gateway (internal, after Traefik):
   ```shell
   curl http://localhost:8080/
   # Expected: "hello world" (web-service)
   ```

   Test Traefik → Envoy → web-service (default):
   ```shell
   curl http://localhost:8081/
   # Expected: "hello world" (web-service)
   ```

   Test Traefik → Envoy → business-service (specific host):
   ```shell
   curl -sH "Host: business-service" http://localhost:8081/ | grep GET && \
   curl -sH "Host: business-service" http://localhost:8081/ | grep Name
   # Expected: "GET / ..."
   # Expected: "Name: business-service"
   ```

   Test business-service routing (requires Host header):
   ```shell
   # Default route → business-service
   curl -sH "Host: business-service" http://localhost:8080/ | grep Name
   # Expected: "Name: business-service"

   # Legacy API route → business-service-api
   curl -sH "Host: business-service" http://localhost:8080/legacy-business-service/test | grep GET && \
   curl -sH "Host: business-service" http://localhost:8080/legacy-business-service/test | grep Name
   # Expected: "GET /legacy-business-service/test ..."
   # Expected: "Name: business-service-api"

   # Download route (via Traefik rewrite) - verifies URL rewriting works
   curl -L -H "Host: business-service" http://localhost:8081/download/mytoken123
   # Expected: whoami output showing the rewritten path:
   #   Name: business-service
   #   GET /business-service/download.xhtml?token=mytoken123 ...
   ```

## AWS Application Load Balancer

Create an ALB to route external traffic to Traefik:

1. Return to shell for setup and create a target group (registers all running instances on port 8081 for Traefik):
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
   # Get ALB DNS name
   alb_dns=$(aws elbv2 describe-load-balancers --names nomad-alb --query 'LoadBalancers[0].DNSName' --output text)

   # Default route → web-service
   curl http://$alb_dns/
   # Expected: "hello world"

   # business-service (specific host)
   curl -sH "Host: business-service" http://$alb_dns/ | grep Name
   # Expected: "Name: business-service"

   # Legacy API route → business-service-api
   curl -sH "Host: business-service" http://$alb_dns/legacy-business-service/test | grep Name
   # Expected: "Name: business-service-api"

   # Download route (via Traefik regex rewrite)
   curl -L -sH "Host: business-service" http://$alb_dns/download/mytoken123 | grep -E "(Name|GET)"
   # Expected:
   #   Name: business-service
   #   GET /business-service/download.xhtml?token=mytoken123 ...
   ```


## Requirements

- AWS CLI configured with appropriate credentials (`aws login`)
- `jq` for JSON parsing
- EC2 key pair named `nomad-keypair`


## Current VPC-ID

- vpc-ec926686

# Current Security Groups

- sg-77476f14 (default)
- sg-09aa7199da65ed0e3 (HTTP)
- sg-0beaa6c98d73ebd3b (HTTPS)
- sg-07fee22cbcdad4c58 (SSH)