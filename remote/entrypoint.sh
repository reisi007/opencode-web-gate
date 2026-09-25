#!/usr/bin/env bash
# entrypoint.sh: sichtet Volumes (gh-Auth bleibt!), startet opencode serve.
set -euo pipefail

# DOCKER_HOST kommt aus Compose (tcp://dind:2375). Lokal ohne Sidecar: unset lassen.
if [ -n "${DOCKER_HOST:-}" ]; then
  echo "DOCKER_HOST=$DOCKER_HOST"
fi

# Sicherstellen, dass gemountete Volumes dem dev-User gehoeren (Portainer Named Volumes = root bei Erststart)
for d in "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.local/share/opencode" "$HOME/.config/opencode" "$HOME/.local/state/opencode" /projects; do
  if [ -e "$d" ] && [ ! -O "$d" ] 2>/dev/null; then
    sudo chown -R "$(id -u):$(id -g)" "$d" 2>/dev/null || true
  fi
done
chmod 700 "$HOME/.ssh" 2>/dev/null || true

if ! command -v gh >/dev/null 2>&1; then
  echo "WARN: gh fehlt im Image"
else
  if gh auth status >/dev/null 2>&1; then
    echo "gh auth: ok ($(gh api user --jq .login 2>/dev/null || echo 'login ok'))"
  else
    echo "gh auth: NICHT angemeldet -> einmalig: docker exec -it code-dev gh auth login"
  fi
fi

BIN="$(command -v opencode || command -v opencode2 || command -v opencode-serve-bin || true)"
if [ -z "$BIN" ]; then
  echo "FEHLER: kein opencode-Binary gefunden"; exit 1
fi

# Self-Update beim Containerstart (Default an, Opt-out via OPENCODE_AUTOUPDATE=false).
# Hintergrund: OPENCODE_DISABLE_AUTOUPDATE=true (s. Dockerfile) verhindert das
# In-Process-Autoupdate des Servers — gut im Container. Dafuer holt dieser Block
# einmalig beim Start das neueste Binary (V2 releast teils mehrmals taeglich;
# neue Abo-Modelle erscheinen erst mit neuerem Binary im Katalog). Schlaegt das
# Update fehl (z.B. kein Netz), startet der Container trotzdem mit dem Image-Stand.
# Das installierte Binary liegt auf dem Image-Layer (/usr/local/bin), daher per sudo.
update_opencode_binary() {
  # Arg: Pfad zum Binary. Return 0 = neues Binary installiert, 1 = aktuell/Fehler.
  local bin="$1"
  local current latest_meta latest_version upd_home
  current="$("$bin" --version 2>/dev/null || true)"
  latest_meta="$(curl -fsSL --max-time 20 https://opencode.ai/update/api/latest/cli/npm 2>/dev/null || true)"
  latest_version="$(printf '%s' "$latest_meta" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
  if [ -z "$latest_version" ]; then
    echo "opencode update: latest-Version nicht ermittelbar (Netz?) — weiter mit ${current:-unbekannt}"
    return 1
  fi
  if printf '%s' "$current" | grep -qF "$latest_version"; then
    return 1 # aktuell — bewusst ohne Log (Watcher laeuft mehrmals pro Stunde)
  fi
  echo "opencode update: ${current:-unbekannt} -> $latest_version"
  upd_home="$(mktemp -d)"
  if HOME="$upd_home" curl -fsSL --max-time 60 https://opencode.ai/v2/install | HOME="$upd_home" bash -s -- --no-modify-path >/tmp/opencode-update.log 2>&1 \
    && [ -x "$upd_home/.opencode/bin/opencode" ] \
    && sudo install -m 0755 "$upd_home/.opencode/bin/opencode" /usr/local/bin/opencode >>/tmp/opencode-update.log 2>&1; then
    echo "opencode update: installiert ($("$bin" --version 2>/dev/null || echo ok))"
    rm -rf "$upd_home"
    return 0
  fi
  echo "WARN: opencode update fehlgeschlagen (s. /tmp/opencode-update.log) — weiter mit Image-Stand"
  rm -rf "$upd_home"
  return 1
}

in_update_window() {
  # Arg: "VON-BIS" in Stunden, z.B. "5-21", "" = rund um die Uhr.
  # Containerzeit (Image-Default UTC). Return 0 = jetzt im Fenster.
  local spec="${1:-}"
  if [ -z "$spec" ]; then return 0; fi
  local from="${spec%%-*}"
  local to="${spec##*-}"
  case "$from$to" in ''|*[!0-9]*) return 0;; esac # ungueltig → immer
  local h
  h="$(date +%H)"
  h="${h#0}"
  if [ -z "$h" ]; then h=0; fi
  if [ "$from" -le "$to" ]; then
    if [ "$h" -ge "$from" ] && [ "$h" -lt "$to" ]; then return 0; else return 1; fi
  else
    if [ "$h" -ge "$from" ] || [ "$h" -lt "$to" ]; then return 0; else return 1; fi
  fi
}

