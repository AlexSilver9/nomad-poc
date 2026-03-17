# File Organization

This project uses a **service-oriented** file organization, grouping files by the service or component they configure.

## Benefits

- All configs for a service are in one folder
- Easy to add/remove services (add/remove a folder)
- Clear which tool consumes each file via naming convention
- Service lifecycle is self-contained

## Directory Structure

```
aws/
├── bin/                                    # Scripts
│   ├── cluster/                            # Run on your local machine (AWS CLI, SSH, nomad/consul CLI)
│   │   ├── setup_cluster.sh                # Full cluster setup orchestration
│   │   ├── rebuild_cluster.sh              # Tear down and rebuild entire cluster
│   │   ├── teardown_cluster.sh             # Tear down only
│   │   ├── bootstrap_acl.sh               # Day-2: enable and bootstrap ACL
│   │   ├── enforce_acl.sh                 # Day-2: switch Consul to deny mode
│   │   ├── test_routing.sh                # Run 14 routing tests against a node
│   │   ├── create_instances.sh             # Create EC2 instances
│   │   ├── terminate_instances.sh          # Terminate all EC2 instances
│   │   ├── describe_running_instances.sh   # List EC2 instances with IPs
│   │   ├── get_public_dns_names.sh         # Output public DNS names
│   │   ├── create_target_group.sh          # Create ALB target group
│   │   ├── create_alb.sh                   # Create Application Load Balancer
│   │   ├── delete_albs.sh                  # Delete ALBs and listeners
│   │   ├── delete_target_group.sh          # Delete target groups
│   │   ├── create_efs.sh                   # Create EFS file system
│   │   ├── delete_efs.sh                   # Delete EFS file systems
│   │   ├── add_client_nodes.sh             # Add standard nodes to cluster
│   │   └── add_isolated_nodes.sh           # Add isolated node pool nodes
│   └── instance/                           # Run on EC2 instances
│       ├── setup_consul_aws_ami.sh         # Install and configure Consul
│       ├── setup_nomad_aws_ami.sh          # Install Nomad and Docker
│       ├── setup_consul_client.sh          # Install Consul client (joins existing cluster)
│       ├── setup_nomad_client.sh           # Install Nomad client (joins existing cluster)
│       ├── mount_efs.sh                    # Mount EFS file system on instance
│       ├── eval_system_jobs.sh             # Re-evaluate system jobs on newly eligible nodes
│       ├── create_user_tokens.sh           # Create personalized ACL user tokens
│       ├── canary_update.sh                # Demo: canary deployment
│       ├── rolling_update.sh               # Demo: rolling update deployment
│       ├── sensitive_service.sh            # Demo: sensitive service on isolated node pool
│       └── node_drain.sh                   # Demo: graceful node drain
├── acl/                                    # ACL policies and roles (tokens never committed)
├── infrastructure/                         # Platform/infrastructure components
│   ├── api-gateway/
│   │   ├── job.nomad.hcl                   # Consul API Gateway (system job: setup prestart + api main)
│   │   └── gateway.consul.hcl              # Consul api-gateway config entry (listeners only)
│   ├── traefik-rewrite/
│   │   └── job.nomad.hcl                   # Traefik URL rewrite proxy (system job, default)
│   └── nginx-rewrite/
│       └── job.nomad.hcl                   # Nginx URL rewrite proxy (system job, optional)
└── services/                               # Application services
    ├── web-service/
    │   ├── job.nomad.hcl                   # Nomad job
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   ├── intentions.consul.hcl           # Consul service-intentions
    │   └── route.consul.hcl                # Consul http-route (north-south routing via API Gateway)
    ├── business-service/
    │   ├── job.nomad.hcl                   # Nomad job
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   ├── intentions.consul.hcl           # Consul service-intentions
    │   ├── router.consul.hcl               # Consul service-router (east-west path routing)
    │   └── route.consul.hcl                # Consul http-route (north-south routing via API Gateway)
    ├── business-service-api/
    │   ├── defaults.consul.hcl             # Consul service-defaults (no separate job)
    │   └── intentions.consul.hcl
    ├── https-service/
    │   ├── job.nomad.hcl                   # Nomad job (HTTPS-native service, speaks TLS internally)
    │   ├── defaults.consul.hcl
    │   ├── intentions.consul.hcl
    │   └── route.consul.hcl                # Consul tcp-route (north-south routing via API Gateway)
    ├── canary-update-service/
    │   ├── job.nomad.hcl
    │   ├── defaults.consul.hcl
    │   └── intentions.consul.hcl
    ├── rolling-update-service/
    │   ├── job.nomad.hcl
    │   ├── defaults.consul.hcl
    │   └── intentions.consul.hcl
    └── sensitive-service/
        ├── job.nomad.hcl                   # Runs on sensitive-node-pool
        ├── defaults.consul.hcl
        ├── intentions.consul.hcl
        └── node-pool.nomad.hcl             # Nomad node pool definition
```

## File Naming Convention

| Pattern                  | Tool   | Description                                          |
|--------------------------|--------|------------------------------------------------------|
| `job.nomad.hcl`          | Nomad  | Job specification                                    |
| `gateway.consul.hcl`     | Consul | api-gateway config entry (listeners)                 |
| `defaults.consul.hcl`    | Consul | service-defaults config entry                        |
| `router.consul.hcl`      | Consul | service-router config entry (east-west only)         |
| `intentions.consul.hcl`  | Consul | service-intentions config entry                      |
| `node-pool.nomad.hcl`    | Nomad  | Node pool definition                                 |
| `route.consul.hcl`       | Consul | http-route or tcp-route (north-south routing via API Gateway) |

The double extension (`*.nomad.hcl` / `*.consul.hcl`) makes it clear which tool consumes each file.

## How to Apply Configurations

### Consul config entries (all `*.consul.hcl` files)

Apply service-defaults and intentions before routes — Consul rejects a route if the service's protocol is not declared yet.

```bash
# Service defaults and intentions first
find services/ -name "defaults.consul.hcl" -exec consul config write {} \;
find services/ -name "intentions.consul.hcl" -exec consul config write {} \;
find services/ -name "router.consul.hcl" -exec consul config write {} \;

# Then routes and gateway listener
find services/ -name "route.consul.hcl" -exec consul config write {} \;
consul config write infrastructure/api-gateway/gateway.consul.hcl
```

### Nomad jobs (all `*.nomad.hcl` files)

Run in dependency order — rewriter and API Gateway before services:

```bash
# 1. Rewriter (nginx or Traefik)
nomad job run infrastructure/nginx-rewrite/job.nomad.hcl
# or
nomad job run infrastructure/traefik-rewrite/job.nomad.hcl

# 2. API Gateway
nomad job run infrastructure/api-gateway/job.nomad.hcl

# 3. Services
nomad job run services/web-service/job.nomad.hcl
nomad job run services/business-service/job.nomad.hcl
# ...
```
