# Deployment-Readiness und lokaler Minikube-Modus

Diese Anleitung beschreibt den Modusvertrag von `scripts/deploy.sh` und dem
PowerShell-/WSL-Wrapper `scripts/deploy.ps1`. Zwei Modi werden über das Flag
`--deploy` gesteuert:

- **Readiness-Modus (`deploy=false`, Standard):** Baut, testet und validiert
  alles, was für ein Deployment nötig ist, **ohne** eine einzige
  Cluster-Ressource anzuwenden.
- **Minikube-Modus (`deploy=true`):** Bereitet ausschließlich das lokale
  Minikube-Ziel vor und rollt den Stack in fester Reihenfolge aus. Nur mit
  Environment `dev` erlaubt.

> **Sicherheitsgrenzen (verbindlich):**
> - `deploy=false` wendet **keine** Namespaces, Pods, Services, PVCs, Secrets,
>   Ingresses oder Helm-Releases an und pusht keine Images.
> - `deploy=true` ist auf das **lokale** Minikube-Ziel (`dev`) beschränkt. Es
>   werden keine Remote-Kubeconfig, kein fremder Kontext und keine
>   Remote-Registry akzeptiert.

Bezüge zu den abgeschlossenen Specs, ohne deren Ressourcen zu duplizieren:
Kubernetes-Manifeste unter [`../k8s/`](../k8s/), TLS-/Tunnel-Details in
[`../k8s/MINIKUBE-TUNNEL.md`](../k8s/MINIKUBE-TUNNEL.md), Monitoring unter
[`../k8s/monitoring/`](../k8s/monitoring/), GitHub-Environments in
[`GITHUB_ENVIRONMENTS.md`](GITHUB_ENVIRONMENTS.md).

---

## 1. Voraussetzungen

### Beide Modi
- Die drei Repos liegen als Geschwister-Verzeichnisse im Workspace
  (`../iskaarBE`, `../iskaarFE/iskaar-frontend`). Overridebar über
  `BACKEND_CONTEXT` und `FRONTEND_CONTEXT`.
- Werkzeuge auf dem `PATH`: `git`, `docker`, `helm`, `kubectl`, `minikube`,
  `curl` (unter Windows/WSL werden auch die `.exe`-Varianten erkannt).
- Ausführung aus dem Repo-Root `Iskaar-deploy/` heraus (die Skripte lösen ihre
  Pfade relativ zum Skriptverzeichnis auf).

### Zusätzlich für `deploy=true` (Minikube-Modus)
- Ein lokales Minikube-Profil (Standard `minikube`) und ein Kubernetes-Kontext,
  der auf einen lokalen API-Server (`localhost`, `127.0.0.0/8`, `::1` oder die
  Minikube-IP) zeigt. Ein fremder Kontext führt zum Abbruch **vor** jeder
  Mutation.
- Lokale PostgreSQL-Credentials als **Local_Secret** (siehe Abschnitt 5). Ohne
  vollständiges Secret bricht der Lauf vor Namespace-/Secret-/Helm-Mutation ab.
- Nur eine **lokale** Registry oder der Minikube-Docker-Daemon
  (`REGISTRY` leer). Remote-Registries werden abgelehnt.

### Windows: Bash-Runner für `deploy.ps1`
`deploy.ps1` sucht `bash.exe` (z. B. Git for Windows) oder `wsl.exe` auf dem
`PATH`. Fehlt beides, wird mit einer Diagnose und Exit-Code `127` abgebrochen.

---

## 2. Kopierbare Aufrufe

Alle Aufrufe verwenden die real existierenden Skriptnamen und Optionen von
`scripts/deploy.sh` bzw. `scripts/deploy.ps1`.

### 2.1 Readiness-Modus (`deploy=false`, Standard, keine Cluster-Mutation)

Bash:

```bash
# Standard ist deploy=false; die Option kann weggelassen werden
./scripts/deploy.sh dev
# oder explizit
./scripts/deploy.sh dev --deploy false
# Readiness auch für stage/prod erlaubt (nur Validierung, keine Mutation)
./scripts/deploy.sh stage --deploy false
./scripts/deploy.sh prod --deploy false
```

WSL (aus PowerShell/CMD heraus):

```powershell
wsl.exe bash ./scripts/deploy.sh dev --deploy false
# alternativ mit Git-for-Windows-Bash:
bash.exe ./scripts/deploy.sh dev --deploy false
```

PowerShell (Wrapper):

```powershell
# Standard: -Deploy false
.\scripts\deploy.ps1 -Environment dev
# oder explizit
.\scripts\deploy.ps1 -Environment dev -Deploy false
```

### 2.2 Minikube-Modus (`deploy=true`, nur `dev`)

Bash:

```bash
# Local_Secret vorher bereitstellen (siehe Abschnitt 5)
./scripts/deploy.sh dev --deploy true
```

WSL:

```powershell
wsl.exe bash ./scripts/deploy.sh dev --deploy true
```

PowerShell (Wrapper):

```powershell
.\scripts\deploy.ps1 -Environment dev -Deploy true
```

> `deploy=true` mit einem anderen Environment als `dev` bricht mit Exit-Code
> ungleich null ab und erklärt, dass der Minikube-Modus nur das lokale
> `dev`-Ziel verwendet.

### 2.3 Monitoring aktivieren (`--monitoring true`)

Bash:

```bash
./scripts/deploy.sh dev --deploy true --monitoring true
```

WSL:

```powershell
wsl.exe bash ./scripts/deploy.sh dev --deploy true --monitoring true
```

PowerShell:

```powershell
.\scripts\deploy.ps1 -Environment dev -Deploy true -Monitoring true
```

`--monitoring` akzeptiert exakt `true` oder `false` (Standard `false`). Der
Monitoring_Stack unter `k8s/monitoring/` wird nur nach erfolgreichem Core_Stack
und nur gegen vorhandene Prometheus-Operator-CRDs angewendet.

### 2.4 Image-Tag überschreiben (`--tag`)

Bash:

```bash
# Readiness rendert Helm-Templates mit dem Tag; deploy=true nutzt den Tag im Rollout
./scripts/deploy.sh dev --deploy false --tag v1.0.0
./scripts/deploy.sh dev --deploy true  --tag v1.0.0
```

WSL:

```powershell
wsl.exe bash ./scripts/deploy.sh dev --deploy true --tag v1.0.0
```

PowerShell:

```powershell
.\scripts\deploy.ps1 -Environment dev -Deploy true -Tag v1.0.0
```

Ohne `--tag` wird der Tag aus Git ermittelt (Semver-Tag plus Kurz-SHA, sonst
reiner Kurz-SHA). Beginnt ein Override mit `v`, wird das Semver-Format
`vMAJOR.MINOR.PATCH` erzwungen.

### 2.5 Timeouts überschreiben

Über Umgebungsvariablen (Bash/WSL). Die Defaults stehen in Klammern:

```bash
BUILD_TIMEOUT=600 \
MINIKUBE_START_TIMEOUT=240 \
ROLLOUT_TIMEOUT=180 \
CERTIFICATE_TIMEOUT=180 \
CLUSTER_ISSUER_TIMEOUT=90 \
ACCESS_TIMEOUT=90 \
INGRESS_TIMEOUT=180 \
SMOKE_TIMEOUT=90 \
./scripts/deploy.sh dev --deploy true
```

PowerShell (typisierte Parameter des Wrappers):

```powershell
.\scripts\deploy.ps1 -Environment dev -Deploy true `
    -BuildTimeout 600 `
    -MinikubeStartTimeout 240 `
    -RolloutTimeout 180 `
    -CertificateTimeout 180 `
    -AccessTimeout 90 `
    -SmokeTimeout 90
```