server_idle() {
  # Return 0 = keine aktive Session (Neustart ok), 1 = busy/unbekannt (vertagen).
  # Auth per Basic wie Caddy upstream (User opencode + Serverpasswort).
  local pw="${OPENCODE_SERVER_PASSWORD:-${OPENCODE_PASSWORD:-}}"
  local resp count
  resp="$(curl -fsSL --http1.1 --max-time 10 -u "opencode:$pw" "http://127.0.0.1:${PORT:-8080}/api/session/active" 2>/dev/null || true)"
  if [ -z "$resp" ]; then echo "idle-check: API nicht erreichbar → vertagt"; return 1; fi
  count="$(printf '%s' "$resp" | python3 -c '
import json,sys
try:
  d = json.load(sys.stdin)
except Exception:
  print("ERR"); sys.exit(0)
data = d.get("data", d) if isinstance(d, dict) else d
# V2 liefert eine Map Session-ID -> Status; aeltere Builds nutzen eine Liste.
print(len(data) if isinstance(data, (dict, list)) else "ERR")
' 2>/dev/null || true)"
  if [ -z "$count" ] || [ "$count" = "ERR" ]; then echo "idle-check: Antwort unverstaendlich → vertagt"; return 1; fi
  if [ "$count" -gt 0 ]; then echo "idle-check: $count aktive Session(s) → vertagt"; return 1; fi
  return 0
}

watch_opencode_updates() {
  # Hintergrund-Watcher: prueft alle OPENCODE_UPDATE_INTERVAL Sekunden
  # (Default 1200 = 3x/Stunde) im Fenster OPENCODE_UPDATE_HOURS (Default "5-21",
  # Containerzeit/UTC) auf neue Releases. Bei Update + idle Server: SIGTERM an
  # PID 1 (serve, per exec unten) → Container stoppt → Restart-Policy startet
  # frisch mit neuem Binary. Bei busy Server: Neustart wird vertagt (oder per
  # OPENCODE_UPDATE_RESTART=always erzwungen).
  local bin="$1"
  local interval="${OPENCODE_UPDATE_INTERVAL:-1200}"
  case "$interval" in ''|*[!0-9]*) interval=1200;; esac
  if [ "$interval" -lt 300 ]; then interval=300; fi # Untergrenze 5 Min (Tippfehlerschutz)
  local hours="${OPENCODE_UPDATE_HOURS:-5-21}"
  local mode="${OPENCODE_UPDATE_RESTART:-idle}"
  echo "opencode watcher: alle ${interval}s im Fenster '${hours:-immer}' (Containerzeit), Neustart-Modus: $mode"
  while true; do
    sleep "$interval" &
    wait "$!" 2>/dev/null || true
    if ! in_update_window "$hours"; then continue; fi
    if update_opencode_binary "$bin"; then
      if [ "$mode" = "always" ]; then
        echo "opencode watcher: neues Binary → Container-Neustart (Modus always)"
        kill -TERM 1 2>/dev/null || true
        return 0
      fi
      if server_idle; then
        echo "opencode watcher: idle → Container-Neustart fuer neues Binary"
        kill -TERM 1 2>/dev/null || true
        return 0 # Restart-Policy uebernimmt; Watcher stirbt mit dem Container
      else
        echo "opencode watcher: neues Binary bereit, Neustart vertagt (Server busy)"
      fi
    fi
  done
}

if [ "${OPENCODE_AUTOUPDATE:-true}" = "true" ]; then
  update_opencode_binary "$BIN" || true
else
  echo "opencode update: deaktiviert (OPENCODE_AUTOUPDATE=false)"
fi

# CodeGraph-MCP automatisch verdrahten (nur opencode, global) — einmalig,
# danach Skip (Config liegt im Volume). Blockiert den Start nie.
if command -v codegraph >/dev/null 2>&1; then
  if grep -q codegraph "$HOME/.config/opencode/opencode.jsonc" 2>/dev/null; then
    echo "codegraph MCP: bereits verdrahtet"
  elif codegraph install --target opencode --location global --yes >/tmp/codegraph-install.log 2>&1; then
    echo "codegraph MCP: opencode verdrahtet"
  else
    echo "WARN: codegraph install fehlgeschlagen (s. /tmp/codegraph-install.log) — Start geht weiter"
  fi
fi

# opencode serve erzwingt Serverpasswort (wie Mac-Setup in run.sh).
if [ -z "${OPENCODE_SERVER_PASSWORD:-${OPENCODE_PASSWORD:-}}" ]; then
  echo "FEHLER: OPENCODE_SERVER_PASSWORD (oder OPENCODE_PASSWORD) fehlt (Portainer-Env)"; exit 1
fi
export OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$OPENCODE_PASSWORD}"

PORT="${PORT:-8080}"
# Watcher als Hintergrundprozess starten (ueberlebt das exec unten, da bereits
# geforkt). Er beendet bei Update+Idle PID 1 per SIGTERM → Restart-Policy startet
# den Container frisch mit neuem Binary. Ohne Autoupdate: direkt exec wie bisher.
if [ "${OPENCODE_AUTOUPDATE:-true}" = "true" ]; then
  watch_opencode_updates "$BIN" &
fi
echo "Starte: $BIN serve --hostname 0.0.0.0 --port $PORT (workdir /projects)"
exec "$BIN" serve --hostname 0.0.0.0 --port "$PORT"
