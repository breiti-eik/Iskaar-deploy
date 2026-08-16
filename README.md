# Iskaar Deploy

Gemeinsames Deployment-Repository für das Iskaar-Projekt. Enthält alle Kubernetes-Manifeste und Docker-Compose-Konfigurationen für den Full-Stack (PostgreSQL, Spring Boot Backend, Nginx Frontend).

## Struktur

```
├── k8s/                             # Kubernetes Manifeste
│   ├── namespace.yaml               # Namespace "iskaar"
│   ├── postgres-secret.yaml         # DB-Credentials (Platzhalter)
│   ├── postgres-pvc.yaml            # PersistentVolumeClaim (1Gi)
│   ├── postgresql-deployment.yaml
│   ├── postgresql-service.yaml
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   ├── ingress.yaml                 # Nginx Ingress + WebSocket + TLS
│   ├── cluster-issuer.yaml          # cert-manager SelfSigned ClusterIssuer
│   └── monitoring/                  # Monitoring & Alerting Stack
│       ├── 00-namespace.yaml            # Namespace "monitoring"
│       ├── 01-prometheus-servicemonitor.yaml  # Scraping-Config für Backend
│       ├── 02-prometheus-rules.yaml     # Alert-Regeln (6 Alerts)
│       ├── 03-alertmanager-config.yaml  # Routing + Webhook-Receiver
│       ├── 04-alertmanager-deployment.yaml
│       ├── 05-grafana-datasource-config.yaml
│       ├── 06-grafana-dashboard-config.yaml
│       ├── 07-grafana-dashboard-json.yaml   # "Iskaar Overview" Dashboard
│       ├── 08-grafana-deployment.yaml
│       ├── 09-grafana-ingress.yaml
│       └── 10-prometheus-cr.yaml        # Prometheus Operator CR + RBAC
├── docker-compose.full-stack.yml    # Full-Stack für LAN/WLAN-Spiel
├── scripts/                         # Deploy- und Validierungsskripte
└── README.md
```

## Projekt-/Repo-Struktur (Workspace)

Alle Iskaar-Repos liegen als Geschwister-Verzeichnisse im selben Workspace:

```
Workspace/
├── iskaarBE/                    # Backend-Repository
│   └── iskaar-be/
│       └── iskaar/              # Maven Multi-Module Root
│           ├── iskaar-domain/       # Reine Spiellogik (keine Frameworks)
│           ├── iskaar-application/  # Use Cases, Orchestrierung
│           ├── iskaar-infrastructure/ # WebSocket, Persistence, Metriken
│           └── iskaar-bootstrap/    # Spring Boot Entry Point, REST, Config
├── iskaarFE/                    # Frontend-Repository
│   └── iskaar-frontend/
│       └── src/                 # React + Phaser 3 (TypeScript, Vite)
├── Iskaar-deploy/               # Deployment-Repository (dieses Repo)
│   ├── k8s/                     # Kubernetes-Manifeste (App + Monitoring)
│   ├── docker-compose.full-stack.yml
│   └── scripts/
└── docs/                        # Übergreifende Dokumentation, Roadmap
```

> **Wichtig:** Die `docker-compose.full-stack.yml` referenziert die Geschwister-Repos über relative Pfade (`../iskaarBE/iskaar-be`, `../iskaarFE/iskaar-frontend`). Die Verzeichnisstruktur darf nicht geändert werden, sonst schlägt der Build fehl.

---

## Docker Compose — LAN/WLAN-Spiel

Mit Docker Compose lässt sich das komplette Iskaar-Kartenspiel (Frontend + Backend + Datenbank) lokal starten und für alle Geräte im selben Netzwerk spielbar machen.

### Voraussetzungen

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installiert und gestartet
- Die App-Repos (`iskaarBE`, `iskaarFE`) liegen als Geschwister-Verzeichnisse neben diesem Repo

### Spiel starten

```bash
docker compose -f docker-compose.full-stack.yml up --build
```

Das startet:
- **PostgreSQL** — Datenbank (intern, kein externer Port)
- **Backend** — Spring Boot auf Port 8080
- **Frontend** — Nginx auf Port 3000

> **Tipp:** Mit `-d` im Hintergrund starten:
> ```bash
> docker compose -f docker-compose.full-stack.yml up --build -d
> ```

### Mitspieler im LAN/WLAN einladen

Andere Geräte im gleichen Netzwerk können über die lokale IP-Adresse des Host-Rechners beitreten:

```
http://<HOST-IP>:3000
```

#### IP-Adresse herausfinden