> Der Wrapper reicht die Parameter `-BuildTimeout`, `-MinikubeStartTimeout`,
> `-RolloutTimeout`, `-CertificateTimeout`, `-AccessTimeout` und
> `-SmokeTimeout` als gleichnamige Umgebungsvariablen (`BUILD_TIMEOUT` usw.) an
> `deploy.sh` durch. `INGRESS_TIMEOUT`, `CLUSTER_ISSUER_TIMEOUT` und
> `CERT_MANAGER_VERSION` werden im Wrapper nicht als Parameter angeboten; sie
> lassen sich vor dem Aufruf als Prozess-Umgebungsvariablen setzen. Alle
> Timeouts müssen positive Ganzzahlen sein.

Standard-Timeouts: `BUILD_TIMEOUT` 300, `MINIKUBE_START_TIMEOUT` 180,
`ROLLOUT_TIMEOUT` 120, `CERTIFICATE_TIMEOUT` 120, `CLUSTER_ISSUER_TIMEOUT` 60,
`ACCESS_TIMEOUT` 60, `INGRESS_TIMEOUT` 120, `SMOKE_TIMEOUT` 60 (Sekunden).

### 2.6 Smoke-Tests überspringen (`--skip-smoke`)

Bash:

```bash
./scripts/deploy.sh dev --deploy true --skip-smoke
```

WSL:

```powershell
wsl.exe bash ./scripts/deploy.sh dev --deploy true --skip-smoke
```

PowerShell:

```powershell
.\scripts\deploy.ps1 -Environment dev -Deploy true -SkipSmoke
```

Bei `--skip-smoke` wird zusätzlich der Zugriffsprozess (Tunnel/Port-Forward)
nicht dauerhaft für die Smoke-Phase offen gehalten; eine Rollback-Verifizierung
beschränkt sich dann auf `helm rollback --wait`.

---

## 3. Ausgabe und Konsolenkontrakt

### 3.1 Modus-Kopf (jeder Lauf)

`deploy.sh` gibt vor jeder Vorprüfung einen stabilen Kopf aus:

Readiness (`deploy=false`):

```
=== Iskaar Deploy ===
Mode: READINESS (deploy=false)
Environment: dev
Minikube profile: minikube
Minikube target: not contacted
Monitoring: false
Cluster mutations: disabled
Dry-run: false
```

Minikube (`deploy=true`):

```
Mode: DEPLOY (deploy=true)
Environment: dev
Minikube profile: minikube
Target context: minikube
Monitoring: false
Cluster mutations: enabled for local Minikube only
```

Bedeutung der Felder:
- **`Mode`** — genau `READINESS (deploy=false)` oder `DEPLOY (deploy=true)`.
- **`Minikube target` / `Target context`** — im Readiness-Modus immer
  `not contacted`; im Minikube-Modus der geprüfte lokale Kontext (Profilname).
- **`Cluster mutations`** — `disabled` (Readiness) oder
  `enabled for local Minikube only` (Minikube-Modus).

### 3.2 Readiness-Abschluss

Nach erfolgreicher Validierung endet der Lauf mit Exit-Code 0 und bestätigt
ausdrücklich, dass nichts mutiert wurde:

```
Readiness validation completed successfully.
Cluster mutations: none (readiness mode)
```

Schlägt ein Readiness-Schritt fehl, wird der betroffene Bereich benannt und der
Lauf mit Exit-Code ungleich null beendet, bevor irgendeine Mutation startet:

```
Error: Readiness phase failed (validator exit code N).
No Minikube, registry, Helm, or cluster mutation was started.
```

### 3.3 Phasenstatus (Minikube-Modus)

Jede Phase wird über `run_deploy_phase` gekapselt und meldet
`<Name> phase started.` sowie `<Name> phase completed.`. Die Gates innerhalb
einer Phase melden `Gate: <Name>.` und `Gate passed: <Name>.`. Die Reihenfolge
der Phasen ist fest (verkürzter Auszug einer erfolgreichen Ausführung):

