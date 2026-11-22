#!/usr/bin/env bash
# =============================================================================
#  📄 Papermark – One-Click-Installer (Proxmox VE)
#  https://github.com/papermark/papermark  ·  Repo: HatchetMan111/Papermark-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Papermark – die Open-Source-Alternative zu DocSend (Dokumente teilen,
#  Zugriffe nachverfolgen, Datarooms) mit Web-UI, PostgreSQL, S3-Speicher und
#  lokalem Mail-Postfach. Nach dem Vorbild der Proxmox VE Community Scripts.
#
#  Alles läuft lokal im Container – keine Cloud-Dienste:
#    • PostgreSQL      Datenbank (Prisma, 134 Migrationen)
#    • Redis           Sessions, Login-Codes, Rate-Limits
#    • Upstash-Bridge  kleiner HTTP-Adapter, damit Paparkmarks Redis-Client
#                      (@upstash/redis) gegen den lokalen Redis läuft
#    • Versity S3      S3-kompatibler Speicher für die Dokumente (Apache-2.0)
#    • Mailpit         SMTP + Web-Postfach für die Login-Codes
#    • Papermark       Next.js (React) auf Port 3000, systemd, Restart=always
#
#  Login: "Continue with email" → Papermark schickt einen 10-stelligen Code,
#  der im lokalen Postfach (http://<CT-IP>:8025) liegt.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Papermark-Proxmox/main/install/papermark.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 6144 --ip 192.168.178.50/24 --gateway 192.168.178.1
#
#  Update / Deinstall / Status / Debug:
#    ... " --update      |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# WICHTIG: Das Skript läuft auch per `bash -c "$(wget -qLO - …)"`. Dort ist
# BASH_SOURCE[0] undefiniert – Skript-Pfad deshalb nur mit Fallback anfassen.
set -Eeuo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"
APP_NAME="papermark"
APP_DISPLAY="Papermark"
CT_HOSTNAME="papermark"
REPO_OWNER="HatchetMan111"
REPO_NAME="Papermark-Proxmox"
REPO_REF="main"

# Upstream-Pin: letzter Commit des öffentlichen Papermark-Repos, der ohne die
# (nicht öffentlichen) Enterprise-Dateien baut – siehe README.
UPSTREAM_REPO="https://github.com/papermark/papermark"
UPSTREAM_REF="bb93cfd03c7531f67cbb09a652e61c92de16d371"

UI_PORT=3000
MAILPIT_WEB_PORT=8025
S3_API_PORT=9000
S3_CONSOLE_PORT=9001
BRIDGE_PORT=8079
NODE_VERSION="24.11.1"
MAILPIT_VERSION="v1.34.0"

CT_ID="${CT_ID:-${CTID:-}}"
ID_SCAN_START=200
CT_MEMORY="${MEMORY:-6144}"     # Next.js-Build braucht ~4 GB, Laufzeit ~1 GB
CT_SWAP="${SWAP:-2048}"         # Puffer für Build-Spitzen (npm/next build)
CT_CORES="${CORES:-4}"          # Build ist CPU-limitiert, Laufzeit genügt 2
CT_ROOTFS="${DISK:-20}"         # node_modules ~2,5 GB + .next ~1,5 GB + Daten
CT_STORAGE="${STORAGE:-local-lvm}"
CT_BRIDGE="${BRIDGE:-vmbr0}"
CT_IP="${IP:-dhcp}"
CT_GATEWAY="${GATEWAY:-}"
CT_PASSWORD="${PASSWORD:-}"
CT_SSHKEY="${SSHKEY:-}"
CT_UNPRIVILEGED="${UNPRIVILEGED:-1}"
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
TEMPLATE="${TEMPLATE:-debian-13-standard}"
TEMPLATE_FILE=""

FORCE_RECREATE=false
ASSUME_YES=false
UPDATE=false
UNINSTALL=false
STATUS_CHECK=false
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"

TMP_DIR=""
# Nur aus einem echten Skriptpfad ableiten: bei `bash -c "$(wget …)" --opt`
# ist $0 die Option selbst – dirname würde dann meckern.
SCRIPT_DIR=""
if [[ "${BASH_SOURCE[0]:-}" == -* ]]; then
    SCRIPT_DIR=""
