#!/usr/bin/env bash
# =============================================================================
#  🧪 Papermark-Proxmox – Mock-Harness
#  Testet install/papermark.sh gegen eine gemockte Proxmox-Umgebung, ohne dass
#  ein Container angefasst wird:
#    - pct/pveam/pvesm/pveversion als Mocks in einem Fakebin-Verzeichnis
#    - der Inner-Installer wird NICHT ausgeführt (nur sein Aufruf protokolliert)
#    - zusätzlich: der Patch-Generator aus dem Inner-Skript wird gegen synthetische
#      Fixtures laufen gelassen (Pflicht-Anker vorhanden / Anker fehlt → Abbruch)
#  Usage: bash harness/run.sh [-v]      (Exit 0 = alle Cases grün)
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(dirname "$HERE")"
APP_NAME="papermark"
SCRIPT="$REPO/install/papermark.sh"
INNER="$REPO/install/papermark-inner.sh"

[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }
[[ -f "$INNER"  ]] || { echo "✘ Inner-Skript nicht gefunden: $INNER"; exit 1; }

MK="$(mktemp -d /tmp/papermark-harness.XXXXXX)"
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT

HS="$MK/state"
BIN="$MK/bin"
CASES="$MK/cases"
mkdir -p "$HS" "$BIN" "$CASES"

HOST_ARCH="$(uname -m)"; case "$HOST_ARCH" in x86_64) HOST_ARCH=amd64;; aarch64) HOST_ARCH=arm64;; esac
CT_IP="10.120.5.77"

PASSED=0; FAILED=0; CUR=""; DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR – $1"; }
warn() { echo "  ⚠ $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }
t()    { CUR="$1"; DIR="$(mktemp -d "$CASES/case.XXXXXX")"; }

assert_exit()  { if [[ "$2" == "$1" ]]; then pass "exit=$2"; else fail "exit=$2, erwartet $1"; fi; }
assert_out()   { if /bin/grep -qF -- "$1" "$DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"; else fail "Ausgabe enthält nicht: $1"; fi; }
assert_no_out(){ if /bin/grep -qF -- "$1" "$DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"; else pass "Ausgabe enthält nicht: $1"; fi; }
assert_calls() { local n; n=$(/bin/grep -cF -- "$2" "$HS/calls.log" 2>/dev/null || true); if [[ "${n:-0}" -ge "$1" ]]; then pass "Calls ≥$1: $2 ($n)"; else fail "Calls <$1: $2 ($n)"; fi; }
assert_file()  { if [[ -f "$1" ]]; then pass "Datei: ${1#$MK/}"; else fail "Datei fehlt: ${1#$MK/}"; fi; }

# ── Mocks ──────────────────────────────────────────────────────────────────
cat > "$BIN/pct" <<'MOCK'
#!/usr/bin/env bash
HS="$PAPERMARK_HARNESS_STATE"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    [[ -f "$HS/ct_list" ]] && cat "$HS/ct_list"
    exit 0
    ;;
  status)
    id="${1:-}"
    if [[ -f "$HS/ct_list" ]] && awk '{print $1}' "$HS/ct_list" | grep -qx "$id"; then
      echo "status: running"
      exit 0
    fi
    echo "status: stopped" >&2
    exit 1
    ;;
  create)
    id="${1:-}"; shift || true
    host="$(printf '%s\n' "$*" | grep -oE -- '--hostname [^ ]+' | head -1 | awk '{print $2}')"
    echo "$id running webserver ${host:-papermark}" >> "$HS/ct_list"
    printf '%s\n' "$*" > "$HS/create_args.txt"
    echo "  (mock) CT $id angelegt"
    ;;
  start)   echo "  (mock) CT ${1:-} gestartet" ;;
  stop)    echo "  (mock) CT ${1:-} gestoppt" ;;
  destroy) echo "  (mock) CT ${1:-} gelöscht" ;;
  push)
    mkdir -p "$HS/pushed"
    cp "${2:-}" "$HS/pushed/$(basename "${3:-nofile}")" 2>/dev/null || true
    echo "  (mock) Datei gepusht"
    ;;
  exec)
    id="${1:-}"; shift || true
    [[ "${1:-}" == "--" ]] && shift || true
    # Aufruf des Inner-Skripts: nur protokollieren, nicht ausführen
    if [[ "$*" == *"bash /tmp/papermark-inner.sh"* ]]; then
      printf '%s\n' "$*" > "$HS/inner_env.txt"
      echo "  (mock) Inner-Skript ausgeführt"
      exit 0
    fi
    case "$*" in
      *"test -f /etc/papermark/s3.env"*|*"test -f /var/log/papermark-setup.log"*)
        # Marker für "im Container steckt schon Papermark / abgebrochener Versuch"
        [[ -f "$HS/has_marker" ]] && exit 0
        exit 1
        ;;
      *"hostname -I"*)                   echo "$PAPERMARK_HARNESS_IP" ;;
      *"systemctl is-active papermark"*) echo "active" ;;
      *"curl -s -o /dev/null -w"*)       echo "200" ;;
      *"/api/health"*)                  echo '{"status":"ok","message":"All systems operational"}' ;;
      *"systemctl is-active"*)           echo "active" ;;
      *) : ;;
    esac
    ;;
  *) echo "  (mock) pct $*" ;;
