# 📄 Papermark-Proxmox

Papermark ([papermark/papermark](https://github.com/papermark/papermark)) als **Proxmox-VE-Einzeiler** –
im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

Papermark ist die Open-Source-Alternative zu DocSend: Dokumente hochladen, per Link teilen,
Zugriffe nachverfolgen (wer hat wann wie lange gelesen), Datarooms, Wasserzeichen,
Passwortschutz, Ablaufdaten. Der Installer legt einen LXC-Container an und baut die App
darin – **vollständig lokal, ohne Cloud-Dienste**.

---

## Installation

Auf dem Proxmox-Host als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Papermark-Proxmox/main/install/papermark.sh)"
```

Der Container wird automatisch angelegt (nächste freie ID ab 200, Debian 13, 4 vCPU,
6 GB RAM, 20 GB Disk, `onboot=1`) und die komplette Installation läuft im Container
(PostgreSQL, Redis, Versity S3, Mailpit, Next.js-Build). Dauer: **15–25 Minuten**
(der Next.js-Build ist der Löwenanteil).

### Optionen

Optionen werden direkt hinter das schließende Anführungszeichen gehängt:

```bash
bash -c "$(wget -qLO - …/install/papermark.sh)" --id 210 --memory 8192 --ip 192.168.178.50/24 --gateway 192.168.178.1
```

| Option | Default | Bedeutung |
| --- | --- | --- |
| `--id ID` | nächste freie ab 200 | Container-ID |
| `--hostname NAME` | `papermark` | Hostname |
| `--cores N` | 4 | vCPUs |
| `--memory MB` | 6144 | RAM (Build braucht ~4 GB) |
| `--swap MB` | 2048 | Swap |
| `--rootfs GB` | 20 | Disk (node_modules + Build + Daten) |
| `--storage NAME` | `local-lvm` | Storage |
| `--bridge BR` | `vmbr0` | Netzwerk-Bridge |
| `--ip CIDR` | `dhcp` | Feste IP, empfohlen (s. u.) |
| `--gateway GW` | – | Gateway bei statischer IP |
| `--password PW` | generiert | root-Passwort im Container |
| `--sshkey PFAD/URL` | – | Public Key für `ssh root@<id>` |
| `--template NAME` | `debian-13-standard` | OS-Template |
| `--port PORT` | 3000 | Web-UI-Papermark |
| `--mailpit-port PORT` | 8025 | Web-Postfach (Login-Codes) |
| `--ref REF` | gepinnter Commit | Papermark-Quelle |
| `--update` | – | Container aktualisieren (Daten bleiben) |
| `--uninstall` | – | Container löschen (alles weg) |
| `--status` | – | Status anzeigen |
| `--debug` | – | `bash -x`-Trace |
| `--dry-run` | – | Befehle nur zeigen |

---

## Zugang

Nach der Installation:

| Zweck | URL |
| --- | --- |
| **Papermark Web-UI** | `http://<CT-IP>:3000` |
| **Postfach (Login-Codes)** | `http://<CT-IP>:8025` |
| S3-API (Versity Gateway) | `http://<CT-IP>:9000` |
| S3-WebUI (Versity) | nur lokal im CT: `http://127.0.0.1:9001` |

**Login:** „Continue with email" → E-Mail-Adresse eingeben → Papermark erzeugt einen
10-stelligen Code und schickt ihn per Mail. Die Mail landet im lokalen **Mailpit-Postfach**
(`http://<CT-IP>:8025`) – dort den Code ablesen und eingeben. Fertig.

> Google-/LinkedIn-/Passkey-Login erscheinen in der Oberfläche, funktionieren aber nur mit
> echten Cloud-Zugangsdaten (Hanko-Tenant, OAuth-Apps). Für den lokalen Betrieb ist der
> E-Mail-Weg gedacht.

---

## Was steckt drin?

Papermark offiziell ist eine Next.js-App mit PostgreSQL (Prisma) und S3-Blob-Speicher.
Ein Docker-Image oder eine Compose-Datei gibt es **nicht** – deshalb baut der Container
die App selbst und betreibt sie als systemd-Dienst. Damit alles lokal bleibt, bringt der
Container vier kleine Dienste mit:

```
┌──────────────────────── LXC (Debian 13, unprivilegiert) ────────────────────────┐
│                                                                                  │
│  papermark.service        Next.js (React)          :3000  → Web-UI              │
│    ├─ postgresql.service  Datenbank (Prisma)       :5432  (nur localhost)        │
│    ├─ redis-server        Sessions, Login-Codes, Rate-Limits :6379 (localhost)   │
│    ├─ papermark-upstash-bridge  HTTP-Adapter für @upstash/redis → Redis :8079    │
│    ├─ papermark-s3        S3-Speicher (Versity)      :9000  (Dokumente)            │
│    └─ papermark-mailpit   SMTP :1025 + Web-Postfach :8025 (Login-Codes)          │
│                                                                                  │
│  papermark-ip-sync.service  hält NEXTAUTH_URL beim IP-Wechsel synchron            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Warum die Upstash-Bridge?** Papermark nutzt `@upstash/redis` – einen HTTP-Client für die
Upstash-Cloud. Damit kein Cloud-Account nötig ist, übersetzt eine ~100-zeilige Bridge die
REST-Aufrufe 1:1 in Redis-Befehle. Sie ist in `install/papermark-inner.sh` enthalten und
gegen den echten Client getestet (SET/GET/INCR/ZADD/ZRANGE/Pipeline/GETDEL).

**Warum Mailpit?** Papermark verschickt Login-Codes per E-Mail (Resend-Cloud). Mailpit ist
ein lokaler SMTP-Server mit Web-Postfach – die Codes liegen damit im LAN griffbereit.

### Warum Versity Gateway statt MinIO?

Papermark braucht zwingend eine S3-API (Uploads, signierte Download-URLs, Multipart-Uploads
für große Dateien). MinIO – lange der Standard – liefert seit 2026 nur noch Builds, die ohne
Lizenz **jede S3-Operation verweigern** („running in offline mode. All S3 operations are
denied"); die alten Download-Pfade geben HTTP 410. Deshalb setzt der Installer den
**Versity Gateway** ein (Apache-2.0, ein Binary, Version v1.11.0, SHA256-geprüft): Er legt
die S3-API über einem lokalen Verzeichnis bereit, jedes Unterverzeichnis ist ein Bucket.

Lokal verifiziert: Bucket anlegen, `PutObject`, `HeadObject`, signierte GET-URL (HTTP 200),
Multipart-Upload (Create/UploadPart/Complete) – alles grün.

## Patches am Upstream-Code

Der Selfhosting-Betrieb braucht zwei kleine, dokumentierte Eingriffe (Script
`patches/apply-patches.mjs`, wird vom Inner-Skript automatisch angewendet):

1. **`lib/resend.ts`** – E-Mail-Versand über SMTP (`SMTP_URL`, Mailpit) statt Resend-Cloud.
   `nodemailer` ist bereits Dependency des Projekts.
2. **`lib/auth/auth-options.ts`** – der QStash-Publish beim ersten Login wird in einen
   Guard gepackt. Ohne QStash-Token würde sonst genau dieser Publish mit 500 abbrechen
   und der erste Login scheitern.
3. **`next.config.mjs`** – `typescript.ignoreBuildErrors` + `eslint.ignoreDuringBuilds`
   (Typfehler im OSS-Stand) **und** `/` → `/dashboard` ohne Host-Bedingung: bei Zugriff
   per `http://<IP>:3000` enthält der Host-Header den Port, die Bedingung würde nie greifen
   und `/` fiele auf 404 zurück.
4. **`middleware.ts`** – die eigene App-Domain (IP/Hostname) und private Adressen werden
   nicht mehr als *Custom-Domain* behandelt. Ohne das schreibt der Domain-Middleware alles
   nach `/view/domains/<host>/…` um → **404 auf jeder Seite**.
5. **`lib/middleware/app.ts`** – Redirects (Login, Welcome, `next`) zeigen auf die
   konfigurierte URL statt auf `localhost`, das Next.js im Middleware einsetzt, wenn die
   App über eine IP erreichbar ist. Sonst landet man beim Login auf dem eigenen Rechner.

Der Build-Hash im Inner-Skript schließt die Patch-Datei ein – eine Patch-Änderung löst
also immer einen Neubau aus, auch außerhalb von `--update`.

---

## Warum dieser Stand? (wichtig)

Paparkmarks öffentliches Repo enthält seit Ende April 2026 Verweise auf Dateien, die es
dort **nicht gibt** (`ee/features/request-lists/…`, `ee/features/branding/…`,
`lib/api/errors`, `lib/oauth/scopes` …). Der Quellcode kompiliert deshalb ab dem
05/2026 nicht mehr – auch nicht mit `npm install && npm run build`.

Der Installer pinnt deshalb den letzten Commit, der nachweislich baut:

```
bb93cfd03c7531f67cbb09a652e61c92de16d371   (2026-04-29, "feat: new file types")
```

Verifiziert: `npm ci` → `prisma generate` → `prisma migrate deploy` (134 Migrationen) →
`next build` → `next start` (HTTP 200 auf `/login`).

Der Web-UI-Stack ist **React (Next.js)** – kein Vite. Ein Vite-Neubau hieße, die komplette
App zu forken; wir fahren bewusst den Original-Code.

---

## Update / Deinstall / Status

```bash
# Update (Daten, DB und .env bleiben erhalten; baut neu)
bash -c "$(wget -qLO - …/install/papermark.sh)" --update

# Status
bash -c "$(wget -qLO - …/install/papermark.sh)" --status

# Deinstall (löscht Container inkl. aller Daten)
bash -c "$(wget -qLO - …/install/papermark.sh)" --uninstall
```

Ein Update ist außerdem nötig, wenn sich die **Container-IP ändert**: `NEXTAUTH_URL` und die
`NEXT_PUBLIC_*`-Werte werden von Next.js teils beim Build inlined. Der Boot-Dienst
`papermark-ip-sync` aktualisiert die Laufzeitwerte automatisch, für die Links muss einmalig
`--update` laufen. Deshalb: **feste IP vergeben oder DHCP-Reservierung einrichten**.

---

## Fehlersuche

Der Installer gibt bei Fehlern immer die komplette Kette aus (Exit-Code, Zeile, Befehl,
Log-Auszug, Container-Logs) und lässt den Container stehen:

```bash
pct enter 200                                   # im Container nachsehen
pct exec 200 -- journalctl -u papermark -f      # App-Logs live
pct exec 200 -- tail -n 50 /var/log/papermark-setup.log
pct exec 200 -- systemctl status papermark papermark-s3 papermark-mailpit papermark-upstash-bridge
bash -c "$(wget -qLO - …/install/papermark.sh)" --debug   # mit bash -x
```

Häufige Stolpersteine:

| Symptom | Ursache / Lösung |
| --- | --- |
| `Template … passt nicht zur Host-Architektur` | arm64-Template auf amd64-Host – Installer bricht bewusst ab |
| Build bricht mit `Killed` ab | RAM/Swap zu klein → `--memory 8192 --swap 4096` |
| Web-UI lädt, Login-Code kommt nicht | Mailpit prüfen: `http://<CT-IP>:8025` |
| Upload bricht ab | S3 prüfen: `pct exec <id> -- systemctl status papermark-s3` |
| Links zeigen nach IP-Wechsel auf alte IP | `--update` ausführen |

---

## Sicherheit

- Der Container läuft **unprivilegiert**, `nesting=1`, rootfs auf `local-lvm`.
- PostgreSQL und Redis lauschen nur auf `127.0.0.1`.
- S3-API und Mailpit-Web-UI sind im LAN erreichbar (nötig für Browser bzw. Login-Codes).
  **Das Mailpit-Postfach enthält die Login-Codes** – im LAN nur mit vertrauenswürdigen
  Geräten betreiben oder per Firewall auf den eigenen Rechner beschränken.
- Alle Secrets (DB-Passwort, S3-Zugang, NEXTAUTH_SECRET, Bridge-Token) werden zufällig
  erzeugt und mit `chmod 600` unter `/etc/papermark/` bzw. in der `.env` abgelegt.

---

## Tests

```bash
bash harness/run.sh          # 69 Assertions: Host-Skript gemockt + Patch-Fixtures
```

Der Harness bildet Proxmox per Mocks nach (`pct`, `pveam`, `pvesm`, `pveversion`) und prüft
u. a. Options-Parsing, `pct create`-Argumente, Architektur-Filter, Update-/Deinstall-Pfade
sowie die Patch-Anker. Zusätzlich wurden Build und Runtime lokal verifiziert:

- `npm ci` → `prisma generate` → `prisma migrate deploy` (134 Migrationen) → `next build`
- `next start` → HTTP 200 auf `/login` („Login | Papermark")
- Upstash-Bridge gegen echten Redis + `@upstash/redis`-Client (inkl. base64-Pipeline)

---

## Lizenz

Installer: MIT. Papermark selbst: AGPLv3 bzw. kommerzielle Lizenz für die Enterprise-Features
(siehe [Papermark-Lizenz](https://github.com/papermark/papermark/blob/main/LICENSE)).