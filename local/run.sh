#!/usr/bin/env bash
# run.sh: Website syncen (rclone) + SSH-Reverse-Tunnel starten.
# Flags: --sync-only | --tunnel-only | (default: beides)
#
# WICHTIG (Tunnel-Ownership): Der Tunnel laeuft mit ControlMaster=no und wird von
# autossh ueberwacht — er haengt an KEINER Master-Connection. Sonst stirbt der
# Forward mit der Master-Connection, ohne dass autossh neu verbindet (das war
# die Ursache fuer "Tunnel liegt tot, obwohl autossh laeuft"). Die Master-
# Connection (ControlPersist) bleibt nur fuer Erfolgswaechter + diagnose.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Doppelklick (.command) startet mit minimalem PATH -> Werkzeuge auffindbar machen
export PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -f ../.env ]; then
  # shellcheck disable=SC1091
  source ../.env
elif [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
else
  echo ".env fehlt -> ../setup.sh"; exit 1
fi

MASTER_PATH='/tmp/ssh-code-%r@%h:%p'
TARGET="${SSH_TARGET:-user@vps.example.com}"
PORT="${SSH_PORT:-22}"
# Bind-Adresse des Forwards AUF DEM VPS: Docker-Bridge-Gateway (webnet: 172.18.0.1),
# damit der Caddy-Container (Bridge-Netz, eigener Loopback!) den Tunnel erreicht.
# Braucht serverseitig: GatewayPorts clientspecified (siehe README).
BIND="${REMOTE_BIND:-172.18.0.1}"
REMOTE="${REMOTE_PORT:-18731}"
LOCAL="${LOCAL_PORT:-8080}"
DIST="${LOCAL_DIST:-apps/web/dist}"
REMOTE_PATH="${RCLONE_REMOTE:-vps.example.com}:${RCLONE_PATH:-/code.example.com}"

# Key-Auth (setzt bootstrap.sh, Werte in .env): unbeaufsichtigter Betrieb ohne
# Passphrase-Prompt. UseKeychain=yes ist der Punkt, der den Key ohne TTY
# entsperrt — launchd startet ssh ohne Terminal, die Passphrase kommt aus der
# macOS-Keychain (einmalig via 'ssh-add --apple-use-keychain' hinterlegt).
KEY_OPTS=()
if [ "${SSH_KEY_AUTH:-0}" = 1 ] && [ -n "${SSH_IDENTITY:-}" ] && [ -f "$SSH_IDENTITY" ]; then
  KEY_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o UseKeychain=yes -i "$SSH_IDENTITY")
fi
# Waechter/Diagnose: eine Master-Connection, 60s Idle-Persist (1x Passphrase).
WATCH_OPTS=(-o ControlMaster=auto -o ControlPath="$MASTER_PATH" -o ControlPersist=60)
# Tunnel: eigene TCP-Verbindung, die autossh besitzt und neu aufbauen kann.
TUNNEL_OPTS=(-o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes)
if [ "${#KEY_OPTS[@]}" -gt 0 ]; then
  WATCH_OPTS+=("${KEY_OPTS[@]}")
  TUNNEL_OPTS+=("${KEY_OPTS[@]}")
fi

