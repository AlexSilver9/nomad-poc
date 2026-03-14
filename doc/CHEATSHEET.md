# List of useful Nomad commands

## Official Cheat Sheet
- https://hashicorp.github.io/nomad-cheatsheet/
- https://www.datocms-assets.com/2885/1650045163-kubernetes-to-nomad-cheat-sheet-v2.pdf

## Cluster Validation

List server members:
```shell
nomad server members
```

Show node status:
```shell
nomad node status
```

Show Raft info:
```shell
nomad operator raft list-peers
```

Run job:
```shell
nomad run <job-file>
# or 
nomad job run <job-file>
```

List Jobs:
```shell
nomad status
```

Job status:
```shell
nomad status <job-name>
# or
nomad job status <job-name>
```

Allocation Id:
`Job status → Allocations Tabelle → ID Spalte`

Allocations (inkl. ID) für Job:
```shell
nomad job allocs <job-name>
```

Allocation status (incl. Dynamic Port Mapping):
```shell
nomad alloc status <allocation-id>
```

Execute command or open shell on alloc:
```shell
nomad alloc exec -task=<task-name> <allocation-id> <command>
# e.g. `nomad alloc exec -task=app 79d50fcd /bin/bash`
```

Logs:
```shell
nomad logs -f <allocation-id>
# or when alloc has multiple tasks
nomad logs -f <allocation-id> <task-name>

# or
nomad alloc logs -f <allocation-id>
# or when alloc has multiple tasks
nomad alloc logs -f <allocation-id> <task-name>
```

Stop job:
```shell
nomad stop <job-name>
# or
nomad job stop <job-name>
```

Cleanup:
```shell
nomad stop -purge <job-name>
# or
nomad job stop -purge <job-name>
```

Server members:
```shell
nomad server members
```

Dry rum Upgrade deployment:
```shell
nomad job plan <job-file>
```

Insect Upgrade deployment:
```shell
nomad status <job-name>
```

Show deployments:
```shell
nomad job deployments <job-name>
```

Deployment status:
```shell
nomad deployment status <deployment-id>
```

Get Allocation IP address (e.g. for Testing Canary alloc directly)
```shell
nomad alloc status <canary allocation-id> | grep -A5 'Allocation Addresses'
```

Fail deployment (Rollback Canary)
```shell
nomad deployment fail <deployment-id>
```

Promote deployment (Approve Canary for Rollout)
```shell
nomad deployment promote <deployment-id>
```

Job history:
```shell
nomad job history -p <job-name>
```

Garbage Collection
```shell
nomad system gc
```

Node Drain Enable
```shell
nomad node drain -enable -yes <node-id>
```

Node Drain Disable
```shell
nomad node drain -disable -yes <node-id>
```

## Consul — Service Health

Check health of a service (via HTTP API):
```shell
curl -s http://localhost:8500/v1/health/service/<service-name> | jq '.[].Checks[].Status'
```

## Consul — Config Entries

List config entries by kind:
```shell
consul config list -kind api-gateway
consul config list -kind http-route
consul config list -kind tcp-route
consul config list -kind service-router
consul config list -kind service-intentions
consul config list -kind service-defaults
```

Read a specific config entry:
```shell
consul config read -kind api-gateway -name api-gateway
```

## Consul — ACL

List all tokens:
```shell
consul acl token list
```

List configured auth methods:
```shell
consul acl auth-method list
```

List NWI (Nomad Workload Identity) binding rules:
```shell
consul acl binding-rule list -method nomad-workloads
```

# Job Specification

- https://developer.hashicorp.com/nomad/docs/job-specification/job

| Abschnitt                 | Bedeutung                                         |
|---------------------------|---------------------------------------------------|
| job "nginx"	            | Name des Jobs                                     |
| datacenters = ["dc1"]	    | Nomad DC, standardmäßig dc1                       |
| type = "service"	        | Dauerhafter Service (nicht Batch)                 |
| group "web"	            | Task-Gruppe → mehrere Tasks gleichzeitig möglich  |
| task "nginx"	            | Task innerhalb der Gruppe                         |
| driver = "docker"         | Docker Driver verwenden                           |
| config.image              | Docker Image                                      |
| resources	                | CPU / RAM Limits                                  |
| network.port              | Port-Mapping → Nomad mappt Container Port zu Host |