elif [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
fi
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
ONE_LINER="bash -c \"\$(wget -qLO - https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/install/${APP_NAME}.sh)\""

# ── Farben & Logging ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''; BOLD=''
fi

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Bei Fehlern die KOMPLETTE Kette ausgeben: Exit-Code, Zeile, Befehl, Log,
# Container-Logs (Setup + Dienste). Container wird nie automatisch gelöscht.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 25 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" >/dev/null 2>&1; then
        info "Container-Logs (Setup + Dienste):"
        pct exec "$CT_ID" -- sh -c '
            echo "--- /var/log/papermark-setup.log (letzte 40) ---"
            tail -n 40 /var/log/papermark-setup.log 2>/dev/null
            echo "--- systemctl is-active ---"
            for u in postgresql redis-server papermark-s3 papermark-mailpit papermark-upstash-bridge papermark; do
                printf "%-28s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null || echo unknown)"
            done
            echo "--- journalctl papermark (letzte 30) ---"
            journalctl -u papermark --no-pager 2>/dev/null | tail -n 30
            echo "--- journalctl s3/mailpit/bridge (letzte 20) ---"
            journalctl -u papermark-s3 -u papermark-mailpit -u papermark-upstash-bridge --no-pager 2>/dev/null | tail -n 20
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container ${CT_ID} wurde NICHT gelöscht – Inspektion: pct enter ${CT_ID}"
        info "Aufräumen: pct stop ${CT_ID} && pct destroy ${CT_ID} --purge"
    fi
    info "Vollständiges Log: ${LOG_FILE}"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# --debug muss vor parse_args gesetzt sein, damit auch das Parsen getraced wird
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    # "" wenn nicht gefunden – niemals Exit 1 (sonst greift set -e in den
    # Zuweisungen `id="$(find_ct_id_by_hostname)"`).
    local id
    id="$(pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}')"
    echo "${id:-}"
    return 0
}

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)         echo "amd64" ;;
        aarch64|arm64)        echo "arm64" ;;
        *)                    echo "$(uname -m)" ;;
    esac
}

get_ct_ip() {
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    local id="$1" tries=0 ip=""
    if [[ "$DRY_RUN" == "1" ]]; then
        info "DRY-RUN: Netzwerk-Warten übersprungen"
        return 0
    fi
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP an der Bridge ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

# Live-Grube aus früheren Installern: pct create --start meldet Exit 0, obwohl
# der Container im Status "stopped" hängen bleibt (falsche Architektur,
# fehlender Storage, …). Deshalb nach dem Start IMMER Status + pct exec prüfen.
verify_ct_started() {
    local id="$1" tries=0 state=""
    if [[ "$DRY_RUN" == "1" ]]; then
        info "DRY-RUN: Start-Verifikation übersprungen"
        return 0
    fi
    while [[ $tries -lt 30 ]]; do
        state="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
        if [[ "$state" == "running" ]]; then
            if pct exec "$id" -- true >/dev/null 2>&1; then
                ok "Container $id läuft (pct exec funktioniert)"
                return 0
            fi
        fi
        tries=$((tries + 1))
        sleep 1
    done
    err "Container $id läuft nicht (Status: ${state:-unbekannt})."
    info "pct start $id && pct status $id"
    info "Logs: pct start $id 2>&1 | tail -20"
    return 1
}

verify_ct_dns() {
    # DHCP-DNS ist in Proxmox-LXCs flaky (Live-Fund in anderen Installern):
    # 3 Erfolge in Folge verlangen, sonst Fallback-Nameserver schreiben.
    local id="$1" ok_count=0 tries=0
    if [[ "$DRY_RUN" == "1" ]]; then
        info "DRY-RUN: DNS-Prüfung übersprungen"
        return 0
    fi
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    [[ -n "$host_ns" ]] && ns_list="$host_ns $ns_list"
    warn "DNS im Container defekt – Fallback-Nameserver werden gesetzt ($ns_list)"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns' || true
    if pct exec "$id" -- getent hosts deb.debian.org >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion.\n  Prüfe: pct exec $id -- cat /etc/resolv.conf"
}

ensure_ct_running() {
    local ct_id="$1" state ip="" i
    state="$(pct status "$ct_id" 2>/dev/null | awk '{print $2}')"
    if [[ "$state" == "running" ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state:-unbekannt}) – starte ihn ..."
    pct start "$ct_id" >/dev/null 2>&1 || die "Container $ct_id konnte nicht gestartet werden (pct start $ct_id)"
    verify_ct_started "$ct_id"
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        [[ -n "$ip" ]] && { ok "Container läuft (IP: $ip)"; return 0; }
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen)"
}

