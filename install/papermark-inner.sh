#!/usr/bin/env bash
# =============================================================================
#  📦 Papermark – Inner-Installer (läuft IM LXC-Container als root)
#  https://github.com/papermark/papermark
#
#  Wird von install/papermark.sh nach dem Anlegen des Containers in diesen
#  hineingeladen und ausgeführt. Die Steuerung kommt als Umgebungsvariablen:
#
#    APP_DIR           Projektverzeichnis            (Default /opt/papermark)
#    REPO_URL          Upstream-Repo                 (Default papermark/papermark)
#    REPO_REF          Pin (Commit SHA oder Tag)     (Default: siehe unten)
#    PORT              Web-UI-Port                   (Default 3000)
#    MAILPIT_WEB_PORT  Web-UI von Mailpit (Mails)    (Default 8025)
#    S3_API_PORT       S3-API (Versity Gateway)      (Default 9000)
#    S3_CONSOLE_PORT   S3-WebUI (nur lokal)          (Default 9001)
#    BRIDGE_PORT       Upstash-REST-Bridge           (Default 8079)
#    NODE_VERSION      Node-24-LTS (Binary-Tarball)  (Default 24.11.1)
#    MAILPIT_VERSION   Mailpit-Release               (Default v1.27.1)
#    UPDATE            "1" = vorhandene Installation aktualisieren
#    DEBUG             "1" = bash -x Trace
#
#  Warum dieser-Aufbau? Papermark ist eine Next.js-App (React/TypeScript) mit
#  PostgreSQL (Prisma) und S3-Blob-Speicher. Offiziell gibt es KEIN Docker-Image
#  und keine Compose-Datei – also wird im Container gebaut und als systemd-Service
#  betrieben. Damit im LAN alles lokal bleibt (keine Cloud-Dienste), bringt der
#  Container vier kleine lokale Dienste mit:
#
#    PostgreSQL   Datenbank (Paket)
#    Redis        Sessions/Login-Codes (Paket) + Upstash-REST-Bridge (nur
#                 HTTP-Adapter, weil Paparkmarks Redis-Client das Upstash-REST-
#                 Protokoll spricht – die Bridge reicht Befehle an Redis durch)
#    Versity S3   S3-kompatibler Speicher für Dokumente
#    Mailpit      SMTP-Server + Web-Postfach: darin liegen die Login-Codes
#    papermark    Next.js (Port 3000, systemd, Restart=always)
#
#  Zwei minimale, dokumentierte Patches (patches/apply-patches.mjs) machen den
#  Betrieb ohne Cloud möglich:
#    1. lib/resend.ts – E-Mail-Versand über SMTP (Mailpit) statt Resend-Cloud
#    2. lib/auth/auth-options.ts – QStash-Publish in try/catch (ohne QStash-Token
#       würde der allererste Login mit 500 abbrechen)
# =============================================================================
set -Eeuo pipefail

# WICHTIG (Live-Grube CT 212): `pct exec` startet über lxc-attach mit minimalem
# PATH – /usr/local/bin fehlt darin. Node landet aber genau dort. Ohne diesen
# Export läuft die Installation durch, findet aber hinterher "node" nicht.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ── Parameter (werden vom Host-Skript gesetzt) ─────────────────────────────
APP_DIR="${APP_DIR:-/opt/papermark}"
REPO_URL="${REPO_URL:-https://github.com/papermark/papermark}"
# Pin: letzter Stand des öffentlichen Repos, der ohne die (nicht öffentlichen)
# Enterprise-Dateien baut – siehe README, Abschnitt "Warum dieser Pin".
REPO_REF="${REPO_REF:-bb93cfd03c7531f67cbb09a652e61c92de16d371}"
PORT="${PORT:-3000}"
MAILPIT_WEB_PORT="${MAILPIT_WEB_PORT:-8025}"
S3_API_PORT="${S3_API_PORT:-9000}"
S3_CONSOLE_PORT="${S3_CONSOLE_PORT:-9001}"
BRIDGE_PORT="${BRIDGE_PORT:-8079}"
NODE_VERSION="${NODE_VERSION:-24.11.1}"
MAILPIT_VERSION="${MAILPIT_VERSION:-v1.27.1}"
UPDATE="${UPDATE:-0}"
DEBUG="${DEBUG:-0}"

APP_SRC="${APP_DIR}/app"
BRIDGE_DIR="${APP_DIR}/upstash-bridge"
CFG_DIR="/etc/papermark"
S3_DATA="/var/lib/papermark-s3"
MAILPIT_DATA="/var/lib/mailpit"
SETUP_LOG="/var/log/papermark-setup.log"
DB_NAME="papermark"
DB_USER="papermark"
REDIS_UNIT="redis-server"   # wird auf papermark-redis umgestellt, falls das Debian-Paket scheitert

# ── Farben & Logging ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''; BOLD=''
fi

