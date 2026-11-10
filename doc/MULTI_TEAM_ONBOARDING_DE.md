# Onboarding XYZ — Architekturanalyse

## Ausgangslage

ABC betreibt bereits eine Nomad/Consul-Cluster-Infrastruktur.
Pro Umgebung (Dev, Staging, Produktion) existiert ein eigenständiger Cluster.
Dieses Modell — getrennte Cluster je Umgebung wird für alle Teams/Projekte angenommen.

XYZ soll als neues Team auf diese Infrastruktur migriert werden.

## Besonderheit bei XYZ: Hochverfügbarkeit über zwei Regionen

XYZ betreibt jede Umgebung gleichzeitig in zwei AWS-Regionen (Bsp: ca-central-1 und
ca-west-1). Beide Regionen sind aktiv und können parallel Traffic bedienen (=6 Cluster).
Aktuell übernimmt ein Nginx die Verteilung des Traffics zwischen den Regionen.

## Untersuchte Ansätze

### Variante 1: ABC Cluster erweitern — wenig geeignet / testen

Technisch ist es möglich, die XYZ Server dem bestehenden ABC-Cluster hinzuzufügen ("datacenter" Label).
Da die XYZ-Server jedoch in anderen AWS-Regionen (in Übersee) stehen gibt zwei fundamentale Probleme:

- Die Kommunikationprotokolle zwischen den Nodes sind für stabile Low Latency Netze ausgelegt.
  Kommunikation über Regionsgrenzen hinweg (insbesondere Übersee) ist latenzbehaftet und instabil.
  Nodes können fälschlicherweise als ausgefallen gemeldet werden (False Positive).
- Fällt die ABC Region aus oder gibt es Störungen im Netzwerk zwischen ABC und XYZ, dann verlieren alle XYZ Regionen komplett die Steuerung.

### Variante 1b: ABC Cluster mit Servern in XYZ Regionen erweitern — nicht geeignet

Anstatt die Cluster-Server nur in einer Region zu betreiben, würden sie auf alle Regionen verteilt,
damit der Cluster einen Ausfall einer Region überstehen kann.

Dies ist jedoch noch problematischer:

- **Latenz:** Jede Scheduling-Entscheidung muss von einer Mehrheit der Server bestätigt werden.
- **Quorum-Verlust bei Netzwerkunterbrechung:** Keine Seite kann allein eine Mehrheit der Server erreichen. Das Cluster wird vollständig handlungsunfähig.
- **Ein Fehler betrifft alle Regionen gleichzeitig.** Da es nur einen gemeinsamen
  Cluster gibt, wirkt sich ein Problem auf der Steuerungsebene auf alle Regionen aus.

HashiCorp empfiehlt ausdrücklich, Cluster-Server immer in derselben Region zu betreiben.
Die Federation-Funktion (Variante 2) wurde genau deshalb entwickelt.

### Variante 2: Sechs eigenständige Cluster mit Nomad-Federation — möglich, evtl. überdimensioniert

Nomad bietet eine sogenannte Federation-Funktion, mit der separate Cluster koordiniert
zusammenarbeiten können. Deployments lassen sich damit atomar eine oder mehrere Regionen ausrollen.

Was Federation leistet:
- Koordiniertes Deployment in eine oder mehrere Regionen in einem Schritt (atomar)
- Alle HA-Regionen würden immer mit denselben Services laufen
- Automatischer Abbruch, wenn das Deployment in einer Region fehlschlägt

Was Federation nicht leistet:
- Welche Region (HA) aktiv ist oder ob eine Region ausfällt entscheidet der Load Balancer bzw. das DNS.

Federation bringt nur dann Mehrwert, wenn kein CI/CD-System die HA-Deployments koordiniert.
Ist ein CI/CD-System vorhanden dann übernimmt es diese Koordination bereits.
Falls nicht, kann es eine Lösung für die XYZ HA-Cluster sein.

### Variante 3: Eigenständige Cluster ohne Federation — empfohlen

Vollständig unabhängige Cluster, HA koordiniert über bestehende CI/CD-Pipelines.
Die Pipeline deployt parallel in beide HA-Regionen und schlägt fehl, wenn eine der
Regionen nicht erfolgreich deployt.

Vorteile:
- Jeder Cluster ist vollständig autark — keine gegenseitigen Abhängigkeiten
- Kein zusätzlicher Einrichtungs- und Wartungsaufwand für Federation
- Eine CI/CD liefert für HA dieselben Garantien wie Federation, ohne zusätzliche Infrastruktur

## Consul — Service Discovery und Netzwerk

Jeder Nomad-Cluster betreibt seinen eigenen Consul-Cluster. Das gilt für alle 
XYZ-Cluster genauso wie für die bestehenden ABC-Cluster. Jede Consul-Instanz ist
vollständig autark: eigene Zugriffsverwaltung (ACL), eigene Zertifikate, eigene
Service-Registry.

Eine Vernetzung der Consul-Instanzen untereinander (Cluster Peering) ist für XYZ nicht erforderlich,
wenn diese zwei Voraussetzungen erfüllt sind:

1. **Kein Traffic zwischen den HA-Regionen.** Services in ca-central-1 kommunizieren nicht
   direkt mit Services in ca-west-1. Jede Region bedient ihren Traffic eigenständig.

2. **Kein direkter Service-zu-Service-Traffic zwischen den Teams.** Falls XYZ- und
   ABC-Services miteinander kommunizieren müssen, läuft das über den Load Balancer
   (ALB) — nicht über interne East-West Service-Mesh-Connections.

## Hochverfügbarkeit: Wer steuert was?

Nomad selbst übernimmt keine Rolle bei der Hochverfügbarkeit im laufenden Betrieb.
Die HA-Logik liegt vollständig außerhalb von Nomad:

- **Load Balancer (ALB)**: prüft die Verfügbarkeit der Services in jeder Region
- **DNS mit Health-Check-Routing**: leitet Traffic automatisch um, wenn eine Region
  nicht mehr erreichbar ist
