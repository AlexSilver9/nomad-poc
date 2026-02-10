# DONE:
- 3 Nomad Server & Client Instanzen
- systemd Unit für Nomad
- Docker Driver für Docker Machine einrichten
- Service Jobs
- Batch Jobs
- System Jobs
- System Batch Jobs
- Periodic Batch Job (Cron)
- Job Lifecycle (Pre, Post, Sidecar, etc ...)
- Ingress / Load-Balancing
- Nginx Routing per URL mit Rewrite -> Traefik / Nginx
- Rolling Updates der Container
- Canary Updates der Container
- Node Isolation (Spezialserver -> Namespace? -> HA?) -> Node Pool (default, all, sensitive)
- Node-Schwenk
- Node drain per UI? -> YES
- Node drain -> startet erst neue Allocs auf anderer Instanz und drained dann


# TODO:
- File Organization
- Volumes (EFS / lokaler flüchtiger Storage / CSI)
- ACLs + TLS
- Nomad Binary Update
    - https://developer.hashicorp.com/nomad/docs/upgrade
    - https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific
- Ingress Connection Drop on Config Update? (consul config write)
- Resources OOM doesn't raise
- Docker Stateful Jobs
- Start container with interactive shell
- Start interactive Shell on running container
- Retry / Reschedule Policies
- Timeouts & Exit Codes
- Failure Handling
- Health Checks
    - https://developer.hashicorp.com/nomad/docs/job-specification/check
- Variables (aka Kubernetes ConfigMaps)
- Job Parameters (aka Args) possible?
- Nomad Actions
    - https://developer.hashicorp.com/nomad/docs/job-declare/nomad-actions
- Node Anti-Affinity
- Indexed Containers (Container X, Y, Z run only on Node X)
- Test System(-Batch) vs. Constrain.distinctHost auf Cluster mit dedizierten Clients, isolated Clients und Servern, ob die Jobs auf Client und/oder Server ausgeführt werden
- Vault Secrets
    - https://developer.hashicorp.com/nomad/docs/secure/vault
- Vault TLS
- CSI (Container Storage Interface - Persistent Volume Mount - CSI Plugin Driver)
- systemd Unit Update
- node pools & constraints
- Port Forwarding
    - https://github.com/hashicorp/nomad/issues/6925
- Migrationskonzept

# OPTIONAL:
- Observability (Prometheus)