```
[DEPLOY] Namespace phase started.
[DEPLOY] Namespace phase: iskaar.
[DEPLOY] Namespace phase completed.
[DEPLOY] Namespace Helm phase started.
[DEPLOY] Namespace Helm phase completed.
[DEPLOY] Local Secret phase started.
[DEPLOY] Local secret phase: postgres-credentials in iskaar.
[DEPLOY] Local secret phase completed.
[DEPLOY] Local Secret phase completed.
[DEPLOY] PostgreSQL phase started.
[DEPLOY] PostgreSQL phase completed.
[DEPLOY] PostgreSQL readiness phase started.
[DEPLOY] Gate: PostgreSQL Service creation.
[DEPLOY] Gate passed: PostgreSQL Service creation.
[DEPLOY] Gate: PostgreSQL rollout/readiness.
[DEPLOY] Gate passed: PostgreSQL rollout/readiness.
[DEPLOY] Gate: PostgreSQL Ready pod.
[DEPLOY] Gate passed: PostgreSQL Ready pod.
[DEPLOY] PostgreSQL readiness phase completed.
[DEPLOY] Backend phase started.
[DEPLOY] Backend phase completed.
[DEPLOY] Backend readiness phase started.
[DEPLOY] Gate: Backend rollout/readiness.
[DEPLOY] Gate passed: Backend rollout/readiness.
[DEPLOY] Gate: Backend Available condition.
[DEPLOY] Gate passed: Backend Available condition.
[DEPLOY] Gate passed: Backend health (/actuator/health).
[DEPLOY] Backend readiness phase completed.
[DEPLOY] Frontend phase started.
[DEPLOY] Frontend phase completed.
[DEPLOY] Frontend readiness phase started.
[DEPLOY] Gate passed: Frontend rollout/readiness.
[DEPLOY] Gate passed: Frontend HTTP readiness (/).
[DEPLOY] Frontend readiness phase completed.
[DEPLOY] TLS/Ingress phase started.
[DEPLOY] TLS/Ingress phase completed.
[DEPLOY] TLS/Ingress readiness phase started.
[DEPLOY] Gate: TLS Certificate readiness.
[DEPLOY] Gate passed: TLS Certificate readiness.
[DEPLOY] Gate: TLS Secret creation.
[DEPLOY] Gate passed: TLS Secret creation.
[DEPLOY] Gate: TLS Secret data.
[DEPLOY] Gate passed: TLS Secret data.
[DEPLOY] Gate: Ingress resource.
[DEPLOY] Gate passed: Ingress resource.
[DEPLOY] TLS/Ingress readiness phase completed.
[DEPLOY] Monitoring phase started.
[DEPLOY] Monitoring phase skipped (monitoring=false).
[DEPLOY] Monitoring phase completed.
...
=== Deployment complete ===
```

Der Phasenname aus `run_deploy_phase` (z. B. `PostgreSQL readiness`) umschließt
die feineren Gate-Meldungen (`Gate: PostgreSQL Service creation.`), sodass ein
fehlgeschlagenes Gate eindeutig einer Phase zugeordnet werden kann.

### 3.4 Effektive URLs

Die Zugriffsphase des Setups gibt die tatsächlich erreichbaren URLs aus, die
danach für die Smoke-Tests verwendet werden:

```
Access mode selected: tunnel
Effective HTTP URL: http://iskaar.games
Effective HTTPS URL: https://iskaar.games
```

Im Port-Forward-Fall enthalten die URLs die lokalen Ports (Default HTTP `8080`,
HTTPS `8443`), z. B. `https://iskaar.games:8443`.

### 3.5 Fehler- und Rollback-Ausgaben

Bei einem Fehler nach bereits erfolgreicher Vorrevision rollt das Skript nur die
Release `iskaar` im geprüften Namespace auf die vorherige Revision zurück und
verifiziert den Rollback (Daten-PVC und Local_Secret bleiben erhalten):