step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
info() { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()   { echo -e "${GREEN}✔${NC}  $1"; }
warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
err()  { echo -e "${RED}✘${NC}  $1" >&2; }
die()  { err "$1"; exit 1; }

# komplettes Log mitschneiden (Debugging-Anforderung)
mkdir -p "$(dirname "$SETUP_LOG")"
exec > >(tee -a "$SETUP_LOG") 2>&1

on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    info "Letzte 40 Zeilen ${SETUP_LOG}:"
    tail -n 40 "$SETUP_LOG" 2>/dev/null | sed 's/^/    /' || true
    info "Service-Status im Container:"
    for u in postgresql "${REDIS_UNIT}" papermark-s3 papermark-mailpit \
             papermark-upstash-bridge papermark; do
        printf '    %-28s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
    done
    info "journalctl (papermark, letzte 30 Zeilen):"
    journalctl -u papermark --no-pager 2>/dev/null | tail -n 30 | sed 's/^/    /' || true
    info "journalctl (papermark-s3 / -mailpit / -upstash-bridge):"
    journalctl -u papermark-s3 -u papermark-mailpit -u papermark-upstash-bridge \
        --no-pager 2>/dev/null | tail -n 30 | sed 's/^/    /' || true
    info "Vollständiges Log: ${SETUP_LOG}"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

if [[ "$DEBUG" == "1" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Startet eine Unit und wartet kurz; bei Misserfolg gibt es die KOMPLETTE
# Diagnose aus (status + journal), damit ein Fehler nie nur als "failed"
# endet. Live-Grube CT 212: genau dieses Detail fehlte beim redis-Start.
start_unit() {
    local unit="$1" _
    systemctl restart "$unit" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        if [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]]; then
            ok "${unit} aktiv"
            return 0
        fi
        sleep 1
    done
    err "${unit} ist nicht aktiv geworden – Diagnose:"
    systemctl status "$unit" --no-pager -n 15 2>&1 | sed 's/^/    /' || true
    journalctl -u "$unit" --no-pager -n 30 2>&1 | sed 's/^/    /' || true
    return 1
}

# Fallback-Redis: das Debian-Paket scheitert in manchen LXCs (Live CT 212,
# redis 8.0.2). Wir starten dann eine eigene Instanz mit Minimal-Config –
# ohne /etc/redis/redis.conf, ohne Logdatei, ohne Drop-Privilegien.
setup_fallback_redis() {
    warn "Debian-Redis startet nicht – Fallback: eigene schlanke Redis-Instanz (papermark-redis.service)."
    systemctl disable redis-server >/dev/null 2>&1 || true
    systemctl mask redis-server >/dev/null 2>&1 || true
    cat > /etc/systemd/system/papermark-redis.service <<'EOF'
[Unit]
Description=Redis (eigene schlanke Instanz für Papermark)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/redis-server --bind 127.0.0.1 --port 6379 --save "" --appendonly no --daemonize no --supervised no --loglevel notice
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if start_unit papermark-redis; then
        REDIS_UNIT="papermark-redis"
        ok "Fallback-Redis läuft (eigene Instanz statt Debian-Paket)"
        return 0
    fi
    die "Auch die eigene Redis-Instanz startet nicht – siehe Diagnose oben.\n  Ohne Redis kein Login (Login-Codes, Sessions, Rate-Limits)."
}

# ── 1. Grundpakete ────────────────────────────────────────────────────────
step "1/9 Grundpakete installieren"
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
# Grube aus früheren LXC-Läufen (n8n/ZeitTracking): apt läuft als _apt und stolpert
# über Resolver-Dateien, die es nicht lesen darf → Sandbox hart auf root stellen.
# Das ist in Einweg-Containern vertretbar und verhindert den Totalabbruch.
APT_OPTS=(-o APT::Sandbox::User=root)
chmod 0644 /etc/resolv.conf 2>/dev/null || true
apt-get "${APT_OPTS[@]}" update -qq
apt-get "${APT_OPTS[@]}" install -y --no-install-recommends \
    ca-certificates curl wget gnupg git openssl xz-utils tar \
    postgresql redis-server

systemctl enable postgresql >/dev/null 2>&1 || true
start_unit postgresql || die "PostgreSQL lässt sich nicht starten – siehe Diagnose oben."
ok "PostgreSQL $(psql --version | awk '{print $3}') aktiv"

# Redis einzeln (nicht zusammen mit postgres): ein failed-Dienst darf nicht
# den Rest blockieren, und die Diagnose muss sichtbar sein.
if ! start_unit redis-server; then
    setup_fallback_redis
fi

# ── 2. Node.js (Binary-Tarball, SHA256-geprüft) ───────────────────────────
# Kein apt-Node (Debian 13 bringt 20.x, Papermark verlangt >= 22, wir bauen mit
# 24 LTS). Der Tarball wird gegen die offizielle SHASUMS256.txt geprüft.
step "2/9 Node.js ${NODE_VERSION} einrichten"
# Version EINMAL sicher einlesen (kein `$(node -v)` im if – würde bei fehlendem
# node den ERR-Trap in der Sub-Shell feuern und die Ausgabe verwässern).
NODE_VER=""
if command -v node >/dev/null 2>&1; then
    NODE_VER="$(node -v 2>/dev/null || true)"
fi
if [[ "$NODE_VER" != "v${NODE_VERSION}" ]]; then
    info "Installiere Node ${NODE_VERSION} nach /usr/local ..."
    TB="node-v${NODE_VERSION}-linux-x64.tar.xz"
    curl -fsSL --retry 3 -o "/tmp/${TB}" "https://nodejs.org/dist/v${NODE_VERSION}/${TB}" \
        || die "Node-Download fehlgeschlagen: https://nodejs.org/dist/v${NODE_VERSION}/${TB}"
    curl -fsSL --retry 3 -o /tmp/SHASUMS256.txt "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
        || die "SHASUMS256.txt konnte nicht geladen werden"
    EXPECT="$(awk -v f="$TB" '$2 == f {print $1}' /tmp/SHASUMS256.txt)"
    [[ -n "$EXPECT" ]] || die "SHA256 für ${TB} nicht in SHASUMS256.txt gefunden"
    echo "${EXPECT}  /tmp/${TB}" | sha256sum -c - >/dev/null \
        || die "SHA256-Prüfung für ${TB} fehlgeschlagen (erwartet ${EXPECT})"
    tar -xJf "/tmp/${TB}" -C /usr/local --strip-components=1 \
        || die "Entpacken von ${TB} nach /usr/local fehlgeschlagen"
    rm -f "/tmp/${TB}" /tmp/SHASUMS256.txt
    NODE_VER=""
    if command -v node >/dev/null 2>&1; then
        NODE_VER="$(node -v 2>/dev/null || true)"
    fi
fi
[[ "$NODE_VER" == "v${NODE_VERSION}" ]] \
    || die "Node ${NODE_VERSION} ist nach der Installation nicht nutzbar (ist '${NODE_VER}').\n  PATH=${PATH}\n  Prüfe: ls -l /usr/local/bin/node"
NPM_VER="?"
if command -v npm >/dev/null 2>&1; then
    NPM_VER="$(npm -v 2>/dev/null || true)"
fi
ok "Node ${NODE_VER} (npm ${NPM_VER}) unter $(command -v node)"

# ── 3. PostgreSQL: Rolle + Datenbank ──────────────────────────────────────
step "3/9 Datenbank ${DB_NAME} vorbereiten"
# In LXCs ist /dev/shm oft auf 64 MB begrenzt – parallele Queries brauchen
# dort mehr. mmap statt sysv verhindert "could not resize shared memory".
PG_CONF="$(ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null | head -1 || true)"
if [[ -n "$PG_CONF" ]]; then
    grep -q '^dynamic_shared_memory_type' "$PG_CONF" \
        || echo "dynamic_shared_memory_type = mmap" >> "$PG_CONF"
fi
systemctl restart postgresql
sleep 2
mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"
if [[ -f "$CFG_DIR/db.env" ]]; then
    DB_PASS="$(sed -n 's/^DB_PASS=//p' "$CFG_DIR/db.env")"
fi
if [[ -z "${DB_PASS:-}" ]]; then
    DB_PASS="$(openssl rand -hex 24)"
    umask 077
    printf 'DB_PASS=%s\n' "$DB_PASS" > "$CFG_DIR/db.env"
fi

if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'\"" | grep -q 1; then
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}'\"" >/dev/null
else
    # idempotent: dasselbe Passwort erneut setzen (ALTER ist problemlos wiederholbar)
    su - postgres -c "psql -c \"ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}'\"" >/dev/null
fi
if ! su - postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\"" | grep -q 1; then
    su - postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}\"" >/dev/null
