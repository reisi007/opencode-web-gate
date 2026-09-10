#!/usr/bin/env bash
# run.sh: Website syncen (rclone) + SSH-Reverse-Tunnel starten.
# Flags: --sync-only | --tunnel-only | (default: beides)
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

SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-code-%r@%h:%p -o ControlPersist=60 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
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

MODE="${1:-all}"
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
  OPENCODE_CMD="${OPENCODE_CMD:-opencode2 serve --hostname 127.0.0.1 --port $LOCAL}"
  if ! (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1; then
    echo "Starte OpenCode-Web: $OPENCODE_CMD"
    # shellcheck disable=SC2086
    $OPENCODE_CMD >>/tmp/code-tunnel-opencode.log 2>&1 &
    for _ in $(seq 1 20); do
      (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1 && break
      sleep 1
    done
    (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1 \
      || { echo "FEHLER: OpenCode-Web lauscht nicht auf :$LOCAL (Log: /tmp/code-tunnel-opencode.log)"; exit 1; }
  else
    echo "OpenCode-Web laeuft bereits auf :$LOCAL."
  fi
  echo "Tunnel: $BIND:$REMOTE (VPS) <- 127.0.0.1:$LOCAL (Mac) via $TARGET:$PORT"
  echo "Master-Connection oeffnen (1x Passphrase), dann Tunnel..."
  ssh $SSH_OPTS -fN -p "$PORT" "$TARGET"
  echo "SSH verbunden, baue Tunnel auf..."
  # Erfolgswachter: meldet sobald der Forward am VPS lauscht (via Master-Connection, keine neue Passphrase)
  ( for _ in $(seq 1 30); do
      if ssh $SSH_OPTS -p "$PORT" "$TARGET" "ss -tln 2>/dev/null | grep -q '$BIND:$REMOTE'"; then
        echo "Tunnel aktiv ($(date +%H:%M:%S)): VPS $BIND:$REMOTE -> Mac 127.0.0.1:$LOCAL — bereit: https://${CODE_DOMAIN:-code.example.com}/"
        exit 0
      fi
      sleep 2
    done
    echo "WARN: Forward nach 60s nicht auf VPS sichtbar — Log pruefen." ) &
  if command -v autossh >/dev/null 2>&1; then
    AUTOSSH_PORT=0 autossh -M 0 -N $SSH_OPTS -p "$PORT" \
      -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  else
    echo "WARN: autossh fehlt (brew install autossh), nutze plain ssh."
    ssh $SSH_OPTS -N -p "$PORT" -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  fi
fi