```
=== ROLLBACK ===
Reason: Backend readiness phase
[DEPLOY] Rolling back release=iskaar to revision=<N> in namespace=iskaar.
[DEPLOY] Helm rollback completed with --wait.
[DEPLOY] Rollback smoke-test verification passed.
```

Existiert keine Vorrevision (Erstinstallation), wird der Teilzustand gemeldet,
**keine** destruktive Bereinigung ausgeführt und Diagnosebefehle genannt:

```
[DEPLOY] No previous Helm revision is available; the failed run may have left a partial release state.
[DEPLOY] No PVC, Local_Secret, Secret, or data-volume cleanup is performed automatically.
Diagnostics: helm history iskaar --namespace iskaar
Diagnostics: kubectl --context 'minikube' -n 'iskaar' get pods,services,pvc,secrets,ingress
```

Ein fehlgeschlagener Smoke-Test führt zu:

```
=== Deployment FAILED (smoke test or access gate) ===
```

---

## 4. Ablauf im Minikube-Modus (`deploy=true`)

Das Hilfsskript `scripts/minikube-setup.sh` und die Deploy-Phasen laufen in
dieser Reihenfolge:

1. **Zielprüfung (read-only):** Profilzustand, Kubernetes-Kontext und lokale
   API-Server-Adresse werden verifiziert. Fremde Kontexte/Registries führen zum
   Abbruch vor jeder Mutation.
2. **Minikube-Start:** Ein gestopptes Profil wird mit `MINIKUBE_DRIVER`
   (Default `docker`) gestartet; API-Bereitschaft innerhalb
   `MINIKUBE_START_TIMEOUT`.
3. **Ingress-Addon:** Das Minikube-Addon `ingress` wird aktiviert bzw. als
   aktiviert erkannt; auf den nginx-Ingress-Controller wird gewartet
   (`INGRESS_TIMEOUT`).
4. **cert-manager:** Die gepinnte Version (Default `v1.17.2`,
   `CERT_MANAGER_VERSION`) wird installiert oder verifiziert; CRDs, Controller,
   Webhook und CA-Injector müssen bereit sein (`CERTIFICATE_TIMEOUT`).
5. **ClusterIssuer:** `k8s/cluster-issuer.yaml` wird angewendet; der
   `selfsigned-cluster-issuer` muss `Ready=True` erreichen
   (`CLUSTER_ISSUER_TIMEOUT`).
6. **Zugriff (`minikube tunnel` / Port-Forward):** Je nach `ACCESS_MODE`
   (`auto`, `tunnel`, `port-forward`) wird ein funktionierender lokaler Zugriff
   hergestellt (`ACCESS_TIMEOUT`). `auto` versucht zuerst den Tunnel und fällt
   auf Port-Forward zurück. Details: [`../k8s/MINIKUBE-TUNNEL.md`](../k8s/MINIKUBE-TUNNEL.md).
7. **Lokale Images:** Backend- und Frontend-Images werden lokal gebaut —
   entweder im Minikube-Docker-Daemon (leeres `REGISTRY`, `imagePullPolicy=Never`)
   oder in einer geprüften lokalen Registry (`imagePullPolicy=IfNotPresent`).
   Kein Remote-Push. Vor dem Rollout wird geprüft, dass die Images lokal
   existieren.
8. **Secret-Quelle:** Das Local_Secret `postgres-credentials` wird erst nach der
   Namespace-Phase erzeugt (siehe Abschnitt 5).
9. **Core_Stack (phasenweises Helm-Rollout):** Namespace + Local_Secret →
   PostgreSQL (PVC/Service/Readiness) → Backend (Rollout + `/actuator/health`)
   → Frontend (Rollout + `/` auf Port 80) → TLS/Ingress (Zertifikat + Secret
   `iskaar-games-tls` + Ingress `iskaar-ingress`).