fi
ok "Rolle und Datenbank ${DB_NAME} vorhanden"

# ── 4. Redis ──────────────────────────────────────────────────────────────
step "4/9 Redis konfigurieren"
# Redis läuft bereits (Schritt 1) und lauscht auf 127.0.0.1:6379 – genau das
# braucht die Upstash-REST-Bridge (Schritt 6).
redis-cli ping | grep -q PONG || die "Redis antwortet nicht auf PING"
# Paparkmarks Login-Code-Abruf nutzt GETDEL (lib/emails/send-verification-request.ts),
# das es erst ab Redis 6.2 gibt. Debian 12/13 liefern 7.x bzw. 8.x – ein Check
# verhindert, dass ein Container mit Uralt-Redis still nicht anmeldbar ist.
REDIS_VERSION="$(redis-server --version 2>/dev/null | sed -n 's/.*v=\([0-9]*\)\.\([0-9]*\)\..*/\1 \2/p' | head -1)"
if [[ -n "$REDIS_VERSION" ]]; then
    R_MAJOR="${REDIS_VERSION% *}"; R_MINOR="${REDIS_VERSION#* }"
    if [[ "$R_MAJOR" -lt 6 ]] || { [[ "$R_MAJOR" -eq 6 ]] && [[ "$R_MINOR" -lt 2 ]]; }; then
        die "Redis ${R_MAJOR}.${R_MINOR} ist zu alt: Paparkmarks Login-Code-Abruf braucht GETDEL (Redis >= 6.2)."
    fi
    ok "Redis ${R_MAJOR}.${R_MINOR} erreichbar (127.0.0.1:6379)"
else
    ok "Redis erreichbar (127.0.0.1:6379)"
fi

# ── 5. S3-Speicher (Versity Gateway) ─────────────────────────────────────
step "5/9 S3-Speicher einrichten"
# Papermark speichert Dokumente ausschließlich in S3
# (NEXT_PUBLIC_UPLOAD_TRANSPORT = "s3"): Uploads, signierte GET-URLs und
# Multipart-Uploads (tus). Der Versity Gateway (Apache-2.0, ein einziges
# Binary) stellt eine S3-API über einem lokalen Verzeichnis bereit – jedes
# Unterverzeichnis ist ein Bucket.
#
# Warum nicht MinIO? Die aktuellen MinIO-Builds (AIStor) verweigern ohne
# Lizenz jede S3-Operation ("running in offline mode. All S3 operations are
# denied"), die alten Binary-Pfade liefern nur noch HTTP 410. Versity Gateway
# ist frei und deckt alle von Papermark genutzten Operationen ab
# (Put/Get/Head, signierte URLs, Multipart-Upload) – lokal verifiziert.
S3_RELEASE="${S3_RELEASE:-v1.11.0}"
S3_TARBALL="versitygw_${S3_RELEASE}_Linux_x86_64.tar.gz"
S3_DIRNAME="versitygw_${S3_RELEASE}_Linux_x86_64"
S3_URL="https://github.com/versity/versitygw/releases/download/${S3_RELEASE}/${S3_TARBALL}"
if [[ ! -x /usr/local/bin/versitygw ]] || [[ "$UPDATE" == "1" ]]; then
    curl -fsSL --retry 3 -o "/tmp/${S3_TARBALL}" "$S3_URL" \
        || die "Versity Gateway konnte nicht geladen werden: ${S3_URL}"
    curl -fsSL --retry 3 -o /tmp/vgw-checksums.txt \
        "https://github.com/versity/versitygw/releases/download/${S3_RELEASE}/checksums.txt" || true
    if [[ -s /tmp/vgw-checksums.txt ]]; then
        EXPECT="$(awk -v f="$S3_TARBALL" '$2 == f {print $1}' /tmp/vgw-checksums.txt)"
        [[ -n "$EXPECT" ]] || die "Keine SHA256 für ${S3_TARBALL} in checksums.txt"
        echo "${EXPECT}  /tmp/${S3_TARBALL}" | sha256sum -c - >/dev/null \
            || die "SHA256-Prüfung für ${S3_TARBALL} fehlgeschlagen (erwartet ${EXPECT})"
    fi
    tar -xzf "/tmp/${S3_TARBALL}" -C /tmp
    install -m 0755 "/tmp/${S3_DIRNAME}/versitygw" /usr/local/bin/versitygw
    rm -rf "/tmp/${S3_TARBALL}" "/tmp/${S3_DIRNAME}" /tmp/vgw-checksums.txt
fi
mkdir -p "$S3_DATA/papermark" "$S3_DATA/papermark-archive"
S3_ACCESS_KEY="papermark"
if [[ -f "$CFG_DIR/s3.env" ]]; then
    S3_SECRET_KEY="$(sed -n 's/^S3_SECRET_KEY=//p' "$CFG_DIR/s3.env")"
fi
if [[ -z "${S3_SECRET_KEY:-}" ]]; then
    S3_SECRET_KEY="$(openssl rand -hex 24)"
