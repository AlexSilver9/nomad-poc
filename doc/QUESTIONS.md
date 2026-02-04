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

------------------------------------------------------------------------------------------------

# Auflösung des statischen Load Balancing

- Aktuell ist ein vorgeschalteter AWS ALB im Einsatz, der alles strikt an einen Nginx LB Docker container auf einer festen Instanz routet
- Der Nginx routet je nach Port den Traffic an andere Container, die jeweils ebenso als Docker container auf festen Instanzen laufen

Ist-Zustand:
```text
Internet
  │
  ▼
AWS ALB
  │  (statisch)
  ▼
EC2 A
 └─ nginx (Docker)
      ├─ :8081 → (Docker) Service A (auf EC2 B)
      ├─ :8082 → (Docker) Service B (auf EC2 C)
      └─ :8083 → (Docker) Service C (auf EC2 D)
```

- Nginx als LB auf indizierter Instanz = **Single Point of Failure**
- Container Anti-Orchestration

Ziel-Zustand:
```text
Internet
  │
  ▼
AWS ALB
  │  (dynamisch)
  ▼
Nomad Allocations (beliebige EC2s)
```

- Nomad entscheidet Placement → keine festen EC2-Zuordnungen, keine festen Ports
- Der ALB hat kein dynamisches Wissen → muss auf stabile, langlebige Ziele routen
- Services sind reine Edge-Services → kein interner Service-zu-Service Traffic nötig
- **Traffic darf nur kontrolliert umgeschwenkt werden** (Sessions liegen lokal)
- Hot-Standby & Schwenken → LB muss Umschalten erlauben, ohne ALB-Rekonfiguration

- ❌ Das schließt ALB-direct-to-Allocations aus.
- ❌ Das schließt statische nginx-Ports aus

## Optimale Architektur

```text
Internet
   │
   ▼
AWS ALB (statisch)
   │
   ▼
Consul Ingress Gateway ("Envoy" als Nomad Job, HA)
   │
   ▼
Nomad Services (dynamisch, beliebige EC2s)
```

Der ALB:
- sieht nur ein stabiles Ziel, keine dynamischen Ports keine Service-Details
- alles Dynamische passiert hinter dem ALB.
- keine AWS IAM Management für dynamische Regeln im ALB 


### Consul Ingress vs. Nginx

| Anforderung                             | Nginx            | Consul Ingress  |
|-----------------------------------------|------------------|-----------------|
| Statischer ALB	                        | ✅	              | ✅             |
| Nomad Placement frei                    | ⚠️	             | ✅             |
| Dynamische Backends                     | ⚠️ (DNS Reloads) | ✅             |
| Kontrolliertes Umschwenken              | ❌               | ✅             |
| Hot-Standby                             | ❌               | ✅             |
| Health-gesteuertes Routing              | ⚠️               | ✅             |
| Kein Singe Point of Failure             | ❌               | ✅             |
| Zero-Downtime Drains                    | ❌               | ✅             |

### Ingress Gateway als Nomad Job

#### Was ist ein Ingress?

Ein Ingress ist eine Config Resource die definiert:
 - Welche externen Anfragen wohin im Cluster weitergeleitet werden. Beispiele:
    - /api/users → user-service
    - /api/payments → payment-service
- Optionales Routing nach Hostnamen, z. B.:
    - users.example.com → user-service
- TLS/SSL-Termination, sodass der Service selbst kein Zertifikat verwalten muss
- Load Balancing, typischerweise auf Container-Ebene (mehrere Instanzen eines Services)

**Ingress ist nicht der Load Balancer selbst, sondern die Konfiguration, die das Routing festlegt.**

### Ingress Gateway Setup:
- 3 Replikas (oder auf allen Nodes)
- Statischer Port (z. B. 8080)
- Registriert sich einmal beim ALB

AWS ALB:

```text
Target Group → ingress-gateway:8080
```

### Services als Connect-enabled Nomad Jobs

```hcl
service {
  name = "web"
  port = "http"

  connect {
    sidecar_service {}
  }
}
```

- ➡️ Keine Port-Kollisionen
- ➡️ Kein Wissen über IPs
- ➡️ Kein manuelles Routing

### Routing (ersetzt Port-basierte nginx-Logik)

```hcl
Kind = "ingress-gateway"
Name = "ingress"

Listeners = [
  {
    Port = 8080
    Protocol = "http"
    Services = [
      {
        Name  = "service-a"
        Hosts = ["a.example.com"]
      },
      {
        Name  = "service-b"
        Hosts = ["b.example.com"]
      }
    ]
  }
]
```

### Hot-Standby & Kernel-Upgrade