# ── Argumente ──────────────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument mit $0, nicht $1 – die Option würde still geschluckt.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)            CT_ID="${args[$((i+1))]:-}";         i=$((i+2)) ;;
            --hostname)      CT_HOSTNAME="${args[$((i+1))]:-}";   i=$((i+2)) ;;
            --storage)       CT_STORAGE="${args[$((i+1))]:-}";    i=$((i+2)) ;;
            --rootfs)        CT_ROOTFS="${args[$((i+1))]:-}";     i=$((i+2)) ;;
            --cores)         CT_CORES="${args[$((i+1))]:-}";      i=$((i+2)) ;;
            --memory)        CT_MEMORY="${args[$((i+1))]:-}";     i=$((i+2)) ;;
            --swap)          CT_SWAP="${args[$((i+1))]:-}";       i=$((i+2)) ;;
            --bridge)        CT_BRIDGE="${args[$((i+1))]:-}";     i=$((i+2)) ;;
            --ip)            CT_IP="${args[$((i+1))]:-}";         i=$((i+2)) ;;
            --gateway)       CT_GATEWAY="${args[$((i+1))]:-}";    i=$((i+2)) ;;
            --password)      CT_PASSWORD="${args[$((i+1))]:-}";   i=$((i+2)) ;;
            --sshkey)        CT_SSHKEY="${args[$((i+1))]:-}";     i=$((i+2)) ;;
            --template)      TEMPLATE="${args[$((i+1))]:-}";      i=$((i+2)) ;;
            --template-store) TEMPLATE_STORE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)          UI_PORT="${args[$((i+1))]:-}";       i=$((i+2)) ;;
            --mailpit-port)  MAILPIT_WEB_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --node-version)  NODE_VERSION="${args[$((i+1))]:-}";  i=$((i+2)) ;;
            --ref)           UPSTREAM_REF="${args[$((i+1))]:-}";  i=$((i+2)) ;;
            --force)         FORCE_RECREATE=true;                i=$((i+1)) ;;
            --yes|-y)        ASSUME_YES=true;                    i=$((i+1)) ;;
            --update)        UPDATE=true;                        i=$((i+1)) ;;
            --uninstall)     UNINSTALL=true;                    i=$((i+1)) ;;
            --status)        STATUS_CHECK=true;                  i=$((i+1)) ;;
            --dry-run)       DRY_RUN=1;                          i=$((i+1)) ;;
            --debug)         set -x;                             i=$((i+1)) ;;
            --help|-h)       print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
    # hart validieren – die Werte landen direkt in pct-Befehlen
    [[ "$UI_PORT" =~ ^[0-9]+$ ]] && [[ "$UI_PORT" -ge 1 && "$UI_PORT" -le 65535 ]] \
        || die "Ungültiger Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 3000)"
    [[ "$MAILPIT_WEB_PORT" =~ ^[0-9]+$ ]] && [[ "$MAILPIT_WEB_PORT" -ge 1 && "$MAILPIT_WEB_PORT" -le 65535 ]] \
        || die "Ungültiger Mailpit-Port: '$MAILPIT_WEB_PORT'"
    [[ "$MAILPIT_WEB_PORT" == "$UI_PORT" ]] \
        && die "Web-UI-Port und Mailpit-Port dürfen nicht identisch sein ($UI_PORT)"
    [[ "$CT_CORES" =~ ^[0-9]+$ ]] && [[ "$CT_CORES" -ge 1 ]]  || die "Ungültige CPU-Anzahl: '$CT_CORES'"
    [[ "$CT_MEMORY" =~ ^[0-9]+$ ]] && [[ "$CT_MEMORY" -ge 1024 ]] || die "Ungültiger RAM: '$CT_MEMORY' MB"
    [[ "$CT_SWAP" =~ ^[0-9]+$ ]]   || die "Ungültiger Swap: '$CT_SWAP'"
    [[ "$CT_ROOTFS" =~ ^[0-9]+$ ]] && [[ "$CT_ROOTFS" -ge 8 ]] || die "Ungültige Disk: '$CT_ROOTFS' GB (min. 8)"
    [[ "$UPSTREAM_REF" =~ ^[0-9A-Za-z._-]+$ ]] || die "Ungültige --ref-Angabe: '$UPSTREAM_REF'"
}

