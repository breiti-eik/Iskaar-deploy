# GitHub Environments & CI/CD Setup

## Überblick

Das Iskaar-Projekt nutzt eine CI/CD-Pipeline über drei Git-Repos:

| Repo | Funktion | Workflow |
|------|----------|----------|
| `iskaar-be` | Backend CI (Build + Test + SonarQube) | `.github/workflows/ci.yml` |
| `Iskaar-fe` | Frontend CI (Build + Test + SonarQube) | `.github/workflows/ci.yml` |
| `Iskaar-deploy` | CD (Deploy auf K8s) | `.github/workflows/deploy.yml` |

## Aktueller Modus: Lokale Registry

Die Pipeline nutzt aktuell eine **lokale Minikube-Registry** (`localhost:5000`). Docker-Build und -Push erfolgen lokal über `deploy.sh` — nicht über GitHub Actions.

Die Docker-Steps in den CI-Workflows sind **vorbereitet aber deaktiviert** (via Repository-Variable `REGISTRY_ENABLED`).

## Lokaler Deploy-Workflow

```bash
# 1. Ins Deploy-Repo navigieren
cd Iskaar-deploy

# 2. Deploy ausführen (startet Minikube automatisch falls nötig)
./scripts/deploy.sh dev

# 3. Optional: Dry-Run (zeigt was passieren würde)
./scripts/deploy.sh dev --dry-run

# 4. Optional: Smoke-Tests überspringen
./scripts/deploy.sh dev --skip-smoke

# 5. Optional: Bestimmten Tag deployen
./scripts/deploy.sh dev --tag v1.0.0
```

Das Skript führt automatisch aus:
1. Minikube starten (falls nicht läuft)
2. Image-Tag bestimmen (Git-Tag + SHA)
3. Docker-Images bauen (Backend + Frontend)
4. Images in lokale Registry pushen
5. Helm-Deployment ausführen
6. Auf Rollout warten
7. Smoke-Tests ausführen
8. Bei Fehler: automatischer Rollback

## GitHub Environments (für Remote-Betrieb)

Wenn eine Remote-Registry eingerichtet wird, werden folgende GitHub Environments benötigt:

### Environment: `dev`

| Eigenschaft | Wert |
|-------------|------|
| Protection Rules | Keine |
| Deployment Branch | `develop` |
| Auto-Deploy | Ja (via repository_dispatch) |

### Environment: `stage`

| Eigenschaft | Wert |
|-------------|------|
| Protection Rules | Keine |
| Deployment Branch | Tags (`v*`) |
| Auto-Deploy | Ja (via repository_dispatch bei Tag-Push) |

### Environment: `prod`

| Eigenschaft | Wert |
|-------------|------|
| Protection Rules | Required Reviewers (mindestens 1) |
| Deployment Branch | Nur manuell (workflow_dispatch) |
| Auto-Deploy | Nein |

## Secrets-Konfiguration

### Deploy-Repo (`Iskaar-deploy`) — pro Environment

| Secret | Beschreibung | Beispiel |
|--------|--------------|----------|
| `KUBECONFIG` | Base64-encoded kubeconfig für den Ziel-Cluster | `cat ~/.kube/config \| base64` |
| `REGISTRY_URL` | Container-Registry URL | `ghcr.io/breiti-eik` |
| `REGISTRY_USERNAME` | Registry-Login Username | `breiti-eik` |
| `REGISTRY_PASSWORD` | Registry-Login Passwort/Token | GitHub PAT mit `write:packages` |

### Code-Repos (`iskaar-be`, `Iskaar-fe`) — Repository-Level

| Secret/Variable | Beschreibung | Beispiel |
|-----------------|--------------|----------|
| Variable: `REGISTRY_ENABLED` | Feature-Toggle für Docker-Build | `true` oder nicht gesetzt |
| Secret: `REGISTRY_URL` | Container-Registry URL | `ghcr.io/breiti-eik` |
| Secret: `REGISTRY_USERNAME` | Registry-Login Username | `breiti-eik` |
| Secret: `REGISTRY_PASSWORD` | Registry-Login Passwort/Token | GitHub PAT |
| Secret: `DEPLOY_REPO_TOKEN` | PAT mit `repo` Scope für repository_dispatch | GitHub PAT |

## Aktivierung der Remote-Registry

Folgende Schritte sind nötig, um von lokaler Registry auf Remote (z.B. ghcr.io) umzusteigen:

### Schritt 1: GitHub Environments erstellen

1. Im Deploy-Repo → Settings → Environments
2. Environments `dev`, `stage`, `prod` erstellen
3. Für `prod`: Required Reviewers hinzufügen

### Schritt 2: Secrets konfigurieren

1. **Deploy-Repo:** `KUBECONFIG`, `REGISTRY_URL`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` pro Environment
2. **Code-Repos:** `REGISTRY_URL`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD`, `DEPLOY_REPO_TOKEN`

### Schritt 3: Repository-Variable setzen

In **beiden Code-Repos** (iskaar-be, Iskaar-fe):
- Settings → Variables → Repository Variables
- `REGISTRY_ENABLED` = `true`

### Schritt 4: Helm-Values anpassen

`helm/iskaar/values-prod.yaml` — Registry-URL aktualisieren:
```yaml
image:
  registry: ghcr.io/breiti-eik  # statt registry.example.com
```

### Schritt 5: imagePullSecret ergänzen (für private Registry)

Falls die Registry privat ist, muss ein `imagePullSecret` im Cluster existieren:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=breiti-eik \
  --docker-password=<PAT> \
  -n iskaar
```

Und im Helm-Chart die Deployments erweitern:
```yaml
spec:
  imagePullSecrets:
    - name: ghcr-pull-secret
```

### Schritt 6: Verifizieren

1. Push auf `develop` → CI baut + pusht Image → repository_dispatch → CD deployt auf `dev`
2. Tag-Push `v1.0.0` → CI baut + pusht → CD deployt auf `stage`
3. Manuell: workflow_dispatch → CD deployt auf `prod` (nach Approval)

## Promotion-Pfad

```
develop-Push → CI → Docker Build/Push → auto-deploy auf dev
                                          ↓
Tag-Push (v*) → CI → Docker Build/Push → auto-deploy auf stage
                                          ↓
workflow_dispatch (manuell)            → deploy auf prod (Approval nötig)
```

## Rollback

Bei fehlgeschlagenem Deployment (Rollout-Timeout oder Smoke-Test-Failure) wird automatisch zurückgerollt:

- **Lokal:** `deploy.sh` führt `helm rollback` aus
- **Remote (CD-Workflow):** Der `Rollback on Failure` Step führt `helm rollback` aus

Manueller Rollback:
```bash
# Letzte erfolgreiche Revision anzeigen
helm history iskaar -n iskaar

# Auf bestimmte Revision zurückrollen
helm rollback iskaar <revision> -n iskaar
```