Ablauf bei EC2 Kernel Upgrade:

1. Drain Node
    - `nomad node drain <node-id> -enable`
2. Nomad startet neue Allocations
    - Auf **anderen EC2s**
    - Connect Sidecars melden sich bei Consul
    - Ingress Gateway sieht neue Backends
3.  Traffic Shift (automatisch!)
    - Ingress routet nur auf healthy Instanzen
    - Alte Allocations bekommen kein neuen Traffic
    - Sessions laufen kontrolliert aus
4. Node wird leer
    - Alte Allocations stoppen
    - EC2 kann sicher rebootet / gepatcht werden
5. Node kommt zurück
    - `nomad node drain <node-id> -disable`


- ✅ Kein ALB-Eingriff
- ✅ Keine reale Downtime (Session Rebuild ausgenommen)
- ✅ Kein Traffic-Verlust

### Sessions

Da Sessions lokal liegen:
  - Ingress Gateway:
    - ❓ unterstützt Consistent Hashing
    - ❓ oder Source-IP Affinity

- ➡️ Sessions bleiben stabil
- ➡️ Umschwenken nur bei Health-Failure

### Warum das „optimal“ ist

- Der ALB bleibt dumm & stabil
- Nomad bekommt volle Freiheit
- Consul übernimmt dynamische Wahrheit
- Ingress ist austauschbar & skalierbar
- Kernel-Upgrades sind kontrollierte Operationen

# Legacy Nginx

Wichtigste Design-Entscheidung

❓ Nginx weiterhin als Ingress behalten – oder abschaffen?

- Consul ist kein Proxy und kein Reverse-Proxy

Konkreter Vergleich: nginx vs Consul Ingress Gateway

| Feature | nginx | Consul Ingress |
|---------|-------|----------------|
| Fester Einstiegspunkt | ✅ | ✅ |
| Dynamische Backends | ⚠️ (DNS/Reload) | ✅ |
| Healthchecks | ⚠️ | ✅ |
| Load Balancing | ✅ | ✅ |
| Zero-Downtime Scaling | ❌ | ✅ |
| mTLS | ❌ | ✅ |
| Nomad-native | ❌ | ✅ |
| Statische Config | ❌ | ❌ |


# URL REWRITE with TRAEFIK
```text
                    ┌─────────────────────────────────────┐
                    │              AWS ALB                │
                    │  Target Group: all instances:8081   │
                    │          TLS Termination            |
                    └──────────────┬──────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           ▼                       ▼                       ▼
   ┌───────────────┐       ┌───────────────┐       ┌───────────────┐
   │   nomad1      │       │   nomad2      │       │   nomad3      │  <-- Nomad Cluster
   │---------------│       │---------------│       │---------------|
   │ Traefik:8081  │       │ Traefik:8081  │       │ Traefik:8081  │  <-- URL Rewrite
   │      ↓        │       │      ↓        │       │      ↓        │
   │ Envoy:8080    │       │ Envoy:8080    │       │ Envoy:8080    │  <-- Ingress
   │      ↓        │       │      ↓        │       │      ↓        │
   │   Sidecar     │       │   Sidecar     │       │   Sidecar     │  <-- Local Proxy
   │      ↓        │       │      ↓        │       │      ↓        │
   │   Service     │       │   Service     │       │   Service     │  <-- Application
   └───────────────┘       └───────────────┘       └───────────────┘
```


## Files involved in routing

| File	                      | Responsibility                                      |
|-----------------------------|-----------------------------------------------------|
| traefik-rewrite.hcl	        | URL regex rewrite, forwards to Envoy                |
| ingress-gateway.hcl	        | Nomad job for Envoy ingress on :8080 (includes host → service mapping) |
| business-service-router.hcl | Consul config: path-based routing (/swdlgwapi vs /) |


## Traefik vs nginx for URL Rewriting

| Aspect | Traefik | nginx |
|--------|---------|-------|
| Rewrite type | `redirectRegex` (302 redirect, client follows) | `rewrite ... break` (internal, transparent) |
| Regex scope | Matches full URL (`https?://[^/]+/...`) | Matches path only (`^/download/(.*)$`) |
| Capture syntax | `${1}`, `${2}` | `$1`, `$2` |
| Config format | YAML (dynamic.yaml) | nginx.conf |
| Client behavior | Must follow redirect (`curl -L`) | Transparent, no redirect |
| Query string | Proper `?` delimiter via redirect | Proper `?` delimiter via internal rewrite |
| Listen port | 8081 | 8081 |
| Listen port | HTTP on 443 allowed | HTTPs on 443 expected |


👉 ⚠️ ✅ ❌ ❓➡️