MODE="${1:-all}"
# Logs koennen Session-Inhalte enthalten -> nur fuer den Besitzer lesbar. Die plist
# setzt Umask 077, das greift aber nur bei NEUEN Dateien; bestehende aus einem
# frueheren Lauf bleiben sonst world-readable.
chmod 600 /tmp/code-tunnel.log 2>/dev/null || true
echo "[$(date '+%F %T')] run.sh start (Modus: $MODE, Key-Auth: $([ "${#KEY_OPTS[@]}" -gt 0 ] && echo ja || echo nein))"
# OpenCode-eigenes Serverpasswort (Pflicht): serve erzwingt Auth, Caddy injiziert
# es upstream per Header -> im Browser unsichtbar (de facto deaktiviert).
[ -n "${OPENCODE_PASSWORD:-}" ] || { echo "FEHLER: OPENCODE_PASSWORD fehlt in .env -> ./setup.sh"; exit 1; }
export OPENCODE_SERVER_PASSWORD="$OPENCODE_PASSWORD"
if [ "$MODE" != "--tunnel-only" ]; then
  ./sync.sh
fi
if [ "$MODE" != "--sync-only" ]; then
  # OpenCode-Web sicherstellen (Pflicht — nie manuell starten).
  # Ueber .env aenderbar: OPENCODE_CMD="..."
  OPENCODE_CMD="${OPENCODE_CMD:-opencode serve --hostname 127.0.0.1 --port $LOCAL}"
  if ! (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1; then
    echo "Starte OpenCode-Web: $OPENCODE_CMD"
    # shellcheck disable=SC2086
    $OPENCODE_CMD >>/tmp/code-tunnel-opencode.log 2>&1 &
    # Log kann Session-Inhalte enthalten -> nur fuer den Besitzer lesbar. Der
    # LaunchAgent setzt dafuer zusaetzlich Umask 077 in der plist.
    chmod 600 /tmp/code-tunnel-opencode.log 2>/dev/null || true
    for _ in $(seq 1 20); do
      (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1 && break
      sleep 1
    done
    (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1 \
      || { echo "FEHLER: OpenCode-Web lauscht nicht auf :$LOCAL (Log: /tmp/code-tunnel-opencode.log)"; exit 1; }
  else
    echo "OpenCode-Web laeuft bereits auf :$LOCAL."
  fi

  # Alte/verwaiste Tunnel-Instanzen beenden. Zwei ssh-Prozesse auf demselben
  # VPS-Port (BIND:REMOTE) machen sich gegenseitig die Bind kaputt
  # (ExitOnForwardFailure) — genau das erzeugt flackernde Tunnel.
  # Muster nur auf Forward + Ziel, nicht auf die Argumentreihenfolge: der
  # plain-ssh-Fallback hat -N hinter den Optionen, ein "ssh -N"-Muster trifft ihn
  # nicht und die verwaiste Instanz bleibt dann auf dem VPS-Port binden.
  tunnel_sig="-R $BIND:$REMOTE:127.0.0.1:$LOCAL"
  pkill -f -- "ssh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
  pkill -f -- "autossh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
  # Master-Connection sauber schliessen -> Control-Socket (/tmp/ssh-code-*) weg.
  # -p MUSS mit: %p im ControlPath wird sonst aus dem Default 22 expandiert und
  # die Bereinigung zeigt bei SSH_PORT != 22 auf den falschen Socket.
  ssh -S "$MASTER_PATH" -p "$PORT" -O exit "$TARGET" >/dev/null 2>&1 || true

  if [ "${#KEY_OPTS[@]}" -eq 0 ]; then
    # Ohne Key: Master-Connection vorab oeffnen, damit nur 1x nach der
    # Passphrase gefragt wird (Waechter + Diagnose multiplexen darauf).
    echo "Oeffne Master-Connection (1x Passphrase)..."
    ssh "${WATCH_OPTS[@]}" -fN -p "$PORT" "$TARGET"
  fi
  echo "Tunnel: $BIND:$REMOTE (VPS) <- 127.0.0.1:$LOCAL (Mac) via $TARGET:$PORT"
  # Erfolgswachter: meldet sobald der Forward am VPS lauscht (bei Key-Auth ohne
  # Passphrase via eigene Verbindung, sonst via Master).
  ( for _ in $(seq 1 30); do
      if ssh "${WATCH_OPTS[@]}" -p "$PORT" "$TARGET" "ss -tln 2>/dev/null | grep -q '$BIND:$REMOTE'"; then
        echo "Tunnel aktiv ($(date +%H:%M:%S)): VPS $BIND:$REMOTE -> Mac 127.0.0.1:$LOCAL — bereit: https://${CODE_DOMAIN:-code.example.com}/"
        exit 0
      fi
      sleep 2
    done
    echo "WARN: Forward nach 60s nicht auf VPS sichtbar — Log pruefen." ) &
  if command -v autossh >/dev/null 2>&1; then
    echo "Modus: autossh (Reconnect bei Netzverlust/Sleep)."
    AUTOSSH_PORT=0 autossh -M 0 -N "${TUNNEL_OPTS[@]}" -p "$PORT" \
      -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  else
    echo "WARN: autossh fehlt (brew install autossh) -> plain ssh, KEIN Reconnect."
    ssh "${TUNNEL_OPTS[@]}" -N -p "$PORT" -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  fi
fi
