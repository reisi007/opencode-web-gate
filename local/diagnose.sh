#!/usr/bin/env bash
# diagnose.sh: lokale + VPS-Checks ueber EINE Master-SSH-Connection (1x Passphrase).
# Usage: ./diagnose.sh [--quick]
set -euo pipefail
cd "$(dirname "$0")"
if [ -f ../.env ]; then
  # shellcheck disable=SC1091
  source ../.env
elif [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
else
  echo ".env fehlt -> ../setup.sh"; exit 1
fi

SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-code-%r@%h:%p -o ControlPersist=60"
TARGET="${SSH_TARGET:-user@vps.example.com}"
PORT="${SSH_PORT:-22}"
REMOTE="${REMOTE_PORT:-18731}"
LOCAL="${LOCAL_PORT:-8080}"
QUICK="${1:-}"

ok() { echo "OK   $1"; }
warn() { echo "WARN $1"; }

echo "== lokal =="
command -v autossh >/dev/null 2>&1 && ok "autossh vorhanden" || warn "autossh fehlt (brew install autossh)"
(echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1 && ok "localhost:$LOCAL lauscht (OpenCode?)" \
  || warn "localhost:$LOCAL nicht erreichbar -> OpenCode-Web starten?"
sed -n '/cat > \/app\/auth.py << "PYEOF"/,/^        PYEOF$/p' docker-compose.yml \
  | sed '1d;$d' | sed 's/^        //' | sed 's/\$\$/\$/g' > /tmp/auth-inline-check.py
python3 -c "import py_compile; py_compile.compile('/tmp/auth-inline-check.py', doraise=True)" \
  && ok "Inline-auth.py kompiliert"

[ "$QUICK" = "--quick" ] && exit 0

echo "== VPS $TARGET =="
ssh $SSH_OPTS -p "$PORT" "$TARGET" \
  "REMOTE=$REMOTE" 'bash -s' <<'EOF'
set -u
echo "-- port --"
ss -tlnp 2>/dev/null | grep -q ":$REMOTE" && echo "OK   VPS $REMOTE lauscht (Tunnel oben)" \
  || echo "WARN VPS $REMOTE fehlt -> run.sh (Tunnel)"
echo "-- container --"
docker ps --format "{{.Names}} {{.Status}}" | grep -E "caddy|code-auth" || echo "WARN kein caddy/code-auth Container gefunden"
echo "-- webnet --"
docker network inspect webnet --format "{{range .Containers}}{{.Name}} {{.IPv4Address}} {{end}}" 2>/dev/null || echo "WARN webnet fehlt"
echo "-- http --"
curl -sk -o /dev/null -w "login.html %{http_code}\n" https://"${CODE_DOMAIN:-code.example.com}"/login.html
curl -sk -o /dev/null -w "root (ohne Cookie) %{http_code} (erwartet 302 auf /login.html)\n" https://"${CODE_DOMAIN:-code.example.com}"/
EOF
echo "Fertig."
