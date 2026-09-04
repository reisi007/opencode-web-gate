#!/usr/bin/env bash
# run.sh: Website syncen (rclone) + SSH-Reverse-Tunnel starten.
# Flags: --sync-only | --tunnel-only | (default: beides)
set -euo pipefail
cd "$(dirname "$0")"
# Doppelklick (.command) startet mit minimalem PATH -> Werkzeuge auffindbar machen
export PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
[ -f .env ] || { echo ".env fehlt -> ./setup.sh"; exit 1; }
# shellcheck disable=SC1091
source .env

SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-code-%r@%h:%p -o ControlPersist=60 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
TARGET="${SSH_TARGET:-root@reisinger.pictures}"
PORT="${SSH_PORT:-22}"
REMOTE="${REMOTE_PORT:-18731}"
LOCAL="${LOCAL_PORT:-8080}"
DIST="${LOCAL_DIST:-apps/web/dist}"
REMOTE_PATH="${RCLONE_REMOTE:-reisinger.pictures}:${RCLONE_PATH:-/code.all-the.rest}"

MODE="${1:-all}"
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
  echo "Tunnel: 127.0.0.1:$REMOTE (VPS) <- 127.0.0.1:$LOCAL (Mac) via $TARGET:$PORT"
  echo "Master-Connection oeffnen (1x Passphrase), dann Tunnel..."
  ssh $SSH_OPTS -fN -p "$PORT" "$TARGET"
  echo "SSH verbunden, baue Tunnel auf..."
  # Erfolgswachter: meldet sobald der Forward am VPS lauscht (via Master-Connection, keine neue Passphrase)
  ( for _ in $(seq 1 30); do
      if ssh $SSH_OPTS -p "$PORT" "$TARGET" "ss -tln 2>/dev/null | grep -q '127.0.0.1:$REMOTE'"; then
        echo "Tunnel aktiv ($(date +%H:%M:%S)): VPS 127.0.0.1:$REMOTE -> Mac 127.0.0.1:$LOCAL — bereit: https://code.all-the.rest/"
        exit 0
      fi
      sleep 2
    done
    echo "WARN: Forward nach 60s nicht auf VPS sichtbar — Log pruefen." ) &
  if command -v autossh >/dev/null 2>&1; then
    AUTOSSH_PORT=0 autossh -M 0 -N $SSH_OPTS -p "$PORT" \
      -R "127.0.0.1:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  else
    echo "WARN: autossh fehlt (brew install autossh), nutze plain ssh."
    ssh $SSH_OPTS -N -p "$PORT" -R "127.0.0.1:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  fi
fi