print_help() {
    cat <<EOF
📄 ${APP_DISPLAY} – Proxmox-Installer (Dokumente teilen & nachverfolgen, papermark/papermark)

Installation:   ${ONE_LINER}

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID             Container-ID (Default: nächste freie ab ${ID_SCAN_START})
  --hostname NAME     Container-Hostname (Default: ${CT_HOSTNAME})
  --storage NAME      Storage für rootfs (Default: ${CT_STORAGE})
  --rootfs GB         Disk-Größe (Default: ${CT_ROOTFS} – node_modules + Build + Daten)
  --cores N           vCPUs (Default: ${CT_CORES} – Next.js-Build ist CPU-limitiert)
  --memory MB         RAM (Default: ${CT_MEMORY} – Build braucht ~4 GB)
  --swap MB           Swap (Default: ${CT_SWAP})
  --bridge BR         Netzwerk-Bridge (Default: ${CT_BRIDGE})
  --ip CIDR           Statt DHCP, z. B. 192.168.178.50/24 (+ --gateway 192.168.178.1)
                      Empfohlen (oder DHCP-Reservierung): NEXTAUTH_URL/Links
                      hängen an der IP.
  --gateway GW        Gateway für statische IP
  --password PW       Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD       Public-Key-Datei oder URL – ssh-Login als root im CT
  --template NAME     OS-Template (Default: ${TEMPLATE})
  --template-store S  Storage mit den Templates (Default: ${TEMPLATE_STORE})
  --port PORT         Web-UI-Port (Default: ${UI_PORT})
  --mailpit-port PORT Web-Postfach für Login-Codes (Default: ${MAILPIT_WEB_PORT})
  --node-version V    Node-Version für den Build (Default: ${NODE_VERSION})
  --ref REF           Papermark-Quelle pinnen (Commit/Tag; Default: ${UPSTREAM_REF:0:12})
  --force             Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y          Rückfragen überspringen
  --update            Papermark im Container aktualisieren (Daten & .env bleiben)
  --uninstall         Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status            Status von Container + Diensten anzeigen
  --dry-run           Befehle nur anzeigen, nichts ausführen
  --debug             Vollständiges bash -x-Trace
  --help / -h         Diese Hilfe

Login: "Continue with email" → Code im Postfach http://<CT-IP>:${MAILPIT_WEB_PORT}
EOF
}

# ── Aktionen ───────────────────────────────────────────────────────────────
run() {
    # --dry-run: Befehle nur anzeigen
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi
    "$@"
}

confirm() {
    [[ "$ASSUME_YES" == "true" ]] && return 0
    local reply=""
    read -r -p "$(echo -e "${YELLOW}⚠${NC}  $1 [j/N] ")" reply || true
    [[ "$reply" =~ ^[jJyY]$ ]]
}

