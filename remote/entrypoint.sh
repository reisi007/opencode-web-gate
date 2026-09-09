#!/usr/bin/env bash
# entrypoint.sh: sichtet Volumes (gh-Auth bleibt!), startet opencode serve.
set -euo pipefail

# DOCKER_HOST kommt aus Compose (tcp://dind:2375). Lokal ohne Sidecar: unset lassen.
if [ -n "${DOCKER_HOST:-}" ]; then
  echo "DOCKER_HOST=$DOCKER_HOST"
fi

# Sicherstellen, dass gemountete Volumes dem dev-User gehoeren (Portainer Named Volumes = root bei Erststart)
for d in "$HOME/.config/gh" "$HOME/.ssh" "$HOME/.local/share/opencode" "$HOME/.config/opencode" /projects; do
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

BIN="$(command -v opencode2 || command -v opencode || command -v opencode-serve-bin || true)"
if [ -z "$BIN" ]; then
  echo "FEHLER: kein opencode2-Binary gefunden"; exit 1
fi

# opencode serve erzwingt Serverpasswort (wie Mac-Setup in run.sh).
if [ -z "${OPENCODE_SERVER_PASSWORD:-${OPENCODE_PASSWORD:-}}" ]; then
  echo "FEHLER: OPENCODE_SERVER_PASSWORD (oder OPENCODE_PASSWORD) fehlt (Portainer-Env)"; exit 1
fi
export OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$OPENCODE_PASSWORD}"

PORT="${PORT:-8080}"
echo "Starte: $BIN serve --hostname 0.0.0.0 --port $PORT (workdir /projects)"
exec "$BIN" serve --hostname 0.0.0.0 --port "$PORT"