| Betriebssystem | Befehl |
|---|---|
| Windows | `ipconfig` → IPv4-Adresse unter "WLAN" oder "Ethernet" |
| macOS | `ipconfig getifaddr en0` |
| Linux | `hostname -I \| awk '{print $1}'` |

### Firewall konfigurieren

Ports **3000** (Frontend) und **8080** (Backend/WebSocket) müssen für eingehende Verbindungen freigegeben sein.

**Windows (PowerShell als Admin):**
```powershell
New-NetFirewallRule -DisplayName "Iskaar LAN" -Direction Inbound -Protocol TCP -LocalPort 3000,8080 -Action Allow -Profile Private
```

**Linux (ufw):**
```bash
sudo ufw allow 3000/tcp
sudo ufw allow 8080/tcp
```

### Spiel stoppen

```bash
# Stoppen (Daten bleiben erhalten)
docker compose -f docker-compose.full-stack.yml down

# Stoppen + Datenbank-Reset
docker compose -f docker-compose.full-stack.yml down -v
```

### Troubleshooting

| Problem | Lösung |
|---------|--------|
| Seite nicht erreichbar | Firewall-Regeln prüfen |
| „502 Bad Gateway" | Backend noch nicht gestartet — warten oder Logs prüfen |
| WebSocket schlägt fehl | Port 3000 muss offen sein |
| Keine Lobby-Verbindung | Alle Geräte im selben LAN/WLAN? |
| Build schlägt fehl | `docker compose build --no-cache` |

```bash
# Logs anzeigen
docker compose -f docker-compose.full-stack.yml logs -f

# Nur Backend-Logs
docker compose -f docker-compose.full-stack.yml logs backend
```

### Portübersicht

| Port | Exponiert | Zweck |
|------|-----------|-------|
| 3000 | ✅ | Spiel (Frontend + API-Proxy) |
| 8080 | ✅ | Direkter Backend-Zugriff, Swagger UI, Health Check |
| 5432 | ❌ | PostgreSQL — nur intern |

---

## Kubernetes Deployment

### Voraussetzungen

- Kubernetes Cluster (z.B. minikube, kind, oder Cloud-Provider)
- `kubectl` konfiguriert
- Nginx Ingress Controller installiert
- Container-Images gebaut und in einer Registry verfügbar

### Alle Manifeste anwenden

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/postgres-secret.yaml
kubectl apply -f k8s/postgres-pvc.yaml
kubectl apply -f k8s/postgresql-deployment.yaml
kubectl apply -f k8s/postgresql-service.yaml
kubectl apply -f k8s/backend-deployment.yaml
kubectl apply -f k8s/backend-service.yaml
kubectl apply -f k8s/frontend-deployment.yaml
kubectl apply -f k8s/frontend-service.yaml
kubectl apply -f k8s/ingress.yaml
```

### Status prüfen

```bash
kubectl -n iskaar get pods
kubectl -n iskaar get services
kubectl -n iskaar get ingress
```

### Konfiguration

#### Secrets

Die Datei `postgres-secret.yaml` enthält base64-codierte Platzhalter. Für echte Environments:

```bash
kubectl -n iskaar create secret generic postgres-credentials \
  --from-literal=POSTGRES_DB=iskaar \
  --from-literal=POSTGRES_USER=<user> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### Images

Die Deployment-Manifeste verwenden Platzhalter-Images (`iskaar-backend:latest`, `iskaar-frontend:latest`). Pro Environment anpassen oder via Kustomize/Helm parametrisieren.

#### Ingress Hostname

In `k8s/ingress.yaml` den Host `iskaar.example.com` durch den tatsächlichen Hostnamen ersetzen.

---

## TLS/HTTPS (Minikube mit Self-Signed Cert)

Für eine produktionsnahe lokale Entwicklung kann TLS/HTTPS mit cert-manager und einem selbstsignierten Zertifikat aktiviert werden.

### Voraussetzungen

| Tool | Mindestversion | Prüfung |
|------|---------------|---------|
| kubectl | v1.28+ | `kubectl version --client` |
| Minikube | v1.32+ | `minikube version` |
| Ingress-Addon | aktiviert | `minikube addons list \| grep ingress` |

### Setup

```bash
# 1. cert-manager installieren
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.yaml

# 2. Warten bis alle Pods ready (~2 Min)
kubectl get pods -n cert-manager --watch

# 3. ClusterIssuer anwenden
kubectl apply -f k8s/cluster-issuer.yaml

# 4. ClusterIssuer prüfen (READY=True)
kubectl get clusterissuer

# 5. Ingress mit TLS anwenden
kubectl apply -f k8s/ingress.yaml

# 6. Zertifikat prüfen (READY=True)
kubectl get certificate -n iskaar

# 7. Tunnel starten (separates Terminal)
minikube tunnel

# 8. HTTPS testen
curl -k https://iskaar.games
```