preflight() {
    header "Vorprüfung (Proxmox-Host)"
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Bitte als root ausführen (sudo -i)."
    command -v pct  >/dev/null || die "pct fehlt – läuft das hier auf einem Proxmox-Host?"
    command -v pveam >/dev/null || die "pveam fehlt – läuft das hier auf einem Proxmox-Host?"
    ok "Proxmox erkannt ($(pveversion --verbose 2>/dev/null | awk -F': ' '/^pve-manager/{print $2}'))"

    if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$CT_STORAGE"; then
        die "Storage '$CT_STORAGE' existiert nicht. Verfügbar:\n$(pvesm status | awk 'NR>1{print "  "$1}')"
    fi
    ok "Storage ${CT_STORAGE} vorhanden"

    # Template-Datei + Architektur (Live-Grube aus früheren Installern: ein
    # arm64-Template auf einem amd64-Host lässt pct create mit Exit 0
    # durchlaufen, der Container startet aber nie.)
    local arch tpl="" try_tpl cand
    arch="$(host_arch)"
    if [[ "$DRY_RUN" == "1" ]]; then
        TEMPLATE_FILE="${TEMPLATE_STORE}:vztmpl/${TEMPLATE}_dummy_${arch}.tar.zst"
        ok "Template (nur Anzeige): ${TEMPLATE_FILE}"
        return 0
    fi
    for cand in "$TEMPLATE" "debian-13-standard" "debian-12-standard"; do
        try_tpl="$cand"
        tpl="$(pveam list "$TEMPLATE_STORE" 2>/dev/null | awk '{print $1}' | sed 's|.*/||' | grep -E "^${try_tpl}_" | head -1 || true)"
        if [[ -z "$tpl" ]]; then
            warn "Template '${try_tpl}' fehlt in '${TEMPLATE_STORE}' – Download wird versucht ..."
            run pveam download "$TEMPLATE_STORE" "$try_tpl" || continue
            tpl="$(pveam list "$TEMPLATE_STORE" 2>/dev/null | awk '{print $1}' | sed 's|.*/||' | grep -E "^${try_tpl}_" | head -1 || true)"
        fi
        [[ -n "$tpl" ]] || continue
        if [[ "$tpl" != *"_${arch}."* ]]; then
            warn "Template '${tpl}' ist nicht für ${arch} – übersprungen"
            tpl=""
            continue
        fi
        break
    done
    [[ -n "$tpl" ]] || die "Kein passendes Debian-Template für ${arch} in '${TEMPLATE_STORE}'.\n  Vorhanden:\n$(pveam list "$TEMPLATE_STORE" 2>/dev/null | awk 'NR>1{print "  "$1}')\n  Download: pveam download ${TEMPLATE_STORE} ${TEMPLATE}"
    TEMPLATE="$try_tpl"
    ok "Template ${tpl} (Architektur ${arch})"
    TEMPLATE_FILE="${TEMPLATE_STORE}:vztmpl/${tpl}"
}

push_inner_script() {
    local ct_id="$1"
    local local_inner=""
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/${APP_NAME}-inner.sh" ]]; then
        local_inner="$SCRIPT_DIR/${APP_NAME}-inner.sh"
    fi
    if [[ -n "$local_inner" ]]; then
        # Aus einem Checkout: direkt in den Container schieben (kein Netz nötig)
        info "Übertrage ${APP_NAME}-inner.sh aus ${local_inner}"
        run pct push "$ct_id" "$local_inner" "/tmp/${APP_NAME}-inner.sh"
    else
        # Aus dem Repo: im Container per curl holen (inkl. Cache-Buster)
        local url="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}/install/${APP_NAME}-inner.sh"
        info "Lade ${APP_NAME}-inner.sh im Container: ${url}"
        run pct exec "$ct_id" -- bash -lc "curl -fsSL --retry 3 --max-time 120 -o /tmp/${APP_NAME}-inner.sh '${url}?cb=\$(date +%s)'"
    fi
    run pct exec "$ct_id" -- chmod 0700 "/tmp/${APP_NAME}-inner.sh"
}

run_inner_script() {
    local ct_id="$1" update_flag="${2:-0}"
    info "Führe Installation im Container aus (das dauert 10–20 Minuten: npm ci + next build) ..."
    run pct exec "$ct_id" -- env \
        APP_DIR="/opt/${APP_NAME}" \
        REPO_URL="$UPSTREAM_REPO" \
        REPO_REF="$UPSTREAM_REF" \
        PORT="$UI_PORT" \
        MAILPIT_WEB_PORT="$MAILPIT_WEB_PORT" \
        S3_API_PORT="$S3_API_PORT" \
        S3_CONSOLE_PORT="$S3_CONSOLE_PORT" \
        BRIDGE_PORT="$BRIDGE_PORT" \
        NODE_VERSION="$NODE_VERSION" \
        MAILPIT_VERSION="$MAILPIT_VERSION" \
        UPDATE="$update_flag" \
        DEBUG="$DEBUG" \
        bash "/tmp/${APP_NAME}-inner.sh"
}