10. **Optionaler Monitoring_Stack:** Nur bei `--monitoring true` nach
    erfolgreichem Core_Stack, gegen vorhandene Prometheus-Operator-CRDs im
    Namespace `monitoring`.
11. **Smoke-Tests:** `scripts/smoke-test.sh` prüft mit den effektiven URLs
    Backend-Health (`/actuator/health`, 200), Frontend-Index (`/`, 200) und den
    WebSocket-Endpunkt (`/ws`, 400 ohne Upgrade). Danach wird der
    Tunnel-/Port-Forward-Prozess aufgeräumt.

Der Readiness-Modus (`deploy=false`) führt **keinen** der Schritte 2–11 aus.

---

## 5. Placeholder_Secret vs. Local_Secret

- **Placeholder_Secret:** `k8s/postgres-secret.yaml` enthält bewusst nicht
  produktive Platzhalter (`iskaar`, base64 `aXNrYWFy`). Diese werden vom
  Deploy-Skript ausdrücklich **als produktive Quelle abgelehnt**. Der
  Minikube-Modus rendert das Placeholder-Secret nicht
  (`postgresql.createPlaceholderSecret=false`) und referenziert nur
  `postgresql.existingSecret=postgres-credentials`.
- **Local_Secret:** Lokale Credentials werden im Minikube-Modus verlangt —
  entweder als drei Umgebungsvariablen **gemeinsam** oder als von Git ignorierte
  Datei unter `secrets/`.

Sicherer lokaler Bereitstellungsweg über eine git-ignorierte Datei (Standardpfad
`secrets/postgres.env`, overridebar via `POSTGRES_SECRET_FILE`). **Nur
Platzhalter — keine echten Werte:**

```bash
# secrets/postgres.env  (NICHT committen; liegt unter dem git-ignorierten secrets/)
POSTGRES_DB=<YOUR_LOCAL_DB_NAME>
POSTGRES_USER=<YOUR_LOCAL_DB_USER>
POSTGRES_PASSWORD=<YOUR_LOCAL_DB_PASSWORD>
```

Alternativ per Umgebung (alle drei zusammen, sonst Abbruch):

```bash
POSTGRES_DB=<YOUR_LOCAL_DB_NAME> \
POSTGRES_USER=<YOUR_LOCAL_DB_USER> \
POSTGRES_PASSWORD=<YOUR_LOCAL_DB_PASSWORD> \
./scripts/deploy.sh dev --deploy true
```

Regeln:
- Fehlt ein Wert oder wird ein bekannter Platzhalter (`iskaar` /`aXNrYWFy`)
  verwendet, bricht die Preflight vor Namespace-/Secret-/Helm-Mutation ab.
- Secret-Werte erscheinen **nie** in der Konsolenausgabe, in Helm-Argumenten,
  Image-Tags oder Workflow-Summaries. Das Secret wird über
  `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`
  im festen Namen `postgres-credentials` (Namespace `iskaar`) angelegt.

---

## 6. Sicherheitsgrenzen (Zusammenfassung)

- **`deploy=false`** wendet keine Namespaces, Pods, Services, PVCs, Secrets,
  Ingresses oder Helm-Releases an; kein `minikube start`, keine
  Addon-Aktivierung, kein Tunnel, kein `docker push`. Nur lokale Builds, Tests,
  Image-Builds, `helm lint`/`helm template` und Client-Dry-Run-Prüfungen.
- **`deploy=true`** ist auf das lokale Minikube-`dev`-Ziel beschränkt. Ein
  Kontext, der nicht dem geprüften Minikube-Target entspricht, eine
  Remote-Registry oder eine Kubeconfig, die auf ein nicht lokales Ziel zeigt,
  führen zum Abbruch vor der ersten Mutation.
- Der automatische Fehlerpfad rollt nur die Release `iskaar` zurück und löscht
  niemals Datenvolumes (PVC) oder das Local_Secret.
