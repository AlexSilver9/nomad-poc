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
- Nginx Routing per URL mit Rewrite

# TODO:
- Resources OOM doesn't raise
- Deploments auf verschiedenen Ports (1 Alloc)
- Node-Schwenk
- Node drain -> startet erst neue Allocs auf anderer Instanz und drained dann, oder andersrum?
    - Testen wie nah man an echte Zero-Downtime ran
- Node drain per UI?
- Rolling Updates der Container
- AWS LoadBalancer -> Ingress Routing zum indizierten Container via DNS (insbesondere wenn Allocs dynamisch auf Nodes verteilt werden) 
- Docker Stateful Jobs
- Allocations auf andere Nodes verschieben, zwecks Sytemupgrade
- Start container with interactive shell
- Start interactive Shell on running container
- Retry / Reschedule Policies
- Timeouts & Exit Codes
- Failure Handling
- Variables (aka Kubernetes ConfigMaps)
- Nomad Actions (https://developer.hashicorp.com/nomad/docs/job-declare/nomad-actions)
- Node Anti-Affinity
- Indexed Containers (Container X, Y, Z run only on Node X)
- Node Isolation (Spezialserver -> eigener Namespace? -> HA?)
- Test System(-Batch) vs. Constrain.distinctHost auf Cluster mit dedizierten Clients, isolated Clients und Servern, ob die Jobs auf Client und/oder Server ausgeführt werden
- Vault Secrets (https://developer.hashicorp.com/nomad/docs/secure/vault)
- Vault TLS
- ACLs + TLS
- Volumes (lokaler flüchtiger Storage)
- CSI (Container Storage Interface - Persistent Volume Mount - CSI Plugin Driver)
- Ingress / Load-Balancing
- Nomad Binary Update (https://developer.hashicorp.com/nomad/docs/upgrade) (https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific)
- systemd Unit Update
- node pools & constraints
- Port Forwarding (https://github.com/hashicorp/nomad/issues/6925)
- Migrationskonzept

# OPTIONAL:
- Observability (Prometheus)