verify_install() {
    local ct_id="$1" ip state code i
    header "Verifikation (vom Host aus)"
    if [[ "$DRY_RUN" == "1" ]]; then
        info "DRY-RUN: Verifikation übersprungen"
        return 0
    fi
    ensure_ct_running "$ct_id"
    ip="$(get_ct_ip "$ct_id")"
    [[ -n "$ip" ]] || die "Container-IP konnte nicht ermittelt werden."
    ok "Container-IP: ${ip}"

    state="$(run pct exec "$ct_id" -- systemctl is-active "$APP_NAME" 2>/dev/null || echo unknown)"
    if [[ "$state" == "active" ]]; then
        ok "Service ${APP_NAME}.service: active"
    else
        err "Service ${APP_NAME}.service: ${state}"
        pct exec "$ct_id" -- journalctl -u "$APP_NAME" --no-pager -n 30 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi

    code="000"
    for i in $(seq 1 40); do
        code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${UI_PORT}/login" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && break
        sleep 2
    done
    if [[ "$code" == "200" ]]; then
        ok "Web-UI antwortet im Container mit HTTP 200"
    else
        err "Web-UI antwortet mit HTTP ${code}"
        pct exec "$ct_id" -- journalctl -u "$APP_NAME" --no-pager -n 30 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi
    CT_IP_FINAL="$ip"
}

CT_IP_FINAL=""

do_install() {
    # ── Container anlegen ─────────────────────────────────────────────────
    if [[ -z "$CT_ID" ]]; then
        CT_ID="$(find_free_id)"
        info "Verwendete freie Container-ID: ${CT_ID}"
    fi
    if pct status "$CT_ID" >/dev/null 2>&1; then
        die "Container ${CT_ID} existiert bereits.\n  Andere ID wählen (--id) oder --force (löscht den Container!)"
    fi
    if ct_exists "$CT_HOSTNAME"; then
        if [[ "$FORCE_RECREATE" == "true" ]]; then
            local old; old="$(find_ct_id_by_hostname)"
            warn "Container '${CT_HOSTNAME}' (${old}) existiert – wird mit --force gelöscht ..."
            run pct stop "$old" || true
            run pct destroy "$old" --purge
        else
            die "Hostname '${CT_HOSTNAME}' ist bereits vergeben ($(find_ct_id_by_hostname)).\n  --hostname NAME oder --force verwenden."
        fi
    fi

    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
    fi

    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    local gw_arg=()
    if [[ "$CT_IP" != "dhcp" && -n "$CT_GATEWAY" ]]; then
        gw_arg=(--gw "$CT_GATEWAY")
    fi

    header "Container ${CT_ID} (${CT_HOSTNAME}) anlegen"
    run pct create "$CT_ID" "$TEMPLATE_FILE" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        "${gw_arg[@]}" \
        --nameserver "1.1.1.1 8.8.8.8 9.9.9.9" \
        --onboot 1 \
        --unprivileged "$CT_UNPRIVILEGED" \
        --description "Papermark (Dokumente teilen/nachverfolgen) – verwaltet mit HatchetMan111/Papermark-Proxmox. Web-UI: :${UI_PORT}, Postfach: :${MAILPIT_WEB_PORT}" \
        --password "$CT_PASSWORD" \
        --start 0
    ok "Container ${CT_ID} angelegt (root-Passwort: ${CT_PASSWORD})"

    if [[ -n "$CT_SSHKEY" ]]; then
        local keyfile=""
        if [[ -f "$CT_SSHKEY" ]]; then
            keyfile="$CT_SSHKEY"
        else
            keyfile="$(mktemp)"
            curl -fsSL --retry 3 -o "$keyfile" "$CT_SSHKEY" || die "SSH-Key konnte nicht geladen werden: $CT_SSHKEY"
        fi
        pct exec "$CT_ID" -- mkdir -p /root/.ssh
        pct exec "$CT_ID" -- chmod 700 /root/.ssh
        run pct push "$CT_ID" "$keyfile" /root/.ssh/authorized_keys
        run pct exec "$CT_ID" -- chmod 600 /root/.ssh/authorized_keys
        ok "SSH-Public-Key hinterlegt"
    fi

    run pct start "$CT_ID"
    verify_ct_started "$CT_ID"
    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    # ── Installation im Container ─────────────────────────────────────────
    push_inner_script "$CT_ID"
    run_inner_script "$CT_ID" 0
    verify_install "$CT_ID"

    header "Fertig 🎉"
    echo -e "  ${BOLD}Web-UI${NC}:        http://${CT_IP_FINAL}:${UI_PORT}"
    echo -e "  ${BOLD}Login-Codes${NC}:    http://${CT_IP_FINAL}:${MAILPIT_WEB_PORT}  (Mailpit-Postfach)"
    echo -e "  ${BOLD}Login${NC}:          \"Continue with email\" → Code im Postfach ablesen"
    echo -e "  ${BOLD}Container${NC}:      ${CT_ID} (${CT_HOSTNAME}) · root-Passwort: ${CT_PASSWORD}"
    echo -e "  ${BOLD}Logs${NC}:           pct exec ${CT_ID} -- journalctl -u ${APP_NAME} -f"
    echo
    echo -e "  Nächste freie ID wäre jetzt: $(find_free_id)"
    echo -e "  Deinstallation: ${ONE_LINER} --uninstall"
    echo -e "  Update:         ${ONE_LINER} --update"
}