fi
umask 077
cat > "$CFG_DIR/s3.env" <<EOF
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
ROOT_ACCESS_KEY=${S3_ACCESS_KEY}
ROOT_SECRET_ACCESS_KEY=${S3_SECRET_KEY}
EOF
chmod 600 "$CFG_DIR/s3.env"
ok "Versity Gateway ${S3_RELEASE} installiert ($(sha256sum /usr/local/bin/versitygw | awk '{print $1}'))"

# ── 6. Mailpit (SMTP + Web-Postfach für Login-Codes) ──────────────────────
step "6/9 Mailpit einrichten"
# Papermark verschickt Login-Codes per E-Mail. Ohne Cloud (Resend) fangen wir
# sie lokal: Papermark → SMTP 127.0.0.1:1025 → Mailpit. Der Code liegt dann im
# Web-Postfach unter http://<CT-IP>:8025 und kann dort abgelesen werden.
if [[ ! -x /usr/local/bin/mailpit ]] || [[ "$UPDATE" == "1" ]]; then
    curl -fsSL --retry 3 -o /tmp/mailpit.tar.gz \
        "https://github.com/axllent/mailpit/releases/download/${MAILPIT_VERSION}/mailpit-linux-amd64.tar.gz"
    tar -xzf /tmp/mailpit.tar.gz -C /tmp mailpit
    install -m 0755 /tmp/mailpit /usr/local/bin/mailpit
    rm -f /tmp/mailpit /tmp/mailpit.tar.gz
fi
mkdir -p "$MAILPIT_DATA"
ok "Mailpit ${MAILPIT_VERSION} installiert"

# ── 7. Upstash-REST-Bridge (lokaler Redis-Adapter) ────────────────────────
step "7/9 Upstash-REST-Bridge einrichten"
# Papermark nutzt @upstash/redis – einen HTTP-Client, der das REST-Protokoll von
# Upstash spricht. Damit kein Cloud-Account nötig ist, übersetzt diese kleine
# Bridge die REST-Aufrufe 1:1 in Redis-Befehle (LICENSE: MIT, ~100 Zeilen).
mkdir -p "$BRIDGE_DIR"
cat > "$BRIDGE_DIR/package.json" <<'EOF'
{
  "name": "papermark-upstash-bridge",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "description": "Minimal Upstash-REST-kompatibler HTTP-Adapter für lokalen Redis",
  "dependencies": {
    "ioredis": "5.11.1"
  }
}
EOF
if [[ ! -d "$BRIDGE_DIR/node_modules/ioredis" ]] || [[ "$UPDATE" == "1" ]]; then
    ( cd "$BRIDGE_DIR" && npm install --omit=dev --no-audit --no-fund >/dev/null )
fi
cat > "$BRIDGE_DIR/server.mjs" <<'BRIDGE_EOF'
// Upstash-REST-kompatibler Adapter für lokalen Redis (Papermark-Selfhosting).
//
// Paparkmarks lib/redis.ts instanziiert @upstash/redis. Dieser Client sendet
// POST-Requests mit einem JSON-Array als Body ("SET", "key", "value", ...) und
// erwartet als Antwort { result } bzw. { error } – bei aktivierter
// base64-Kodierung (Default des Clients) sind alle String-Ergebnisse base64.
// Genau das hier wird 1:1 an einen echten Redis durchgereicht.
//
// Unterstützte Endpunkte (vom Client erzeugt):
//   POST /            → einzelnes Kommando
//   POST /pipeline    → mehrere Kommandos (Pipeline)
//   POST /multi-exec  → mehrere Kommandos in MULTI/EXEC
import http from "node:http";
import { Redis } from "ioredis";

const PORT = Number(process.env.BRIDGE_PORT || 8079);
const TOKEN = process.env.BRIDGE_TOKEN || "";
const REDIS_URL = process.env.REDIS_URL || "redis://127.0.0.1:6379";

const redis = new Redis(REDIS_URL, { maxRetriesPerRequest: 2, lazyConnect: false });

const b64 = (v) => (v === "OK" ? "OK" : Buffer.from(String(v)).toString("base64"));

// Ergebnis für die Upstash-Antwort aufbereiten (Strings → base64).
function encode(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === "number") return value;
  if (Array.isArray(value)) return value.map(encode);
  if (typeof value === "string") return b64(value);
  return b64(String(value));
}

