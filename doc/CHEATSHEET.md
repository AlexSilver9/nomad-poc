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
nomad run <jobfile>
# or 
nomad job run <jobfile>
```

List Jobs:
```shell
nomad status
```

Job status:
```shell
nomad status <jobname>
# or
nomad job status <jobname>
```

Allocation Id:
`Job status → Allocations Tabelle → ID Spalte`

Allocations (inkl. ID) für Job:
```shell
nomad job allocs <jobname>
```

Allocation status (incl. Dynamic Port Mapping):
```shell
nomad alloc status <allocation id>
```

Logs:
```shell
nomad logs -f <allocation id>
# or
nomad alloc logs -f <allocation id>
```

Stop job:
```shell
nomad stop <jobname>
# or
nomad job stop <jobname>
```

Cleanup:
```shell
nomad stop -purge <jobname>
# or
nomad job stop -purge <jobname>
```

Server members:
```shell
nomad server members
```

Dry rum Upgrade deployment:
```shell
nomad job plan <jobfile>
```

Insect Upgrade deployment:
```shell
nomad status <jobname>
```

Show deployments:
```shell
nomad job deployments <jobname>
```

Deployment status:
```shell
nomad deployment status <deployment id>
```

Get Allocation IP address (e.g. for Testing Canary alloc directly)
```shell
nomad alloc status <canary allocation id> | grep -A5 'Allocation Addresses'
```

Fail deployment (Rollback Canary)
```shell
nomad deployment fail <deployment id>
```

Promote deployment (Approve Canary for Rollout)
```shell
nomad deployment promote <deployment id>
```

Job history:
```shell
nomad job history -p <jobname>
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