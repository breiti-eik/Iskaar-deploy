# GitHub Environments & CI/CD Setup

## Überblick

Das Iskaar-Projekt nutzt eine CI/CD-Pipeline über drei Git-Repos:

| Repo | Funktion | Workflow |
|------|----------|----------|
| `iskaar-be` | Backend CI (Build + Test + SonarQube) | `.github/workflows/ci.yml` |
| `Iskaar-fe` | Frontend CI (Build + Test + SonarQube) | `.github/workflows/ci.yml` |
| `Iskaar-deploy` | CD (Deploy auf K8s) | `.github/workflows/deploy.yml` |

## Aktueller Modus: Zweigeteilter Readiness-/Minikube-Betrieb

Der CD-Workflow `deploy.yml` ist in zwei streng getrennte Modi aufgeteilt und orchestriert **ausschließlich** `scripts/deploy.sh` — er konfiguriert keine Remote-Kubeconfig und ruft weder `helm upgrade`/`kubectl rollout` noch `helm rollback` direkt auf.

| Modus | Runner | Verhalten |
|-------|--------|-----------|
| **Readiness (`deploy=false`, Standard)** | `ubuntu-latest` (GitHub-hosted) | Kein `KUBECONFIG`, keine Produktions-Credentials, keine Cluster-Mutation. Ruft nur `scripts/deploy.sh <env> --deploy false --monitoring <bool>`. |
| **Deploy (`deploy=true`)** | `[self-hosted, minikube]` | Nur auf dem lokalen Self-hosted-Minikube-Runner; verifiziert vorher den lokalen Kontext und ruft nur `scripts/deploy.sh dev --deploy true --monitoring <bool>`. |

Ein fehlender oder ungültiger `deploy`-/`monitoring`-Wert (auch aus `repository_dispatch`) wird sicher auf `false` normalisiert. `deploy=true` ist nur mit `environment=dev` zulässig; jedes andere Environment fällt auf Readiness zurück. Damit ist ein **Remote-Produktionsdeployment kein aktueller Standard** — der Standard ist Readiness ohne Clusterzugriff, und ein echtes Deployment ist auf das lokale Minikube-`dev`-Ziel begrenzt.

Docker-Build und -Push erfolgen lokal über `deploy.sh` (lokale Registry `localhost:5000` oder Minikube-Docker-Daemon). Die Docker-Steps in den CI-Workflows der Code-Repos sind **vorbereitet aber deaktiviert** (via Repository-Variable `REGISTRY_ENABLED`).

## Lokaler Deploy-Workflow

```bash
# 1. Ins Deploy-Repo navigieren
cd Iskaar-deploy

# 2. Readiness (sicherer Standard, keine Cluster-Mutation)
./scripts/deploy.sh dev

# 3. Lokaler Minikube-Deploy (nur dev; Local_Secret vorher bereitstellen)
./scripts/deploy.sh dev --deploy true

# 4. Optional: Monitoring-Stack mit ausrollen
./scripts/deploy.sh dev --deploy true --monitoring true

# 5. Optional: Smoke-Tests überspringen
./scripts/deploy.sh dev --deploy true --skip-smoke

# 6. Optional: Bestimmten Tag verwenden
./scripts/deploy.sh dev --deploy true --tag v1.0.0
```

Details zu beiden Modi, Voraussetzungen, Ausgabe, Local_Secret und Sicherheitsgrenzen: [`DEPLOYMENT-READINESS.md`](DEPLOYMENT-READINESS.md).

> **Hinweis:** Der frühere unbedingte Ablauf „Minikube starten → Images in Registry pushen → Helm-Deployment → automatischer Rollback bei jedem Aufruf" ist überholt. Im Readiness-Modus (Standard) findet **keine** dieser Mutationen statt; im Minikube-Modus übernimmt `deploy.sh` Setup, phasenweises Helm-Rollout, Smoke-Tests und Rollback (siehe Abschnitt „Rollback").

## GitHub Environments (optionaler Zukunftsschritt: Remote-Betrieb)

> **Optional / nicht aktueller Standard:** Die folgenden GitHub Environments und Remote-Credentials sind **kein** Bestandteil des aktuellen zweigeteilten Betriebs. Sie beschreiben einen klar gekennzeichneten Zukunftsschritt, falls eine Remote-Registry und ein Remote-Cluster eingerichtet werden. Der aktuelle Workflow benötigt für Readiness keinerlei `KUBECONFIG`- oder Registry-Secrets und für `deploy=true` nur den lokalen Minikube-Kontext des Self-hosted-Runners.

