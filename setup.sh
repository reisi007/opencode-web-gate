#!/usr/bin/env bash
# Einmaliges Setup: .env erzeugen, Secret + Passwort-Hash setzen, Deps pruefen.
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FEHLT: $1"; MISSING=1; }; }
MISSING=0
need ssh; need docker; need python3; need openssl
# rsync: macOS liefert per Default /usr/bin/rsync = openrsync (Protokoll 29), das
# --chown/--chmod nicht kann — local/sync.sh bricht dann hart ab. Also schon hier
# die GNU-Variante pruefen. WICHTIG: nicht per `rsync --version | grep -q ...`:
# unter `set -o pipefail` beendet `grep -q` den Upstream per SIGPIPE, die
# Pipeline gilt als fehlgeschlagen und der Guard schlaegt IMMER an.
_rsync_version="$(command -v rsync >/dev/null 2>&1 && rsync --version 2>/dev/null | head -1 || true)"
if [[ "$_rsync_version" != "rsync  version"* ]]; then
  echo "FEHLT: GNU-rsync (macOS-Default ist openrsync) -> brew install rsync"
  MISSING=1
fi
unset _rsync_version
if ! command -v autossh >/dev/null 2>&1; then
  echo "HINWEIS: autossh fehlt -> local/bootstrap.sh (bzw. brew install autossh) installiert es"
  echo "          und richtet den LaunchAgent ein; ohne autossh kein Reconnect im Tunnel."
fi
if [ "${MISSING:-0}" = 1 ]; then echo "Bitte fehlende Tools installieren."; exit 1; fi

[ -f .env ] || cp .env.example .env
# shellcheck disable=SC1091
source .env

gen_secret() { openssl rand -hex 32; }

if [ -z "${AUTH_SECRET:-}" ]; then
  S=$(gen_secret)
  if grep -q '^AUTH_SECRET=$' .env; then
    sed -i '' "s/^AUTH_SECRET=$/AUTH_SECRET=$S/" .env
  else
    echo "AUTH_SECRET=$S" >> .env
  fi
  echo "AUTH_SECRET generiert."
fi

if [ -z "${AUTH_HASH:-}" ]; then
  echo "--- Single-User Credentials ---"
  read -r -p "Benutzername [${AUTH_USER:-admin}]: " U
  U=${U:-${AUTH_USER:-admin}}
  sed -i '' "s/^AUTH_USER=.*/AUTH_USER=$U/" .env
  read -r -s -p "Passwort: " P; echo
  if [ -z "$P" ]; then echo "Leeres Passwort abgebrochen."; exit 1; fi
  echo "Hashe via lokalem Caddy-Container..."
  if HASH=$(docker run --rm caddy:2 caddy hash-password --plaintext "$P" 2>/dev/null); then
    # $ maskieren ist nicht noetig (.env wird nicht von Compose expandiert bei single quotes? doch -> single quotes nutzen)
    sed -i '' "s|^AUTH_HASH=.*|AUTH_HASH='$HASH'|" .env
    echo "AUTH_HASH (bcrypt via caddy) gesetzt."
  else
    echo "Docker-Caddy fehlgeschlagen, nutze PBKDF2-Fallback (Stdlib, kein pip noetig)."
    HASH=$(python3 -c "import hashlib,secrets; p=input(); s=secrets.token_hex(16); print('pbkdf2\$100000\$'+s+'\$'+hashlib.pbkdf2_hmac('sha256',p.encode(),bytes.fromhex(s),100000).hex())" <<< "$P")
    sed -i '' "s|^AUTH_HASH=.*|AUTH_HASH='$HASH'|" .env
    echo "AUTH_HASH (pbkdf2) gesetzt."
  fi
  unset P HASH
fi

if [ -z "${OPENCODE_PASSWORD:-}" ]; then
  P=$(openssl rand -base64 24)
  if grep -q '^OPENCODE_PASSWORD=$' .env; then
    sed -i '' "s/^OPENCODE_PASSWORD=$/OPENCODE_PASSWORD=$P/" .env
  else
    echo "OPENCODE_PASSWORD=$P" >> .env
  fi
  echo "OPENCODE_PASSWORD generiert (fuer opencode serve; Caddy injiziert es per Header upstream)."
  unset P
fi

echo "--- Checks ---"
# Sync-Ziel: kein rclone-Config mehr, aber SSH-Zugang + Zielverzeichnis müssen
# stehen. BatchMode, damit der Check nicht an einer Passphrase-Prompt hängt.
SYNC_ROOT="${SYNC_SITES_ROOT:-/home/webadmin/websites}"
SYNC_SITE="${SYNC_SITE_DIR:-code.example.com}"
if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "${SSH_PORT:-22}" \
     "${SSH_TARGET:?FEHLER: SSH_TARGET fehlt in .env}" \
     "test -d '$SYNC_ROOT/$SYNC_SITE'" 2>/dev/null; then
  echo "Sync-Ziel ok (${SSH_TARGET}:$SYNC_ROOT/$SYNC_SITE)"
else
  echo "WARN: Sync-Ziel ${SSH_TARGET}:$SYNC_ROOT/$SYNC_SITE nicht erreichbar (SSH-Key? Verzeichnis? noch nie gesynct?)"
fi
if getent hosts "${CODE_DOMAIN:-code.example.com}" >/dev/null 2>&1 || dscacheutil -q host -a name "${CODE_DOMAIN:-code.example.com}" >/dev/null 2>&1; then
  echo "DNS ${CODE_DOMAIN:-code.example.com} ok"
else
  echo "WARN: DNS ${CODE_DOMAIN:-code.example.com} loest nicht auf -> A-Record auf VPS setzen"
fi
echo "Fertig. Naechste Schritte siehe README (Portainer-Stack + Caddyfile-Fragment + ./local/start-tunnel.command)."
