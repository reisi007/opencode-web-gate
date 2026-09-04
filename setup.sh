#!/usr/bin/env bash
# Einmaliges Setup: .env erzeugen, Secret + Passwort-Hash setzen, Deps pruefen.
set -euo pipefail
cd "$(dirname "$0")"

need() { command -v "$1" >/dev/null 2>&1 || { echo "FEHLT: $1"; MISSING=1; }; }
MISSING=0
need ssh; need docker; need rclone; need python3; need openssl
if ! command -v autossh >/dev/null 2>&1; then
  echo "HINWEIS: autossh fehlt -> brew install autossh (sonst plain ssh Fallback in run.sh)"
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
  echo "OPENCODE_PASSWORD generiert (fuer opencode2 serve; Caddy injiziert es per Header upstream)."
  unset P
fi

echo "--- Checks ---"
rclone listremotes | grep -q "^${RCLONE_REMOTE:-reisinger.pictures}:$" \
  && echo "rclone remote ok" || echo "WARN: rclone remote '${RCLONE_REMOTE:-reisinger.pictures}:' fehlt (rclone config)"
if getent hosts "code.all-the.rest" >/dev/null 2>&1 || dscacheutil -q host -a name code.all-the.rest >/dev/null 2>&1; then
  echo "DNS code.all-the.rest ok"
else
  echo "WARN: DNS code.all-the.rest loest nicht auf -> A-Record auf VPS setzen"
fi
echo "Fertig. Naechste Schritte siehe README (Portainer-Stack + Caddyfile-Fragment + ./run.sh)."
