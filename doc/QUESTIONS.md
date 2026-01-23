- Clusters Cloud Native:
    - Dev/Smoke: Hier läuft alles, und es darf auch mal rauchen, Cluster Development
    - Stageing/Release/UAT: Hier läuft alles, Kunden können gegen Release Candidates testen
    - Prod: Hier läuft alles

- Client node introduction token? -> YES
    - https://developer.hashicorp.com/nomad/docs/deploy/clusters/connect-nodes#use-client-node-introduction-tokens
    - Node darf nur bestimmten NodePool joinen
    - und/oder Node muss bestimmten Namen haben um joinen zu dürfen
    - und/oder TTL

- How to connect to my host network when using Docker Desktop (Windows and MacOS)?
    - https://developer.hashicorp.com/nomad/docs/faq#q-how-to-connect-to-my-host-network-when-using-docker-desktop-windows-and-macos

- Nomad als root für Docker Plugin 'resources.cores' -> NO
    - Nomad as root or in docker group to access Docker Unix socket
    - resources.cores geht (CPU Isolation / Numa Scheduling) geht nur mit Nomad als root, ebenso nicht-Docker Driver Tasks
    - https://developer.hashicorp.com/nomad/docs/deploy/task-driver/docker#client-requirements
    - Ohne root -> ständige WARN im Log

- Nomad als:
    - Binary mit manuellem Control und Version Control
    - Binary mit systemd Control und manuellem Version Control
    - Linux Package mit systemd Control und Linux Version Control -> YES

- Nomad Enterprise Features (Contact Sales):
    - https://developer.hashicorp.com/nomad/docs/enterprise
    - https://www.hashicorp.com/de/pricing?tab=nomad
    - ❓ Time-based task execution
    - ❌ Multi-cluster deployment (Multi region)
    - Node pool governance
    - ❌ Enhanced read scalability (Raft non-voters for reads scalability / scheduling throughput)
    - ❌ Non-uniform memory access (NUMA) support
    - ❓ Dynamic Application Sizing (resource consumption of applications using resource sizing recommendations)
    - ❓ Audit logging
    - ❓ Resource quotas (restrict the aggregate resource usage of namespaces/regions)
    - ❓ Sentinel policies (fine-grained policies on top of ACL)
    - ❌ Automated backups (snapshots of the state of the Nomad server)
    - ❓ Automated upgrades (on new server version promote new servver & degrade old servers once new servers are >= 50% ) -> Check manual upgrades 
    - ❌ Redundancy zones (deploy a non-voting server as a hot standby server on a per availability zone basis)
    - ❓ Long term support releases (receive critical fixes and security patches between LTS releases, and hardened upgrade paths to the next LTS release)
    - ❌ Multiple Vault namespaces
    - ❌ Consul namespace support
    - ❌ Multiple Vault cluster support
    - ❌ Multiple Consul cluster support