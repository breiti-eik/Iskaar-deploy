# Iskaar Deploy

Gemeinsames Deployment-Repository für das Iskaar-Projekt. Enthält alle Kubernetes-Manifeste und Docker-Compose-Konfigurationen für den Full-Stack (PostgreSQL, Spring Boot Backend, Nginx Frontend).

## Struktur

```
├── k8s/                            # Kubernetes Manifeste
│   ├── namespace.yaml              # Namespace "iskaar"
│   ├── postgres-secret.yaml        # DB-Credentials (Platzhalter)
│   ├── postgres-pvc.yaml           # PersistentVolumeClaim (1Gi)
│   ├── postgresql-deployment.yaml
│   ├── postgresql-service.yaml
│   ├── backend-deployment.yaml
│   ├── backend-service.yaml
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml
│   └── ingress.yaml                # Nginx Ingress + WebSocket
├── docker-compose.full-stack.yml   # Full-Stack für LAN/WLAN-Spiel
├── scripts/                        # Deploy- und Validierungsskripte
└── README.md
```

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

## Zusammengehörige Repos

| Repo | Beschreibung |
|------|-------------|
| iskaarBE | Spring Boot Backend (Java 21) |
| iskaarFE | React Frontend (TypeScript, Vite, Phaser 3) |
| **Iskaar-deploy** | Deployment-Konfiguration (dieses Repo) |