esac
MOCK

cat > "$BIN/pveam" <<MOCK
#!/usr/bin/env bash
HS="\$PAPERMARK_HARNESS_STATE"
echo "pveam \$*" >> "\$HS/calls.log"
cmd="\${1:-}"; shift || true
case "\$cmd" in
  list)
    echo "local:vztmpl/debian-13-standard_13.0-1_${HOST_ARCH}.tar.zst   210MB"
    ;;
  download)
    echo "local:vztmpl/\${2}_13.0-1_${HOST_ARCH}.tar.zst   210MB" >> "\$HS/ct_list.templates"
    echo "  (mock) Template \${2} geladen"
    ;;
esac
MOCK

cat > "$BIN/pvesm" <<'MOCK'
#!/usr/bin/env bash
echo "pvesm $*" >> "$PAPERMARK_HARNESS_STATE/calls.log"
cat <<'EOF'
Name             Type     Status     Total            Used       Available        Progress
local            dir      active    500.00 GiB      100.00 GiB    400.00 GiB            N/A
local-lvm        lvmthin  active    500.00 GiB      100.00 GiB    400.00 GiB            N/A
EOF
MOCK

cat > "$BIN/pveversion" <<'MOCK'
#!/usr/bin/env bash
echo "pveversion $*" >> "$PAPERMARK_HARNESS_STATE/calls.log"
echo "pve-manager: 8.4.1"
MOCK

cat > "$BIN/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock: kopiert ein lokales Fixture als "Download" (kein Netz im Harness)
HS="$PAPERMARK_HARNESS_STATE"
out=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out="$a"
    prev="$a"
done
if [[ -n "$out" ]]; then
    cp "$HS/fake-inner.sh" "$out" 2>/dev/null || printf '#!/usr/bin/env bash\n' > "$out"
fi
exit 0
MOCK

