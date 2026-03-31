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
- File Organization
- Volumes (EFS / lokaler flüchtiger Storage / KEIN CSI)
- ACLs
- Nomad ACL lost token bootstrap (leader: nomad acl bootstrap -> sudo tee /opt/nomad/data/server/acl-bootstrap-reset -> restart)
- Consul token generation or initial_management token
- mTLS
- docker registry connection (tech user kommt von Steffen)
- demo service deployen & testen
    - mapping:  /data/container/demo/...
    - registry: dockerhub.appservices.mitel.com
    - image:    /app/demo:1.0.0
    - Payara HTTPS:
        -> nginx stream listener
        -> ALB: TCP passthrough to nginx port 8083 — no TLS termination!!
- Environment Variables
- Variables (aka Kubernetes ConfigMaps)
    - Env Vars -> Static per Job -> im Git -> Job Redeploy on Change
    - Consul KV -> Dynamic -> Runtime update of vars (pendant to CM), secret management, ACLs
    - Nomad Variables -> Dynamic -> Runtime update of vars -> secret management, ACLs
- Rollenkonzept für personalisierte User (alice, bob)
- Rename main -> master
- Rename "nomad-deployer", "nomad-operator", "consul-readwrite"
- Volumes mappen
    - /data/container/demo/logs:/opt/payara/logs
    - /data/container/demo/javamelody:/data/javamelody
    -> chown -R 1111:1111 (parara)
    -> redeploy with purge
- Exec into alloc (Start interactive shell / run command on running container)
- Deploy/Undeploy Script: deploy <service name>
- Token Revoke Scripts (Script für Token Löschung)
- 2 Repos:
    - Cluster Scripts & ACLs
    - Service Definitions
- 3-Node Cluster bilden
- Update SETUP.md + SERVICES.md
- Zugriff Container Definitionen
- api-gateway statt ingress-gateway
- SSL -> ALB -> Nginx SSL -> Payara SSL hostname based routing
- Nomad Administration Menü wenn ACLS aktiv sind -> Token Revoke per UI
- ALB specs
- Reserve resources for OS/system
- Reserve resources for Nginx + API-Gateway
- Onboarding 3 neue Nodees als Client (1 als isolated: 'sls-ssh-sync')
- CPU & Memory Settings / Limits erarbeiten

- run.sh + stop.sh 
- server heartbeat_grace -> 60sec ?
- ServiceName RFC 1123
- Services übernehmen:
    - Phonebook Service
    - service.customers     curl -k -H "Host: service.customers.mitel.com" https://albtest.appservices.mitel.com
    - service.assets        curl -k -H "Host: service.assets.mitel.com" https://albtest.appservices.mitel.com
    - service.swa           curl -k -H "Host: service.swa.mitel.com" https://albtest.appservices.mitel.com
- Service Healthcheck auf na/ping, rest/ping status code 200
- set_real_ip header aus nginx
- Nginx Healthcheck

# TODO:
sudo git pull origin master --rebase

- ACLs aktiv setzen
- Nginx Configs aus Image übernehmen oder Nginx Image übernehmen (`infrastructure/nginx-rewrite/config`)
    - Service-spezifische configs werden im Job künftig in die Alloc gemappt
    - TLSv1.2 + TLSv1.3 + Cipher Suites zentralisieren und aus den server blocks rausnehmen (eigenes Template)
- Reserve resources for Envoy Sidecar
- Revisit CPU and Memory Settings for the injected Envoy sidecar proxy

- Nomad bin packing: memory von Docker Images nehmen   

- Scripts Branches
    - master (prod)
    - staging (6 Nodes)
    - dev (1 Node)

- Prometheus / Grafana Recherche

- Document Consul ACL Reset: https://developer.hashicorp.com/consul/docs/secure/acl/reset
- `consul/policies/agent.policy.hcl`
    - scope agent tokens to their own node name using `node "hostname" { policy = "write" }`
- Update CheatSheet
- Nomad Binary Update
    - https://developer.hashicorp.com/nomad/docs/upgrade
    - https://developer.hashicorp.com/nomad/docs/upgrade/upgrade-specific
- Ingress Connection Drop on Config Update? (consul config write)
- Resources OOM doesn't raise
- Docker Stateful Jobs
- Start container with interactive shell
- Retry / Reschedule Policies
- Timeouts & Exit Codes
- Failure Handling
- Health Checks
    - https://developer.hashicorp.com/nomad/docs/job-specification/check
- Job Parameters (aka Args) possible?
- Nomad Actions
    - https://developer.hashicorp.com/nomad/docs/job-declare/nomad-actions
- Node Anti-Affinity
- Indexed Containers (Container X, Y, Z run only on Node X)
- Test System(-Batch) vs. Constrain.distinctHost auf Cluster mit dedizierten Clients, isolated Clients und Servern, ob die Jobs auf Client und/oder Server ausgeführt werden
- Vault Secrets
    - https://developer.hashicorp.com/nomad/docs/secure/vault
- Vault TLS
- systemd Unit Update
- node pools & constraints
- Port Forwarding https://github.com/hashicorp/nomad/issues/6925
- Garbage Collection (Docker Images, Nomad, Consul)
- Migrationskonzept

# OPTIONAL:
- Observability (Prometheus)

# POC ONLY
- Make AWS prerequisites configurable: VPC, subnets, security groups, key pair name, instance type, region
    - Currently hardcoded in create_instances.sh, create_target_group.sh, create_alb.sh
    - Move to a config file (e.g. aws/config.sh) sourced by all cluster scripts
- Replace GitHub raw file downloads with `git clone`
    - setup_cluster.sh currently downloads individual files via wget from raw.githubusercontent.com
    - Should clone the repo on the node instead, then reference files locally
    - Avoids broken downloads when files are added/moved and simplifies the download logic