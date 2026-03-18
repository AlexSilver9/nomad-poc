# Nomad Cluster POC

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Nomad](https://img.shields.io/badge/Nomad-1.11.2-00BC7F?logo=hashicorp)
![Consul](https://img.shields.io/badge/Consul-1.22.3-F24C53?logo=consul)
![Envoy](https://img.shields.io/badge/Envoy-1.35.8-AC6199)
![Platform](https://img.shields.io/badge/platform-AWS%20%7C%20Multipass-orange)

A production-oriented proof-of-concept for a HashiCorp Nomad container orchestration cluster with a full Consul service mesh, API Gateway ingress, regex URL rewriting, and ACL security — deployable to AWS EC2 or local Multipass VMs.

---

## Overview

The cluster runs three nodes, each acting as both Nomad server and client. All inter-service traffic is encrypted with mutual TLS via Consul Connect. External traffic enters through a two-layer ingress stack:

```
Internet / ALB
      │
      ├── :8081 (HTTP)  ──► nginx / Traefik   ──► Consul API Gateway :8080 ──► service
      └── :8443 (HTTPS) ──► nginx / Traefik   ──► Consul API Gateway :8082 ──► service
                              (TLS termination,      (Envoy, host-based
                               regex URL rewrite,     routing + service
                               hostname routing)      discovery via xDS)
```

| Layer | Responsibility |
|---|---|
| **nginx / Traefik** | TLS termination, regex URL rewrite with capture groups, hostname routing for HTTPS |
| **Consul API Gateway** | HTTP hostname routing, service discovery via Consul xDS, TCP passthrough for HTTPS-native services |
| **Connect sidecar** | East-west mTLS, service-router (prefix rewrite, traffic splitting) |

### Key features

- **Nomad** — container orchestration, rolling updates, canary deployments, node pools
- **Consul service mesh** — automatic mTLS, service discovery, health checks
- **Consul API Gateway** — Envoy-based ingress, replaces the deprecated ingress gateway
- **Regex URL rewrite** — nginx / Traefik rewrites URLs with capture groups before the API Gateway (e.g. `/download/abc123` → `/service/download.xhtml?token=abc123`)
- **ACL** — Nomad + Consul ACL with role-based user tokens and Nomad Workload Identity (NWI)
- **Node isolation** — sensitive workloads on a dedicated node pool
- **Two deployment targets** — AWS EC2 (`aws/`) and local Multipass VMs (`multipass/`)

---

## Repository layout

```
nomad-poc/
├── aws/
│   ├── bin/
│   │   ├── cluster/        # Scripts run on your local machine (AWS CLI)
│   │   └── instance/       # Scripts run on EC2 instances
│   ├── acl/                # ACL policies and roles (tokens never committed)
│   ├── cluster/nomad/      # Nomad agent configuration
│   ├── infrastructure/
│   │   ├── api-gateway/    # Consul API Gateway job + listener config
│   │   ├── traefik-rewrite/ # Traefik URL rewrite proxy (default)
│   │   └── nginx-rewrite/  # nginx URL rewrite proxy (alternative)
│   └── services/           # Application services (job + Consul config entries each)
├── multipass/              # Local VM deployment
├── jobs/                   # Sample Nomad job specs
└── doc/                    # Documentation
```

---

## Quick start

### Prerequisites

See [doc/PREREQUISITES.md](doc/PREREQUISITES.md) for required AWS resources (VPC, subnets, security groups, key pair) and hardcoded values to update before running the scripts.

### 1. Set up each node

Use `setup_cluster.sh` or `rebuild_cluster.sh` to orchestrate all nodes from your local machine:

```bash
./aws/bin/cluster/setup_cluster.sh
#or
./aws/bin/cluster/rebuild_cluster.sh
```

This installs Consul, Nomad, Docker, and all dependencies; starts the cluster; and deploys the API Gateway and rewriter.

### 2. Set your tokens and connect

```bash
export NOMAD_ADDR=http://<node-ip>:4646
export NOMAD_TOKEN=<your-token>
export CONSUL_HTTP_ADDR=http://<node-ip>:8500
export CONSUL_HTTP_TOKEN=<your-token>

nomad server members   # verify cluster
consul members         # verify service mesh
```

- **Nomad UI**: `http://<node-ip>:4646`
- **Consul UI**: `http://<node-ip>:8500`

For a full setup walkthrough, see [doc/SETUP.md](doc/SETUP.md).

---

## Documentation

### Getting started
| Document | Description |
|---|---|
| [SETUP.md](doc/SETUP.md) | Full cluster setup walkthrough |
| [PREREQUISITES.md](doc/PREREQUISITES.md) | Required AWS resources and hardcoded values |
| [OPERATOR_GUIDE.md](doc/OPERATOR_GUIDE.md) | Day-to-day operations: deploy, stop, drain, tokens |

### Architecture
| Document | Description |
|---|---|
| [ARCHITECTURE.md](doc/ARCHITECTURE.md) | Cluster architecture, traffic flow, layer responsibilities |
| [TRAFFIC_FLOWS.md](doc/TRAFFIC_FLOWS.md) | North-south and east-west traffic explained |
| [API_GATEWAY.md](doc/API_GATEWAY.md) | Consul API Gateway internals, URL rewrite, NWI |

### Configuration
| Document | Description |
|---|---|
| [CONFIGURATION_GUIDE.md](doc/CONFIGURATION_GUIDE.md) | Config entry reference (routes, defaults, intentions, routers) |
| [FILE_ORGANIZATION.md](doc/FILE_ORGANIZATION.md) | Directory and file naming conventions |
| [ADDING_A_SERVICE.md](doc/ADDING_A_SERVICE.md) | Checklist for onboarding a new service |

### Security
| Document | Description |
|---|---|
| [ACL.md](doc/ACL.md) | ACL policy structure and NWI overview |
| [ACL_IMPLEMENTATION.md](doc/ACL_IMPLEMENTATION.md) | Step-by-step ACL bootstrap and enforcement |
| [USER_TOKENS.md](doc/USER_TOKENS.md) | Creating and managing personal operator tokens |
| [NWI.md](doc/NWI.md) | Nomad Workload Identity — how the API Gateway authenticates to Consul |

### Operations
| Document | Description |
|---|---|
| [NODE_ISOLATION.md](doc/NODE_ISOLATION.md) | Sensitive node pool setup and usage |
| [CANARY_TRAFFIC_ISOLATION.md](doc/CANARY_TRAFFIC_ISOLATION.md) | Canary deployments with traffic isolation |
| [CHEATSHEET.md](doc/CHEATSHEET.md) | Nomad and Consul command reference |

---

## Component versions

| Component | Version |
|---|---|
| Nomad | 1.11.2 |
| Consul | 1.22.3 |
| Envoy | 1.35.8 |

---

## License

[MIT](LICENSE)