do_update() {
    header "Update"
    local ct_id="${CT_ID:-}"
    if [[ -z "$ct_id" ]]; then
        ct_id="$(find_ct_id_by_hostname)"
    fi
    [[ -n "$ct_id" ]] || die "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden.\n  Vorhandene Container:\n$(pct list | awk 'NR>1{print "  "$1" "$NF}')"
    CT_ID="$ct_id"
    ensure_ct_running "$CT_ID"
    push_inner_script "$CT_ID"
    run_inner_script "$CT_ID" 1
    verify_install "$CT_ID"
    echo -e "\n${GREEN}✔${NC}  Update fertig – Web-UI: http://${CT_IP_FINAL}:${UI_PORT}"
}

do_uninstall() {
    header "Deinstallation"
    local ct_id="${CT_ID:-}"
    if [[ -z "$ct_id" ]]; then
        ct_id="$(find_ct_id_by_hostname)"
    fi
    [[ -n "$ct_id" ]] || die "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden."
    CT_ID="$ct_id"
    warn "Container ${ct_id} (${CT_HOSTNAME}) wird gelöscht – ALLE Daten (Dokumente, DB, Postfach) gehen verloren!"
    confirm "Wirklich deinstallieren?" || { info "Abgebrochen."; exit 0; }
    run pct stop "$ct_id" || true
    run pct destroy "$ct_id" --purge
    ok "Container ${ct_id} gelöscht"
}

do_status() {
    header "Status"
    local ct_id="${CT_ID:-}"
    if [[ -z "$ct_id" ]]; then
        ct_id="$(find_ct_id_by_hostname)"
    fi
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '${CT_HOSTNAME}' gefunden."
        pct list | awk 'NR>1{print "  "$1"  "$NF}'
        exit 0
    fi
    CT_ID="$ct_id"
    local state ip
    state="$(pct status "$ct_id" 2>/dev/null | awk '{print $2}')"
    ip="$(get_ct_ip "$ct_id")"
    echo "  Container:  ${ct_id} (${CT_HOSTNAME}) – ${state:-unbekannt}"
    echo "  IP:         ${ip:-–}"
    if [[ "$state" != "running" ]]; then
        warn "Container läuft nicht – starte mit: pct start ${ct_id}"
        exit 0
    fi
    for u in postgresql redis-server papermark-s3 papermark-mailpit \
             papermark-upstash-bridge papermark papermark-ip-sync; do
        printf '  %-28s %s\n' "$u" "$(pct exec "$ct_id" -- systemctl is-active "$u" 2>/dev/null || echo unknown)"
    done
    local code
    code="$(pct exec "$ct_id" -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${UI_PORT}/login" 2>/dev/null || echo 000)"
    echo "  HTTP (login): ${code}"
    echo "  Web-UI:     http://${ip}:${UI_PORT}"
    echo "  Postfach:   http://${ip}:${MAILPIT_WEB_PORT}"
}

# ── Einstieg ───────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    header "${APP_DISPLAY} – Installer v${INSTALLER_VERSION} (Papermark ${UPSTREAM_REF:0:12})"
    if [[ "$STATUS_CHECK" == "true" ]]; then
        do_status
        exit 0
    fi
    if [[ "$UNINSTALL" == "true" ]]; then
        preflight
        do_uninstall
        exit 0
    fi
    if [[ "$UPDATE" == "true" ]]; then
        preflight
        do_update
        exit 0
    fi
    preflight
    do_install
}

main "$@"