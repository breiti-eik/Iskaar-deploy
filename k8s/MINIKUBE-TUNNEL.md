# Lokaler Cluster-Zugang (Windows + Docker-Driver)

Anleitung für den lokalen Zugriff auf den Kubernetes-Cluster über `http://iskaar.games:8080`.

> **Hinweis:** Bei Minikube mit Docker-Driver auf Windows ist Port 80 typischerweise durch HTTP.sys / Docker Desktop belegt. Deshalb verwenden wir `kubectl port-forward` auf Port 8080 als Standard-Zugang.

## Voraussetzungen

- [Minikube](https://minikube.sigs.k8s.io/) installiert und Cluster gestartet (`minikube start`)
- nginx Ingress Controller aktiviert:
  ```powershell
  minikube addons enable ingress
  ```
- Ingress Controller Service als LoadBalancer konfiguriert:
  ```powershell
  kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=merge -p '{\"spec\":{\"type\":\"LoadBalancer\"}}'
  ```
- Alle Kubernetes-Ressourcen deployed (Namespace, Services, Deployments, Ingress):
  ```powershell
  kubectl apply -f k8s/namespace.yaml
  kubectl apply -f k8s/ -n iskaar
  ```

## Schritt-für-Schritt-Anleitung

### 1. hosts-Eintrag prüfen/anlegen

Die Windows-hosts-Datei muss den Eintrag `127.0.0.1 iskaar.games` enthalten.

**Datei:** `C:\Windows\System32\drivers\etc\hosts`

1. PowerShell **als Administrator** öffnen (Rechtsklick → "Als Administrator ausführen")
2. Prüfen ob der Eintrag bereits existiert:
   ```powershell
   Get-Content C:\Windows\System32\drivers\etc\hosts | Select-String "iskaar.games"
   ```
3. Falls kein Eintrag vorhanden, hinzufügen:
   ```powershell
   Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1 iskaar.games"
   ```
4. **Wichtig:** Falls ein Eintrag mit `192.168.49.2 iskaar.games` existiert, diesen entfernen — er verhindert die korrekte Auflösung auf `127.0.0.1`.
5. Eintrag verifizieren:
   ```powershell
   ping iskaar.games
   ```
   Erwartete Ausgabe: `Pinging iskaar.games [127.0.0.1]...`

> **Hinweis:** Das Bearbeiten der hosts-Datei erfordert Administrator-Rechte.

### 2. Port-Forward starten

In einem beliebigen Terminal (keine Admin-Rechte nötig):

```powershell
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 --address 127.0.0.1
```

Der Befehl bleibt im Vordergrund aktiv. Das Terminal muss geöffnet bleiben.

> **Warum Port 8080?** Port 80 ist auf Windows mit Docker Desktop typischerweise durch HTTP.sys (PID 4) belegt und lässt sich auch mit Admin-Rechten nicht binden. Port 8080 funktioniert zuverlässig ohne Einschränkungen.

### 3. Funktionstest

In einem separaten Terminal:

```powershell
# Frontend erreichbar?
Invoke-WebRequest -Uri http://iskaar.games:8080/ -UseBasicParsing | Select-Object StatusCode
# Erwartung: 200

# Backend Health-Check:
Invoke-WebRequest -Uri http://iskaar.games:8080/actuator/health -UseBasicParsing | Select-Object Content
# Erwartung: {"status":"UP"}

# API-Endpunkt:
Invoke-WebRequest -Uri http://iskaar.games:8080/games -UseBasicParsing | Select-Object StatusCode
# Erwartung: 200

# Swagger:
Invoke-WebRequest -Uri http://iskaar.games:8080/swagger-ui/index.html -UseBasicParsing | Select-Object StatusCode
# Erwartung: 200
```

Im Browser öffnen: **http://iskaar.games:8080/**

Wenn alle Endpunkte antworten, ist das Routing korrekt konfiguriert.

## Alternative: Port 80 (falls frei)

Falls Port 80 auf deinem System nicht belegt ist, kannst du stattdessen direkt auf Port 80 forwarden (Admin-Terminal erforderlich):

```powershell
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 80:80 --address 127.0.0.1
```

Dann erreichst du alles ohne Port-Angabe: `http://iskaar.games/`

## Routing-Übersicht

| Pfad | Ziel-Service | Port |
|------|-------------|------|
| `/games` | iskaar-backend | 8080 |
| `/ws` | iskaar-backend | 8080 |
| `/actuator` | iskaar-backend | 8080 |
| `/swagger-ui` | iskaar-backend | 8080 |
| `/v3/api-docs` | iskaar-backend | 8080 |
| `/` (alles andere) | iskaar-frontend | 80 |

## Troubleshooting

### Port-Forward bricht ab / Connection refused

**Symptom:** `http://iskaar.games:8080` gibt `Connection refused` zurück.

**Prüfschritte:**
1. Ist der Port-Forward noch aktiv? → Terminal prüfen, ggf. neu starten:
   ```powershell
   kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 --address 127.0.0.1
   ```
2. Läuft Minikube?
   ```powershell
   minikube status
   ```
   Falls gestoppt: `minikube start` und Port-Forward erneut starten

### hosts-Eintrag fehlt oder falsch

**Symptom:** Browser zeigt `Could not resolve host: iskaar.games`

**Lösung:**
1. hosts-Datei prüfen:
   ```powershell
   Get-Content C:\Windows\System32\drivers\etc\hosts | Select-String "iskaar.games"
   ```
2. Es darf **nur** `127.0.0.1 iskaar.games` vorhanden sein — Einträge mit `192.168.49.2` entfernen!
3. DNS-Cache leeren:
   ```powershell
   ipconfig /flushdns
   ```

### Port 80 belegt (HTTP.sys / Docker Desktop)

**Symptom:** `kubectl port-forward ... 80:80` schlägt fehl mit `access permissions` Fehler.

**Ursache:** Windows reserviert Port 80 über HTTP.sys (PID 4). Das ist Standard bei Docker Desktop / Hyper-V.

**Lösung:** Port 8080 verwenden (Standard in dieser Anleitung). Alternativ:
```powershell
# Prüfen was Port 80 belegt:
netstat -ano | findstr ":80 "
# PID 4 = HTTP.sys → nicht ohne Weiteres zu stoppen
```

### Ingress Controller nicht installiert

**Symptom:** Port-Forward aktiv, aber alle Anfragen geben `404`.

**Lösung:**
```powershell
# Prüfen ob Ingress-Addon aktiviert ist:
minikube addons list | Select-String "ingress"

# Falls nicht aktiviert:
minikube addons enable ingress

# Warten bis der Ingress Controller bereit ist:
kubectl get pods -n ingress-nginx
# Alle Pods müssen Status "Running" haben
```

### Mehrere hosts-Einträge für iskaar.games

**Symptom:** Browser-Timeout trotz korrekt laufendem Port-Forward.

**Ursache:** Ein Eintrag `192.168.49.2 iskaar.games` in der hosts-Datei wird bevorzugt aufgelöst — diese IP ist bei Docker-Driver nicht vom Host erreichbar.

**Lösung (Admin-PowerShell):**
```powershell
# Alle iskaar.games-Einträge anzeigen:
Get-Content C:\Windows\System32\drivers\etc\hosts | Select-String "iskaar.games"

# Alte Einträge mit 192.168.49.2 entfernen — nur 127.0.0.1 behalten
```

## Port-Forward beenden

Den Port-Forward beenden:
1. Im Terminal `Ctrl+C` drücken
2. Oder das Terminal schließen

Der hosts-Eintrag bleibt bestehen und muss nicht entfernt werden.
