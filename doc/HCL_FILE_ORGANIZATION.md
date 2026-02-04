# HCL File Organization Options

This document outlines two approaches for organizing Consul config entries and Nomad job files.

## Current Structure

```
aws/
└── jobs/                           # Mixed Consul configs and Nomad jobs
    ├── web-service-defaults.hcl    # Consul config entry
    ├── web-service.hcl             # Nomad job
    ├── business-service.hcl        # Nomad job
    ├── business-service-defaults.hcl
    ├── ingress-gateway.hcl         # Nomad job
    ├── ingress-intentions.hcl      # Consul config entry
    └── ...
```

> **Note:** Ingress gateway routing is defined directly in the Nomad job (`ingress-gateway.hcl`)
> rather than a separate Consul config entry. This avoids conflicts where Nomad would overwrite
> the Consul config on job deployment.

---

## Option A: Group by Tool

Organize files by the tool that consumes them (Consul vs Nomad).

```
aws/
├── bin/                            # Scripts
├── consul/
│   └── config-entries/             # Consul config entries
│       ├── web-service-defaults.hcl
│       ├── business-service-defaults.hcl
│       ├── business-service-api-defaults.hcl
│       ├── business-service-router.hcl
│       └── ingress-intentions.hcl
└── nomad/
    └── jobs/                       # Nomad job specifications
        ├── traefik-rewrite.hcl
        ├── ingress-gateway.hcl
        ├── web-service.hcl
        ├── business-service.hcl
        └── nginx-rewrite.hcl       # (optional alternative)
```

### Pros
- Clear separation by tool
- Easy to find "all Consul configs" or "all Nomad jobs"
- Simpler structure with less nesting
- Good for ops-focused workflows
- Easier for learning/POC projects

### Cons
- Related configs for a service are split across directories
- Harder to see what a single service needs
- Service-level changes require editing multiple locations

### When to Use
- Smaller projects with fewer services
- Learning/POC environments
- Ops-centric teams that think in terms of tools
- When you frequently need to view all configs for one tool

---

## Option B: Group by Service/Workload

Organize files by the service or component they configure.

```
aws/
├── bin/                            # Scripts
├── infrastructure/                 # Platform/infrastructure components
│   ├── ingress-gateway/
│   │   ├── job.nomad.hcl           # Nomad job (includes ingress routing config)
│   │   └── intentions.consul.hcl   # Consul intentions
│   ├── traefik-rewrite/
│   |   └── job.nomad.hcl           # Nomad job (no Consul config needed)
│   └── nginx-rewrite/
│       └── job.nomad.hcl           # (optional alternative)
└── services/                       # Application services
    ├── web-service/
    │   ├── job.nomad.hcl           # Nomad job
    │   └── defaults.consul.hcl     # Consul service-defaults
    ├── business-service/
    │   ├── job.nomad.hcl           # Nomad job
    │   ├── defaults.consul.hcl     # Consul service-defaults
    │   └── router.consul.hcl       # Consul service-router
    └── business-service-api/
        └── defaults.consul.hcl     # Consul service-defaults (no separate job, deployed with business-service)
```

> **Note:** Ingress gateway routing is defined in the Nomad job itself, not a separate Consul config file.

### File Naming Convention
- `job.nomad.hcl` - Nomad job specification
- `defaults.consul.hcl` - Consul service-defaults config entry
- `router.consul.hcl` - Consul service-router config entry
- `intentions.consul.hcl` - Consul service intentions

### Pros
- All configs for a service in one place
- Easy to add/remove services (add/remove a folder)
- Natural fit for microservices teams (each team owns a folder)
- Better for GitOps/CI/CD (deploy service = apply folder contents)
- Service lifecycle is self-contained

### Cons
- More nesting and directories
- Harder to see "all Consul configs at once"
- Requires convention for file naming
- Setup script needs to traverse directories

### When to Use
- Production-oriented projects
- Microservices architecture with team ownership
- GitOps workflows where services are deployed independently
- When services have complex, multi-file configurations

---

## Setup Script Implications

### Option A Script Changes
```bash
GITHUB_RAW_BASE="https://raw.githubusercontent.com/.../aws"

# Consul configs
for file in "${consul_files[@]}"; do
    ssh_run "$node" "wget -q $GITHUB_RAW_BASE/consul/config-entries/$file"
done

# Nomad jobs
for file in "${nomad_jobs[@]}"; do
    ssh_run "$node" "wget -q $GITHUB_RAW_BASE/nomad/jobs/$file"
done
```

### Option B Script Changes
```bash
GITHUB_RAW_BASE="https://raw.githubusercontent.com/.../aws"

# Deploy infrastructure components
for component in ingress-gateway traefik-rewrite; do
    ssh_run "$node" "mkdir -p $component"
    # Download all files for this component
    for file in $(get_files_for_component $component); do
        ssh_run "$node" "wget -q $GITHUB_RAW_BASE/infrastructure/$component/$file -O $component/$file"
    done
done

# Deploy services
for service in web-service business-service business-service-api; do
    ssh_run "$node" "mkdir -p $service"
    # Download all files for this service
    for file in $(get_files_for_service $service); do
        ssh_run "$node" "wget -q $GITHUB_RAW_BASE/services/$service/$file -O $service/$file"
    done
done

# Apply Consul configs (*.consul.hcl)
find . -name "*.consul.hcl" -exec consul config write {} \;

# Run Nomad jobs (*.nomad.hcl) in order
nomad job run infrastructure/traefik-rewrite/job.nomad.hcl
nomad job run infrastructure/ingress-gateway/job.nomad.hcl
nomad job run services/web-service/job.nomad.hcl
nomad job run services/business-service/job.nomad.hcl
```

---

## Recommendation

| Scenario | Recommended Option |
|----------|-------------------|
| POC / Learning | Option A |
| Small team, few services | Option A |
| Production-bound project | Option B |
| Multiple teams, many services | Option B |
| GitOps / CI/CD pipelines | Option B |
| Ops-focused workflow | Option A |

For this Nomad POC, **Option A** is sufficient and keeps things simple. Consider migrating to **Option B** if the project grows toward production use with multiple independently-deployable services.