### Verifikation

| Prüfung | Kommando | Erwartung |
|---------|----------|-----------|
| cert-manager Pods | `kubectl get pods -n cert-manager` | 3× Running 1/1 |
| ClusterIssuer | `kubectl get clusterissuer` | Ready=True |
| Zertifikat | `kubectl get certificate -n iskaar` | Ready=True |
| TLS Secret | `kubectl get secret iskaar-games-tls -n iskaar` | Typ `kubernetes.io/tls` |
| HTTPS | `curl -k https://iskaar.games` | HTTP 200 |
| SSL-Redirect | `curl -I http://iskaar.games` | 308 → https:// |

### Hinweis: Selbstsigniertes Zertifikat

Da ein selbstsigniertes Zertifikat verwendet wird, zeigt der Browser eine Sicherheitswarnung an. Das ist erwartetes Verhalten für die lokale Entwicklung. Zertifikat im Browser manuell akzeptieren.

### Troubleshooting

| Problem | Lösung |
|---------|--------|
| cert-manager Pods starten nicht | `kubectl describe pod -n cert-manager` — Ressourcen prüfen |
| ClusterIssuer nicht Ready | cert-manager-Logs prüfen |
| Zertifikat nicht ausgestellt | `kubectl describe certificate -n iskaar` |
| HTTPS nicht erreichbar | `minikube tunnel` aktiv? hosts-Eintrag vorhanden? |

---

## Monitoring & Alerting Stack

Der Monitoring-Stack wird im separaten Kubernetes-Namespace `monitoring` deployed und überwacht das Iskaar-Backend.

### Komponenten

| Komponente | Funktion | Port |
|---|---|---|
| **Prometheus** | Metriken-Sammlung (Operator-basiert) | 9090 |
| **Grafana** | Dashboard-Visualisierung | 3000 |
| **Alertmanager** | Alert-Routing & Notifications | 9093 |

### Voraussetzungen

- Kubernetes Cluster mit [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator) installiert (für CRDs: Prometheus, ServiceMonitor, PrometheusRule)
- Nginx Ingress Controller (für Grafana-Zugriff)

### Monitoring-Stack deployen

```bash
# Namespace + alle Manifeste auf einmal
kubectl apply -f k8s/monitoring/
```

### Grafana-Zugriff (lokaler Cluster)

```bash
kubectl port-forward svc/grafana 3000:3000 -n monitoring
# → http://localhost:3000 (Login: admin / admin)
```

Das Dashboard "Iskaar Overview" wird automatisch provisioniert und enthält 10 Panels:
- **Game Metrics:** Active Games, Connected Players, WebSocket Connections
- **WebSocket:** Message Throughput, Deserialization Errors
- **JVM:** Heap Memory, Non-Heap Memory, GC Pause Duration
- **HTTP:** Response Time Percentiles, Request Rate by Status

### Alert-Regeln

| Alert | Severity | Trigger |
|---|---|---|
| IskaarHighErrorRate | critical | HTTP 5xx > 5% über 5 Min |
| IskaarWebSocketConnectionDrop | warning | Connections > 50% Drop in 2 Min |
| IskaarHighMemoryUsage | warning | Heap > 85% über 5 Min |
| IskaarDeserializationFailures | critical | > 3 Fehler in 5 Min |
| IskaarServiceDown | critical | Backend nicht erreichbar > 1 Min |
| IskaarScrapeFailure | warning | Kein Scrape > 2 Min |

### Webhook-URLs anpassen

Die Alertmanager-Konfiguration (`03-alertmanager-config.yaml`) enthält Platzhalter-URLs für Webhook-Receiver. Vor dem produktiven Einsatz anpassen:

```yaml
# In 03-alertmanager-config.yaml
url: 'http://webhook-receiver.monitoring.svc.cluster.local:5001/alerts'       # Default
url: 'http://critical-webhook-receiver.monitoring.svc.cluster.local:5001/alerts'  # Critical
```

---

## Zusammengehörige Repos

| Repo | Beschreibung |
|------|-------------|
| iskaarBE | Spring Boot Backend (Java 21) |
| iskaarFE | React Frontend (TypeScript, Vite, Phaser 3) |
| **Iskaar-deploy** | Deployment-Konfiguration (dieses Repo) |