chmod +x "$BIN"/*
export PAPERMARK_HARNESS_STATE="$HS"
export PAPERMARK_HARNESS_IP="$CT_IP"
export PATH="$BIN:$PATH"

reset_state() {
    rm -f "$HS/calls.log" "$HS/ct_list" "$HS/create_args.txt" "$HS/inner_env.txt"
    rm -rf "$HS/pushed"
    mkdir -p "$HS/pushed"
}

run_script() { # args… → stdout+stderr in $DIR/out.log, Exit-Code in $DIR/rc
    local start=$SECONDS
    # unshare -rm mappt den Harness-Nutzer auf root (EUID-Prüfung des Scripts)
    unshare -rm bash "$SCRIPT" "$@" > "$DIR/out.log" 2>&1
    echo "$?" > "$DIR/rc"
    echo "  (Dauer: $((SECONDS-start))s)"
}

echo "════════════════════════════════════════════════════════════"
echo " 🧪 Papermark-Proxmox – Mock-Harness"
echo "════════════════════════════════════════════════════════════"

# ── 1. Statische Checks ────────────────────────────────────────────────────
t "Statische Checks"
if bash -n "$SCRIPT" 2>"$DIR/err.log"; then pass "papermark.sh: bash -n"; else fail "papermark.sh: bash -n"; cat "$DIR/err.log"; fi
if bash -n "$INNER"  2>>"$DIR/err.log"; then pass "papermark-inner.sh: bash -n"; else fail "papermark-inner.sh: bash -n"; cat "$DIR/err.log"; fi
if /bin/grep -q "set -Eeuo pipefail" "$SCRIPT"; then pass "Host: set -Eeuo pipefail"; else fail "Host: set -Eeuo pipefail fehlt"; fi
if /bin/grep -q "set -Eeuo pipefail" "$INNER"; then pass "Inner: set -Eeuo pipefail"; else fail "Inner: set -Eeuo pipefail fehlt"; fi
if /bin/grep -q "trap 'on_error" "$SCRIPT"; then pass "Host: Fehlerketten-Trap"; else fail "Host: Fehlerketten-Trap fehlt"; fi
if /bin/grep -q "trap 'on_error" "$INNER"; then pass "Inner: Fehlerketten-Trap"; else fail "Inner: Fehlerketten-Trap fehlt"; fi
if /bin/grep -q 'exec > >(tee' "$INNER"; then pass "Inner: komplettes Log mitgeschnitten"; else fail "Inner: Log-Teiler fehlt"; fi

# ── 2. --help ──────────────────────────────────────────────────────────────
reset_state
t "--help"
run_script --help
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "Papermark – Proxmox-Installer"
assert_out "Continue with email"

# ── 3. Unbekannte Option ───────────────────────────────────────────────────
reset_state
t "Unbekannte Option"
run_script --gibtsnicht
assert_out "Unbekannte Option"

# ── 4. Port-Validierung ────────────────────────────────────────────────────
reset_state
t "Port-Validierung"
run_script --port 0
assert_out "Ungültiger Port"
reset_state
run_script --port 3000 --mailpit-port 3000
assert_out "dürfen nicht identisch sein"
reset_state
run_script --memory 100
assert_out "Ungültiger RAM"

# ── 5. --status ohne Container ─────────────────────────────────────────────
reset_state
t "Status ohne Container"
run_script --status
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "Kein Container mit Hostname 'papermark' gefunden"

# ── 6. --uninstall ohne Container ──────────────────────────────────────────
reset_state
t "Deinstall ohne Container"
run_script --uninstall --yes
assert_out "Kein Container mit Hostname 'papermark' gefunden"

# ── 7. --dry-run legt nichts an ────────────────────────────────────────────
reset_state
t "Dry-Run"
run_script --dry-run --yes
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "DRY-RUN"
if [[ -f "$HS/ct_list" ]]; then fail "Dry-Run hat einen Container angelegt"; else pass "Dry-Run legt keinen Container an"; fi

# ── 8. Voller Installationslauf (gemockt) ──────────────────────────────────
reset_state
t "Installation (gemockt)"
run_script --id 210 --hostname papermark --yes
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "Container 210 angelegt"
assert_out "Verifikation"
assert_out "Web-UI antwortet im Container mit HTTP 200"
assert_calls 1 "pct create 210"
assert_calls 1 "pct push 210"
assert_calls 1 "papermark-inner.sh"
if /bin/grep -q -- "--rootfs local-lvm:20" "$HS/create_args.txt" 2>/dev/null; then pass "create: rootfs local-lvm:20"; else fail "create: rootfs falsch"; fi
if /bin/grep -q -- "--memory 6144" "$HS/create_args.txt" 2>/dev/null; then pass "create: memory 6144"; else fail "create: memory falsch"; fi
if /bin/grep -q -- "--cores 4" "$HS/create_args.txt" 2>/dev/null; then pass "create: cores 4"; else fail "create: cores falsch"; fi
if /bin/grep -q -- "--onboot 1" "$HS/create_args.txt" 2>/dev/null; then pass "create: onboot 1"; else fail "create: onboot fehlt"; fi
if /bin/grep -q -- "--unprivileged 1" "$HS/create_args.txt" 2>/dev/null; then pass "create: unprivilegiert"; else fail "create: unprivilegiert fehlt"; fi
if /bin/grep -q -- "--net0 name=eth0,bridge=vmbr0,ip=dhcp" "$HS/create_args.txt" 2>/dev/null; then pass "create: Netzwerk"; else fail "create: Netzwerk falsch"; fi
if /bin/grep -q "PORT=3000" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: PORT=3000"; else fail "Inner-Aufruf: PORT fehlt"; fi
if /bin/grep -q "MAILPIT_WEB_PORT=8025" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: MAILPIT_WEB_PORT=8025"; else fail "Inner-Aufruf: MAILPIT_WEB_PORT fehlt"; fi
if /bin/grep -q "REPO_REF=bb93cfd0" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: gepinnter Ref"; else fail "Inner-Aufruf: REPO_REF fehlt"; fi

# ── 9. Benutzerdefinierte Werte ────────────────────────────────────────────
reset_state
t "Optionen durchgereicht"
run_script --id 4711 --hostname pm-test --cores 6 --memory 8192 --swap 4096 --rootfs 30 \
           --bridge vmbr1 --ip 192.168.178.50/24 --gateway 192.168.178.1 --port 3100 \
           --mailpit-port 8100 --yes
assert_exit 0 "$(cat "$DIR/rc")"
for needle in "--cores 6" "--memory 8192" "--swap 4096" "--rootfs local-lvm:30" \
              "--net0 name=eth0,bridge=vmbr1,ip=192.168.178.50/24" "--gw 192.168.178.1"; do
    if /bin/grep -qF -- "$needle" "$HS/create_args.txt" 2>/dev/null; then pass "create: $needle"; else fail "create: $needle fehlt"; fi
done
if /bin/grep -q "PORT=3100" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: PORT=3100"; else fail "Inner-Aufruf: PORT=3100 fehlt"; fi
if /bin/grep -q "MAILPIT_WEB_PORT=8100" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: MAILPIT_WEB_PORT=8100"; else fail "Inner-Aufruf: MAILPIT_WEB_PORT=8100 fehlt"; fi

# ── 10. Hostname-Konflikt ohne --force ─────────────────────────────────────
reset_state
echo "211 running webserver papermark" >> "$HS/ct_list"
echo "999 running webserver webserver" >> "$HS/ct_list"
t "Hostname-Konflikt"
run_script --hostname papermark --yes
assert_out "Hostname 'papermark' ist bereits vergeben"

# ── 11. --update auf nicht vorhandenem Container ───────────────────────────
reset_state
t "Update ohne Container"
run_script --update --yes
assert_out "Kein Container mit Hostname 'papermark' gefunden"

# ── 12. Update auf vorhandenem Container ───────────────────────────────────
reset_state
echo "210 running webserver papermark" >> "$HS/ct_list"
t "Update mit Container"
run_script --update --yes
assert_exit 0 "$(cat "$DIR/rc")"
assert_calls 1 "papermark-inner.sh"
if /bin/grep -q "UPDATE=1" "$HS/inner_env.txt" 2>/dev/null; then pass "Inner-Aufruf: UPDATE=1"; else fail "Inner-Aufruf: UPDATE=1 fehlt"; fi

# ── 13. Architektur-Mismatch (arm64-Template auf amd64-Host) ───────────────
reset_state
if [[ "$HOST_ARCH" == "amd64" ]]; then
    cat > "$BIN/pveam" <<'MOCK'
#!/usr/bin/env bash
HS="$PAPERMARK_HARNESS_STATE"
echo "pveam $*" >> "$HS/calls.log"
echo "local:vztmpl/debian-13-standard_13.0-1_arm64.tar.zst   210MB"
MOCK
    chmod +x "$BIN/pveam"
    t "Architektur-Mismatch"
    run_script --id 222 --yes
    assert_out "Kein passendes Debian-Template für"
    # Mock wiederherstellen
    cat > "$BIN/pveam" <<MOCK
#!/usr/bin/env bash
HS="\$PAPERMARK_HARNESS_STATE"
echo "pveam \$*" >> "\$HS/calls.log"
echo "local:vztmpl/debian-13-standard_13.0-1_${HOST_ARCH}.tar.zst   210MB"
MOCK
    chmod +x "$BIN/pveam"
fi

# ── 11b. Idempotenz: Container mit vorhandener Installation wiederverwenden ─
reset_state
echo "211 running webserver papermark" >> "$HS/ct_list"
: > "$HS/has_marker"
t "Idempotenter Re-Run"
run_script --yes
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "enthält bereits Papermark"
assert_calls 1 "papermark-inner.sh"
if /bin/grep -q "pct create" "$HS/calls.log" 2>/dev/null; then
    fail "Container wurde trotz vorhandener Installation neu angelegt"
else
    pass "kein pct create (Container wiederverwendet)"
fi

# ── 13b. Host-Download des Inner-Skripts (nacktes Template ohne curl) ──────
reset_state
mkdir -p "$MK/standalone"
cp "$SCRIPT" "$MK/standalone/${APP_NAME}.sh"
printf '#!/usr/bin/env bash\necho inner-fake\n' > "$HS/fake-inner.sh"
t "Host-Download (curl im CT fehlt)"
start=$SECONDS
unshare -rm bash "$MK/standalone/${APP_NAME}.sh" --id 222 --yes > "$DIR/out.log" 2>&1
echo "$?" > "$DIR/rc"
echo "  (Dauer: $((SECONDS-start))s)"
assert_exit 0 "$(cat "$DIR/rc")"
assert_out "auf dem Proxmox-Host"
assert_out "Übertrage papermark-inner.sh in den Container"
assert_calls 1 "pct push 222"
if /bin/grep -q "curl -fsSL" "$HS/calls.log" 2>/dev/null; then
    fail "curl wurde im Container ausgeführt (soll nicht)"
else
    pass "kein curl-Aufruf im Container"
fi

# ── 14. Patch-Fixtures (Anker-Drift im Inner-Skript) ───────────────────────
t "Patch-Fixtures"
if command -v node >/dev/null 2>&1; then
    if node "$HERE/test-patches.mjs" "$INNER" > "$DIR/out.log" 2>&1; then
        pass "Patch-Fixtures grün"
    else
        fail "Patch-Fixtures rot"
        tail -n 6 "$DIR/out.log" | sed 's/^/      /'
    fi
else
    warn "node fehlt – Patch-Fixtures übersprungen"
fi

echo
echo "════════════════════════════════════════════════════════════"
echo "  Ergebnis: ${PASSED} ✔  /  ${FAILED} ✘"
echo "════════════════════════════════════════════════════════════"
[[ "$FAILED" -eq 0 ]]