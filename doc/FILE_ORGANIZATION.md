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
│   ├── cluster/                            # Run on your local machine to setup the aws cluster (AWS CLI, SSH, nomad/consul CLI)
│   │   ├── setup_cluster.sh                # Full cluster setup orchestration
│   │   ├── create_instances.sh             # Create EC2 instances
│   │   ├── terminate_instances.sh          # Terminate all EC2 instances
│   │   ├── describe_running_instances.sh   # List EC2 instances with IPs
│   │   ├── get_public_dns_names.sh         # Output public DNS names
│   │   ├── create_target_group.sh          # Create ALB target group
│   │   ├── create_alb.sh                   # Create Application Load Balancer
│   │   ├── delete_albs.sh                  # Delete ALBs and listeners
│   │   ├── delete_target_group.sh          # Delete target groups
│   │   ├── add_client_nodes.sh             # Add client-only nodes to cluster
│   │   ├── add_isolated_nodes.sh           # Add isolated node pool nodes
│   │   └── rebuild_cluster.sh              # Tear down and rebuild entire cluster
│   └── instance/                           # Run on EC2 instances (install software, configure services)
│       ├── setup_consul_aws_ami.sh         # Install Consul server+client
│       ├── setup_nomad_aws_ami.sh          # Install Nomad server+client and Docker
│       ├── setup_consul_client.sh          # Install Consul client-only (joins existing cluster)
│       ├── setup_nomad_client.sh           # Install Nomad client-only (joins existing cluster)
│       ├── canary_update.sh                # Demo: canary deployment
│       ├── rolling_update.sh               # Demo: rolling update deployment
│       ├── sensitive_service.sh            # Demo: sensitive service on isolated node pool
│       ├── node_drain.sh                   # Demo: graceful node drain
│       └── eval_system_jobs.sh            # Re-evaluate system jobs on newly eligible nodes
├── cluster/nomad/                          # Nomad agent configuration
├── infrastructure/                         # Platform/infrastructure components
│   ├── ingress-gateway/
│   │   ├── job.nomad.hcl                   # Consul Connect ingress gateway (system job)
│   │   ├── with-canary-update.nomad.hcl    # Variant: includes canary-update-service
│   │   ├── with-rolling-update.nomad.hcl   # Variant: includes rolling-update-service
│   │   └── with-sensitive-service.nomad.hcl # Variant: includes sensitive-service
│   ├── traefik-rewrite/
│   │   └── job.nomad.hcl                   # Traefik URL rewrite reverse proxy (system job)
│   └── nginx-rewrite/
│       └── job.nomad.hcl                   # Nginx URL rewrite reverse proxy (system job, optional)
└── services/                               # Application services
    ├── web-service/
    │   ├── job.nomad.hcl                   # Nomad job
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   └── intentions.consul.hcl           # Consul service-intentions
    ├── business-service/
    │   ├── job.nomad.hcl                   # Nomad job (deploys both business-service and business-service-api)
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   └── router.consul.hcl              # Consul service-router (path-based routing)
    ├── business-service-api/
    │   └── defaults.consul.hcl             # Consul service-defaults (no separate job, deployed with business-service)
    ├── canary-update-service/
    │   ├── job.nomad.hcl                   # Nomad job (canary deployment demo)
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   └── intentions.consul.hcl           # Consul service-intentions
    ├── rolling-update-service/
    │   ├── job.nomad.hcl                   # Nomad job (rolling update demo)
    │   ├── defaults.consul.hcl             # Consul service-defaults
    │   └── intentions.consul.hcl           # Consul service-intentions
    └── sensitive-service/
        ├── job.nomad.hcl                   # Nomad job (runs on sensitive-node-pool)
        ├── defaults.consul.hcl             # Consul service-defaults
        ├── intentions.consul.hcl           # Consul service-intentions
        └── node-pool.nomad.hcl             # Nomad node pool definition
```

## File Naming Convention

| Pattern                 | Tool    | Description                        |
|-------------------------|---------|------------------------------------|
| `job.nomad.hcl`         | Nomad   | Job specification                  |
| `defaults.consul.hcl`   | Consul  | Service-defaults config entry      |
| `router.consul.hcl`     | Consul  | Service-router config entry        |
| `intentions.consul.hcl` | Consul  | Service-intentions config entry    |
| `node-pool.nomad.hcl`   | Nomad   | Node pool definition               |
| `with-*.nomad.hcl`      | Nomad   | Ingress gateway variant jobs       |

The double extension (`*.nomad.hcl` / `*.consul.hcl`) makes it clear which tool consumes each file.

## How to Apply Configurations

### Consul config entries (all `*.consul.hcl` files)

```bash
find infrastructure/ services/ -name "*.consul.hcl" -exec consul config write {} \;
```

### Nomad jobs (all `*.nomad.hcl` files)

Run in dependency order:

```bash
# 1. Infrastructure first
nomad job run infrastructure/traefik-rewrite/job.nomad.hcl
nomad job run infrastructure/ingress-gateway/job.nomad.hcl

# 2. Then services
nomad job run services/web-service/job.nomad.hcl
nomad job run services/business-service/job.nomad.hcl
```