Wenn künftig eine Remote-Registry eingerichtet wird, werden folgende GitHub Environments benötigt:

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

## Secrets-Konfiguration (optional, nur für Remote-Betrieb)

> **Optional / nicht aktueller Standard:** Weder ein base64-`KUBECONFIG`-Secret noch Remote-Registry-Credentials werden vom aktuellen Workflow benötigt. Readiness läuft ohne jedes Cluster-Secret; `deploy=true` nutzt ausschließlich den lokalen Minikube-Kontext des Self-hosted-Runners. Die folgende Tabelle gilt nur, falls der optionale Remote-Betrieb aufgesetzt wird. Alle Beispielwerte sind Platzhalter.

### Deploy-Repo (`Iskaar-deploy`) — pro Environment

| Secret | Beschreibung | Beispiel (Platzhalter) |
|--------|--------------|----------|
| `KUBECONFIG` | Base64-encoded kubeconfig für den Ziel-Cluster | `cat ~/.kube/config \| base64` |
| `REGISTRY_URL` | Container-Registry URL | `<registry-host>/<org>` |
| `REGISTRY_USERNAME` | Registry-Login Username | `<registry-user>` |
| `REGISTRY_PASSWORD` | Registry-Login Passwort/Token | `<PAT mit write:packages>` |

### Code-Repos (`iskaar-be`, `Iskaar-fe`) — Repository-Level

| Secret/Variable | Beschreibung | Beispiel |
|-----------------|--------------|----------|
| Variable: `REGISTRY_ENABLED` | Feature-Toggle für Docker-Build | `true` oder nicht gesetzt |
| Secret: `REGISTRY_URL` | Container-Registry URL | `<registry-host>/<org>` |
| Secret: `REGISTRY_USERNAME` | Registry-Login Username | `<registry-user>` |
| Secret: `REGISTRY_PASSWORD` | Registry-Login Passwort/Token | `<PAT mit write:packages>` |
| Secret: `DEPLOY_REPO_TOKEN` | PAT mit `repo` Scope für repository_dispatch | `<PAT mit repo scope>` |

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
  registry: <registry-host>/<org>  # z. B. ghcr.io/<org>, statt registry.example.com
```

### Schritt 5: imagePullSecret ergänzen (für private Registry)

Falls die Registry privat ist, muss ein `imagePullSecret` im Cluster existieren:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=<registry-host> \
  --docker-username=<registry-user> \
  --docker-password=<PAT mit read:packages> \
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

## Promotion-Pfad (optionaler Remote-Betrieb)

> **Optional / nicht aktueller Standard:** Der folgende Remote-Promotion-Pfad (auto-deploy auf `dev`/`stage`/`prod`) gehört zum optionalen Zukunftsschritt und ist im aktuellen zweigeteilten Betrieb **nicht** aktiv. Aktuell führt `deploy=true` ausschließlich ein lokales Minikube-`dev`-Deployment aus; `stage`/`prod` sind nur Readiness-Validierungen.

```
develop-Push → CI → Docker Build/Push → auto-deploy auf dev
                                          ↓
Tag-Push (v*) → CI → Docker Build/Push → auto-deploy auf stage
                                          ↓
workflow_dispatch (manuell)            → deploy auf prod (Approval nötig)
```

## Rollback

Rollback ist Aufgabe von `scripts/deploy.sh` — **nicht** des Workflows. Der CD-Workflow ruft keinen direkten `helm rollback` mehr auf; er delegiert die gesamte Cluster-Mutation und deren Fehlerbehandlung an das Skript.

`deploy.sh` besitzt eine Revisionserkennung und rollt im Minikube-Modus (`deploy=true`) nur die Release `iskaar` im geprüften Namespace auf die vorherige Revision zurück, wenn ein Rollout-, Zertifikats-, Zugangs- oder Smoke-Schritt fehlschlägt. Der Rollback wird mit `helm rollback --wait` verifiziert; PostgreSQL-PVC und Local_Secret bleiben erhalten (keine destruktive Bereinigung). Existiert keine Vorrevision (Erstinstallation), wird der Teilzustand gemeldet und kein Rollback vorgetäuscht. Details und die genaue Ausgabe: [`DEPLOYMENT-READINESS.md`](DEPLOYMENT-READINESS.md) (Abschnitt „Fehler- und Rollback-Ausgaben").

Manueller Rollback (nur lokal, gegen den geprüften Minikube-Kontext):
```bash
# Letzte Revisionen anzeigen
helm history iskaar -n iskaar

# Auf bestimmte Revision zurückrollen
helm rollback iskaar <revision> -n iskaar
```