async function runOne(cmd) {
  try {
    const [name, ...args] = cmd;
    const result = await redis.call(String(name).toUpperCase(), ...args.map((a) => String(a)));
    return { result: encode(result) };
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) };
  }
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const auth = req.headers["authorization"] || "";
  if (TOKEN && auth !== `Bearer ${TOKEN}`) {
    send(res, 401, { error: "unauthorized" });
    return;
  }

  let raw = "";
  for await (const chunk of req) raw += chunk;
  if (!raw) raw = "[]";

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    send(res, 400, { error: "invalid json" });
    return;
  }

  const path = (req.url || "/").replace(/\/+$/, "");
  const commands = Array.isArray(parsed) && Array.isArray(parsed[0]) ? parsed : [parsed];

  try {
    if (path.endsWith("/multi-exec")) {
      const multi = redis.multi();
      for (const cmd of commands) {
        const [name, ...args] = cmd;
        multi.call(String(name).toUpperCase(), ...args.map((a) => String(a)));
      }
      const results = await multi.exec();
      send(
        res,
        200,
        (results || []).map(([error, value]) =>
          error ? { error: error.message } : { result: encode(value) },
        ),
      );
      return;
    }
    if (path.endsWith("/pipeline") || commands.length > 1) {
      const out = [];
      for (const cmd of commands) out.push(await runOne(cmd));
      send(res, 200, out);
      return;
    }
    send(res, 200, await runOne(commands[0]));
  } catch (error) {
    send(res, 500, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[upstash-bridge] listening on 0.0.0.0:${PORT} → ${REDIS_URL}`);
});
BRIDGE_EOF
ok "Bridge-Datei geschrieben"
if [[ -f "$CFG_DIR/bridge.env" ]]; then
    BRIDGE_TOKEN="$(sed -n 's/^BRIDGE_TOKEN=//p' "$CFG_DIR/bridge.env")"
fi
if [[ -z "${BRIDGE_TOKEN:-}" ]]; then
    BRIDGE_TOKEN="$(openssl rand -hex 24)"
fi
umask 077
cat > "$CFG_DIR/bridge.env" <<EOF
BRIDGE_PORT=${BRIDGE_PORT}
BRIDGE_TOKEN=${BRIDGE_TOKEN}
REDIS_URL=redis://127.0.0.1:6379
NODE_ENV=production
EOF
chmod 600 "$CFG_DIR/bridge.env"
ok "Bridge eingerichtet (Port ${BRIDGE_PORT})"

# ── 8. Papermark-Quellcode + Selfhosting-Patches ─────────────────────────
step "8/9 Papermark ${REPO_REF} einspielen"
mkdir -p "$APP_SRC"
SRC_TGZ="/tmp/papermark-src.tar.gz"
SRC_TMP="$(mktemp -d)"
# GitHub-Archiv des Pins (kein git nötig, reproduzierbar, schnell)
REPO_BASE="${REPO_URL%.git}"
curl -fsSL --retry 3 -o "$SRC_TGZ" "${REPO_BASE}/archive/${REPO_REF}.tar.gz"
tar -xzf "$SRC_TGZ" -C "$SRC_TMP"
SRC_TOP="$(find "$SRC_TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
[[ -n "$SRC_TOP" ]] || die "Entpacken des Papermark-Archivs fehlgeschlagen (${SRC_TGZ})"
cp -a "$SRC_TOP/." "$APP_SRC/"
rm -rf "$SRC_TMP" "$SRC_TGZ"
ok "Quellcode in ${APP_SRC}"

# Die Patches sind absichtlich als Skript im Skript: das Inner-Skript wird per
# curl aus dem Repo geladen und muss ohne weitere Dateien auskommen.
cat > /tmp/apply-patches.mjs <<'PATCH_EOF'
// Wendet die Selfhosting-Patches auf den Papermark-Quellcode an.
// Jeder Patch wird als exakte Zeichenkette gesucht; fehlt sie, bricht das
// Skript mit Dateiname + Kontext ab ( upstream hat sich geändert → Pin prüfen ).
import fs from "node:fs";
import path from "node:path";

const root = process.argv[2];
if (!root) {
  console.error("usage: apply-patches.mjs <papermark-source-dir>");
  process.exit(2);
}

const L = (...lines) => lines.join("\n");

const patches = [
  // ── 1) E-Mail-Versand über SMTP statt Resend-Cloud ──────────────────────
  {
    file: "lib/resend.ts",
    find: L('import { render, toPlainText } from "@react-email/render";', 'import { Resend } from "resend";'),
    replace: L(
      'import { render, toPlainText } from "@react-email/render";',
      'import nodemailer from "nodemailer";',
      'import { Resend } from "resend";',
    ),
    why: "nodemailer-Import für den SMTP-Versand",
  },
  {
    file: "lib/resend.ts",
    find: L(
      "export const resend = process.env.RESEND_API_KEY",
      "  ? new Resend(process.env.RESEND_API_KEY)",
      "  : null;",
    ),
    replace: L(
      "export const resend = process.env.RESEND_API_KEY",
      "  ? new Resend(process.env.RESEND_API_KEY)",
      "  : null;",
      "",
      "// Selfhosting (Proxmox-LXC): ist SMTP_URL gesetzt (z. B.",
      "// smtp://127.0.0.1:1025 für Mailpit), geht der Versand über den lokalen",
      "// SMTP-Server statt über Resend. nodemailer ist bereits Dependency des",
      "// Upstream-Projekts.",
      "export const smtpTransport = process.env.SMTP_URL",
      "  ? nodemailer.createTransport(process.env.SMTP_URL)",
      "  : null;",
    ),
    why: "SMTP-Transport (Mailpit) vorbereiten",
  },
  {
    file: "lib/resend.ts",
    find: L(
      "  if (!resend) {",
      "    // Throw an error if resend is not initialized",
      '    throw new Error("Resend not initialized");',
      "  }",
    ),
    replace: L(
      "  if (!resend && !smtpTransport) {",
      "    // Throw an error if neither Resend nor SMTP is configured",
      '    throw new Error("Resend not initialized");',
      "  }",
    ),
    why: "Resend ist jetzt optional (SMTP genügt)",
  },
  {
    file: "lib/resend.ts",
    find: L('            : "Marc from Papermark <marc@papermark.com>");', "", "  try {"),
    replace: L(
      '            : "Marc from Papermark <marc@papermark.com>");',
      "",
      "  if (smtpTransport) {",
      "    // Selfhosting: Versand über den lokalen SMTP-Server (Mailpit).",
      "    const info = await smtpTransport.sendMail({",
      "      from: fromAddress,",
      '      to: test ? "delivered@resend.dev" : to,',
      "      cc: cc,",
      '      replyTo: marketing ? "marc@papermark.com" : replyTo,',
      "      subject,",
      "      html,",
      "      text: plainText,",
      "      headers: unsubscribeUrl",
      "        ? {",
      '            "List-Unsubscribe": `<${unsubscribeUrl}>`,',
      '            "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",',
      "          }",
      "        : {},",
      "    });",
      "    return { id: info.messageId } as any;",
      "  }",
      "",
      "  try {",
    ),
    why: "SMTP-Versand Zweig vor dem Resend-Aufruf",
  },
  {
    file: "lib/resend.ts",
    find: "    const { data, error } = await resend.emails.send(",
    replace: "    const { data, error } = await resend!.emails.send(",
    why: "TypeScript-Narrowing (resend kann jetzt null sein)",
  },

  // ── 2) QStash-Publish absichern (ohne QSTASH_TOKEN → kein 500 beim Login) ─
  {
    file: "lib/auth/auth-options.ts",
    find: L(
      "      await qstash.publishJSON({",
      "        url: `${process.env.NEXT_PUBLIC_BASE_URL ?? getMainDomainUrl()}/api/cron/welcome-user`,",
    ),
    replace: L(
      "      if (!process.env.QSTASH_TOKEN) {",
      "        // Selfhosting ohne QStash: keine Queue, keine Begrüßungs-Mail.",
      "        // Ohne diesen Guard würde der allererste Login mit 500 abbrechen.",
      '        console.warn("[papermark] QSTASH_TOKEN nicht gesetzt – Begrüßungs-Job übersprungen");',
      "        return;",
      "      }",
      "",
      "      await qstash.publishJSON({",
      "        url: `${process.env.NEXT_PUBLIC_BASE_URL ?? getMainDomainUrl()}/api/cron/welcome-user`,",
    ),
    why: "QStash-Publish nur mit konfiguriertem Token",
  },

  // ── 3) Build von Typfehlern des öffentlichen Repos entkoppeln ──────────
  {
    file: "next.config.mjs",
    find: "const nextConfig = {",
    replace: L(
      "const nextConfig = {",
      "  // Selfhosting: im öffentlichen Repo fehlen die Enterprise-Dateien,",
      "  // dadurch enthält der Code Typfehler (z. B.",
      "  // lib/api/links/bulk-import.ts: rateLimiters.bulkLinkImport).",
      "  // Zur Laufzeit sind sie irrelevant – der Build würde sonst abbrechen.",
      "  typescript: { ignoreBuildErrors: true },",
      "  eslint: { ignoreDuringBuilds: true },",
    ),
    why: "Build trotz fehlender EE-Typen",
  },
];

let applied = 0;
for (const patch of patches) {
  const file = path.join(root, patch.file);
  if (!fs.existsSync(file)) {
    console.error(`✘ ${patch.file} fehlt – kann Patch nicht anwenden (${patch.why})`);
    process.exit(1);
  }
  let content = fs.readFileSync(file, "utf8");
  const count = content.split(patch.find).length - 1;
  if (count === 0) {
    console.error(`✘ Anker nicht gefunden in ${patch.file}: ${patch.why}`);
    console.error("  gesucht:");
    console.error(
      patch.find
        .split("\n")
        .map((l) => "    | " + l)
        .join("\n"),
    );
    console.error("→ Passt der Anker nicht mehr, Papermark-Pin prüfen (REPO_REF).");
    process.exit(1);
  }
  if (count > 1) {
    console.error(`✘ Anker mehrfach in ${patch.file} (${count}×): ${patch.why}`);
    process.exit(1);
  }
  content = content.replace(patch.find, patch.replace);
  fs.writeFileSync(file, content);
  applied++;
}
console.log(`✔ ${applied} Selfhosting-Patches angewendet`);
PATCH_EOF
node /tmp/apply-patches.mjs "$APP_SRC"
ok "Patches angewendet"

# ── 9. Konfiguration, Build, Dienste ─────────────────────────────────────
step "9/9 Konfiguration, Build und Dienste"

# ── 9a. Secrets (einmalig erzeugen, danach wiederverwenden) ───────────────
mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"
if [[ ! -f "$CFG_DIR/secrets.env" ]]; then
    umask 077
    cat > "$CFG_DIR/secrets.env" <<EOF
NEXTAUTH_SECRET=$(openssl rand -hex 32)
NEXT_PRIVATE_DOCUMENT_PASSWORD_KEY=$(openssl rand -hex 32)
NEXT_PRIVATE_VERIFICATION_SECRET=$(openssl rand -hex 32)
INTERNAL_API_KEY=$(openssl rand -hex 24)
EOF
    chmod 600 "$CFG_DIR/secrets.env"
fi
# shellcheck disable=SC1091
source "$CFG_DIR/secrets.env"

# Container-IP (für NEXTAUTH_URL, S3-Endpunkt und die Links)
CT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$CT_IP" ]] || die "Container hat keine IP-Adresse (hostname -I ist leer)"
info "Container-IP: ${CT_IP}"

# ── 9b. .env schreiben ───────────────────────────────────────────────────
# NEXTAUTH_URL & NEXT_PUBLIC_* hängen an der IP. Sie werden bei jedem Lauf
# neu geschrieben; ändert sich die IP, muss zusätzlich gebaut werden
# (NEXT_PUBLIC_*-Werte werden von Next.js beim Build inlined) → --update.
cat > "$APP_SRC/.env" <<EOF
# Papermark – Selfhosting-Konfiguration (von install/papermark-inner.sh erzeugt)
NEXTAUTH_SECRET=${NEXTAUTH_SECRET}
NEXTAUTH_URL=http://${CT_IP}:${PORT}

NEXT_PUBLIC_BASE_URL=http://${CT_IP}:${PORT}
NEXT_PUBLIC_MARKETING_URL=http://${CT_IP}:${PORT}
NEXT_PUBLIC_APP_BASE_HOST=${CT_IP}
NEXT_PUBLIC_WEBHOOK_BASE_HOST=${CT_IP}
NEXT_PUBLIC_WEBHOOK_BASE_URL=http://${CT_IP}:${PORT}

# Datenbank (lokal im Container)
POSTGRES_PRISMA_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}
POSTGRES_PRISMA_URL_NON_POOLING=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}

# Objektspeicher: Versity S3 Gateway. Kein DISTRIBUTION_HOST → signierte URLs
# zeigen direkt auf den S3-Endpunkt (http://<CT-IP>:9000), was im LAN
# funktioniert und CloudFront überflüssig macht.
NEXT_PUBLIC_UPLOAD_TRANSPORT=s3
NEXT_PRIVATE_UPLOAD_ENDPOINT=http://${CT_IP}:${S3_API_PORT}
NEXT_PRIVATE_UPLOAD_REGION=us-east-1
NEXT_PRIVATE_UPLOAD_BUCKET=papermark
NEXT_PRIVATE_ARCHIVE_BUCKET=papermark-archive
NEXT_PRIVATE_UPLOAD_ACCESS_KEY_ID=${S3_ACCESS_KEY}
NEXT_PRIVATE_UPLOAD_SECRET_ACCESS_KEY=${S3_SECRET_KEY}

# Redis-Locker/Login-Codes: Upstash-REST-Adapter auf lokalem Redis
UPSTASH_REDIS_REST_URL=http://127.0.0.1:${BRIDGE_PORT}
UPSTASH_REDIS_REST_TOKEN=${BRIDGE_TOKEN}
UPSTASH_REDIS_REST_LOCKER_URL=http://127.0.0.1:${BRIDGE_PORT}
UPSTASH_REDIS_REST_LOCKER_TOKEN=${BRIDGE_TOKEN}

# E-Mail-Versand lokal: Papermark → Mailpit (SMTP)
SMTP_URL=smtp://127.0.0.1:1025
RESEND_API_KEY=

# Verschlüsselung von Dokument-Passwörtern / Verification-URLs
NEXT_PRIVATE_DOCUMENT_PASSWORD_KEY=${NEXT_PRIVATE_DOCUMENT_PASSWORD_KEY}
NEXT_PRIVATE_VERIFICATION_SECRET=${NEXT_PRIVATE_VERIFICATION_SECRET}
INTERNAL_API_KEY=${INTERNAL_API_KEY}

# ── Cloud-Integrationen: Platzhalter ──────────────────────────────────────
# Papermark instanziiert einige Cloud-Clients (OpenAI, Slack, Hanko, Stripe …)
# schon beim Modul-Import und wirft, wenn die Keys fehlen. Für den lokalen
# Betrieb sind sie nicht nötig – Platzhalter genügen, damit Build und Start
# durchlaufen. Wer die Funktion will, trägt echte Keys ein und baut neu.
OPENAI_API_KEY=sk-local-placeholder
HANKO_API_KEY=local-placeholder-hanko-key
NEXT_PUBLIC_HANKO_TENANT_ID=local-placeholder-tenant
SLACK_CLIENT_ID=local-placeholder
SLACK_CLIENT_SECRET=local-placeholder
SLACK_APP_INSTALL_URL=http://${CT_IP}:${PORT}/api/integrations/slack/install
SLACK_INTEGRATION_ID=local-placeholder
TINYBIRD_TOKEN=local-placeholder
TRIGGER_SECRET_KEY=tr_local_placeholder
STRIPE_SECRET_KEY=sk_test_local_placeholder
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_local_placeholder
GOOGLE_CLIENT_ID=local-placeholder.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=local-placeholder
LINKEDIN_CLIENT_ID=local-placeholder
LINKEDIN_CLIENT_SECRET=local-placeholder
DUB_API_KEY=local-placeholder
EOF
chmod 600 "$APP_SRC/.env"
ok ".env geschrieben (Zugriff nur root)"

# ── 9c. Abhängigkeiten + Migrationen + Build ─────────────────────────────
cd "$APP_SRC"
LOCK_HASH="$(sha256sum package-lock.json | awk '{print $1}')"
if [[ ! -d node_modules ]] || [[ ! -f .npm-lock-hash ]] || [[ "$(cat .npm-lock-hash 2>/dev/null)" != "$LOCK_HASH" ]]; then
    info "npm ci (kann einige Minuten dauern) ..."
    npm ci --no-audit --no-fund
    echo "$LOCK_HASH" > .npm-lock-hash
    ok "Abhängigkeiten installiert ($(du -sh node_modules | awk '{print $1}'))"
else
    ok "Abhängigkeiten unverändert ($(du -sh node_modules | awk '{print $1}'))"
fi

info "Prisma-Client erzeugen ..."
npx prisma generate >/dev/null
ok "Prisma-Client aktuell"

info "Datenbank-Migrationen einspielen (prisma migrate deploy) ..."
npx prisma migrate deploy
ok "Schema auf aktuellem Stand"

BUILD_HASH="$(sha256sum package-lock.json .env next.config.mjs 2>/dev/null | sha256sum | awk '{print $1}')"
if [[ "$UPDATE" != "1" && -f .next-build-hash && "$(cat .next-build-hash 2>/dev/null)" == "$BUILD_HASH" ]]; then
    ok "Build unverändert – übersprungen"
else
    info "next build (Next.js-Produktions-Build, braucht 3–8 Minuten und ~4 GB RAM) ..."
    NODE_OPTIONS="--max-old-space-size=4096" npx next build
    echo "$BUILD_HASH" > .next-build-hash
    ok "Build fertig ($(du -sh .next | awk '{print $1}'))"
fi

# ── 9d. systemd-Dienste ──────────────────────────────────────────────────
step "systemd-Dienste einrichten"
cat > /etc/systemd/system/papermark-s3.service <<EOF
[Unit]
Description=Versity S3 Gateway – S3-Speicher für Papermark
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/papermark/s3.env
ExecStart=/usr/local/bin/versitygw --port 0.0.0.0:${S3_API_PORT} --region us-east-1 --webui 127.0.0.1:${S3_CONSOLE_PORT} posix ${S3_DATA}
Restart=always
RestartSec=5
LimitNOFILE=65536
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/papermark-mailpit.service <<'EOF'
[Unit]
Description=Mailpit – lokales SMTP-Postfach für Papermark-Login-Codes
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mailpit --listen 0.0.0.0:8025 --smtp 127.0.0.1:1025 --database /var/lib/mailpit/mailpit.db
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/papermark-upstash-bridge.service <<EOF
[Unit]
Description=Upstash-REST-Bridge (Papermark → lokaler Redis)
After=${REDIS_UNIT}.service
Wants=${REDIS_UNIT}.service

[Service]
Type=simple
EnvironmentFile=/etc/papermark/bridge.env
ExecStart=/usr/local/bin/node ${BRIDGE_DIR}/server.mjs
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/papermark.service <<EOF
[Unit]
Description=Papermark (Next.js) – Dokumente teilen, nachverfolgen, Datarooms
After=network-online.target postgresql.service redis-server.service papermark-s3.service papermark-mailpit.service papermark-upstash-bridge.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_SRC}
Environment=NODE_ENV=production
Environment=NEXT_TELEMETRY_DISABLED=1
ExecStart=/usr/local/bin/node ${APP_SRC}/node_modules/next/dist/bin/next start -p ${PORT} -H 0.0.0.0
Restart=always
RestartSec=5
TimeoutStopSec=20
KillMode=mixed
User=root

[Install]
WantedBy=multi-user.target
EOF

# IP-Sync: schreibt die IP in die runtime-relevanten NEXTAUTH_URL-Werte und
# startet Papermark neu, wenn sich die Container-IP geändert hat.
cat > /usr/local/bin/papermark-sync-env <<'EOF'
#!/usr/bin/env bash
# Hält NEXTAUTH_URL & NEXT_PUBLIC_* in /opt/papermark/app/.env synchron mit der
# aktuellen Container-IP (DHCP/IP-Wechsel). NEXT_PUBLIC_*-Werte werden von
# Next.js beim Build inlined – ändert sich die IP dauerhaft, zusätzlich
# `install/papermark.sh --update` ausführen (baut neu).
set -Eeuo pipefail
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
ENV_FILE="/opt/papermark/app/.env"
LOG="/var/log/papermark-ip-sync.log"
[[ -n "$IP" ]] || { echo "$(date -Is) keine IP – übersprungen" >> "$LOG"; exit 0; }
[[ -f "$ENV_FILE" ]] || { echo "$(date -Is) keine .env – übersprungen" >> "$LOG"; exit 0; }

changed=0
set_ip_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        grep -q "^${key}=${value}$" "$ENV_FILE" && return 0
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
    changed=1
}

set_ip_var "NEXTAUTH_URL" "http://${IP}:__PORT__"
set_ip_var "NEXT_PUBLIC_BASE_URL" "http://${IP}:__PORT__"
set_ip_var "NEXT_PUBLIC_MARKETING_URL" "http://${IP}:__PORT__"
set_ip_var "NEXT_PUBLIC_APP_BASE_HOST" "${IP}"
set_ip_var "NEXT_PUBLIC_WEBHOOK_BASE_HOST" "${IP}"
set_ip_var "NEXT_PUBLIC_WEBHOOK_BASE_URL" "http://${IP}:__PORT__"

if [[ "$changed" == "1" ]]; then
    echo "$(date -Is) IP-Wechsel → ${IP}, .env aktualisiert" >> "$LOG"
    if systemctl is-active --quiet papermark; then
        systemctl restart papermark
        echo "$(date -Is) papermark neu gestartet" >> "$LOG"
    fi
    echo "ACHTUNG: NEXT_PUBLIC_*-Werte sind im Build inlined – bitte"  >> "$LOG"
    echo "         'install/papermark.sh --update' ausführen, sonst zeigen" >> "$LOG"
    echo "         freigegebene Links noch auf die alte IP." >> "$LOG"
fi
exit 0
EOF
sed -i "s/__PORT__/${PORT}/g" /usr/local/bin/papermark-sync-env
chmod 0755 /usr/local/bin/papermark-sync-env

cat > /etc/systemd/system/papermark-ip-sync.service <<'EOF'
[Unit]
Description=Papermark: Container-IP in .env übernehmen
After=network-online.target
Wants=network-online.target
Before=papermark.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/papermark-sync-env
RemainAfterExit=no
EOF

systemctl daemon-reload
systemctl enable papermark-s3 papermark-mailpit papermark-upstash-bridge \
    papermark-ip-sync papermark >/dev/null 2>&1 || true
systemctl restart papermark-s3 papermark-mailpit papermark-upstash-bridge
sleep 3
systemctl restart papermark

# ── 9e. Verifikation ─────────────────────────────────────────────────────
step "Verifikation"
ALL_OK=1
for u in postgresql redis-server papermark-s3 papermark-mailpit \
         papermark-upstash-bridge papermark; do
    state="$(systemctl is-active "$u" 2>/dev/null || echo failed)"
    if [[ "$state" == "active" ]]; then
        ok "${u}: ${state}"
    else
        err "${u}: ${state}"
        journalctl -u "$u" --no-pager -n 15 2>/dev/null | sed 's/^/    /' || true
        ALL_OK=0
    fi
done

info "Warte auf Web-UI (http://127.0.0.1:${PORT}/login) ..."
HTTP_CODE="000"
for _ in $(seq 1 60); do
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/login" 2>/dev/null || echo 000)"
    [[ "$HTTP_CODE" == "200" ]] && break
    sleep 2
done
if [[ "$HTTP_CODE" == "200" ]]; then
    ok "Web-UI antwortet mit HTTP 200"
else
    err "Web-UI antwortet mit HTTP ${HTTP_CODE}"
    journalctl -u papermark --no-pager -n 40 2>/dev/null | sed 's/^/    /' || true
    ALL_OK=0
fi

# S3-Endpunkt prüfen – ohne den keine Uploads möglich sind. Der Versity
# Gateway beantwortet anonyme Listen mit 403 ( korrektes Verhalten ); ein
# Verbindungsfehler wäre 000.
S3_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${S3_API_PORT}/" 2>/dev/null || echo 000)"
if [[ "$S3_CODE" == "403" || "$S3_CODE" == "200" ]]; then
    ok "S3-Gateway antwortet (HTTP ${S3_CODE})"
else
    err "S3-Gateway antwortet mit HTTP ${S3_CODE}"
    ALL_OK=0
fi

# Upstash-Bridge prüfen (PING → +PONG)
BRIDGE_PONG="$(curl -s --max-time 5 -X POST "http://127.0.0.1:${BRIDGE_PORT}/pipeline" \
    -H "Authorization: Bearer ${BRIDGE_TOKEN}" -H 'Content-Type: application/json' \
    -d '[["PING"]]' 2>/dev/null || true)"
if [[ "$BRIDGE_PONG" == *'"result"'* ]]; then
    ok "Upstash-Bridge antwortet (Redis-Pipeline)"
else
    err "Upstash-Bridge antwortet nicht: ${BRIDGE_PONG:-<leer>}"
    journalctl -u papermark-upstash-bridge --no-pager -n 20 2>/dev/null | sed 's/^/    /' || true
    ALL_OK=0
fi

if [[ "$ALL_OK" != "1" ]]; then
    die "Verifikation fehlgeschlagen – Details siehe oben und in ${SETUP_LOG}"
fi

echo
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Papermark ist installiert und läuft${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Web-UI (Papermark):   http://${CT_IP}:${PORT}"
echo -e "  Login-Codes (Mailpit): http://${CT_IP}:${MAILPIT_WEB_PORT}"
echo -e "  S3-API (Versity):      http://${CT_IP}:${S3_API_PORT}  (WebUI nur lokal: ${S3_CONSOLE_PORT})"
echo
echo -e "  ${BOLD}Login${NC}:      \"Continue with email\" → Code kommt per Mail →"
echo -e "             Postfach unter http://${CT_IP}:${MAILPIT_WEB_PORT} öffnen, Code ablesen"
echo -e "  ${BOLD}Daten${NC}:      Container ${APP_DIR} · PostgreSQL ${DB_NAME} · S3 ${S3_DATA}"
echo -e "  ${BOLD}Logs${NC}:       journalctl -u papermark -f   ·   ${SETUP_LOG}"
echo
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"