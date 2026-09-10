#!/usr/bin/env bash
# finish-setup.sh: bereitet Portainer-Deploy + Caddy-Snippets aus lokaler .env vor.
# - Kein SSH noetig (VPS-Schritte als Copy-Paste ausgegeben, du fuehrst sie aus).
# - Liest AUSSCHLIESSLICH .env (nie committen, steht in .gitignore).
# - Schreibt echte Secrets NUR nach /tmp (nie ins Repo).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

[ -f .env ] || { echo ".env fehlt -> ./setup.sh"; exit 1; }
# shellcheck disable=SC1091
set -a; source .env; set +a

strip_q() { local v="$1"; v="${v#\'}"; v="${v%\'}"; v="${v#\"}"; v="${v%\"}"; printf '%s' "$v"; }

AUTH_USER="$(strip_q "${AUTH_USER:-admin}")"
AUTH_HASH="$(strip_q "${AUTH_HASH:-}")"
AUTH_SECRET="$(strip_q "${AUTH_SECRET:-}")"
OPENCODE_PASSWORD="$(strip_q "${OPENCODE_PASSWORD:-}")"
SESSION_TTL="${SESSION_TTL:-43200}"
IMAGE="${IMAGE:-ghcr.io/reisi007/opencode-web-dev-baseline:latest}"
CODE_DOMAIN="$(strip_q "${CODE_DOMAIN:-code.example.com}")"
REMOTE_DOMAIN="$(strip_q "${REMOTE_DOMAIN:-remote-code.example.com}")"
CODE_SITE="$(strip_q "${CODE_SITE:-code.example.com}")"
ADMIN_EMAIL="$(strip_q "${ADMIN_EMAIL:-admin@example.com}")"
SSH_TARGET="$(strip_q "${SSH_TARGET:-user@vps.example.com}")"

fail=0
[ -n "$AUTH_HASH" ] || { echo "FEHLER: AUTH_HASH leer in .env"; fail=1; }
[ -n "$AUTH_SECRET" ] || { echo "FEHLER: AUTH_SECRET leer in .env"; fail=1; }
[ -n "$OPENCODE_PASSWORD" ] || { echo "FEHLER: OPENCODE_PASSWORD leer in .env"; fail=1; }
[ "$fail" = 1 ] && exit 1

# Repo auf eingecheckte Secrets/Prod-URLs pruefen (Platzhalter sind ok, echte Werte nicht)
if git grep -n 'header_up Authorization "Basic ' -- local remote setup.sh finish-setup.sh 2>/dev/null | grep -v __OPENCODE_BASIC__; then
  echo "FEHLER: echter Basic-Hash im Repo gefunden — entfernen."; exit 1
fi
if git grep -nE 'all-the\.rest|reisinger\.pictures' -- local remote setup.sh run.sh diagnose.sh sync.sh .env.example 2>/dev/null; then
  echo "FEHLER: echte Prod-URL im Repo gefunden — scrubben."; exit 1
fi
if git ls-files --error-unmatch .bla >/dev/null 2>&1; then
  echo "FEHLER: .bla noch getrackt (git rm .bla)."; exit 1
fi

BASIC=$(printf 'opencode:%s' "$OPENCODE_PASSWORD" | base64)
export OPENCODE_BASIC="$BASIC"

# .env.production: globales Env fuer Portainer (gitignored, nie committen).
# Quelle: .env — Datei einfach 1:1 in Portainer (Stack -> Environment) pasten.
{
  echo "# Generiert von ./finish-setup.sh aus .env — gitignored, nur in Portainer pasten."
  echo "AUTH_USER=$AUTH_USER"
  echo "AUTH_HASH=$AUTH_HASH"
  echo "AUTH_SECRET=$AUTH_SECRET"
  echo "OPENCODE_PASSWORD=$OPENCODE_PASSWORD"
  echo "SESSION_TTL=$SESSION_TTL"
  echo "IMAGE=$IMAGE"
} > remote/.env.production
chmod 600 remote/.env.production
echo "remote/.env.production geschrieben (gitignored)."

fill() { # $1=src $2=dst: alle Platzhalter aus .env ersetzen (Secrets nur nach /tmp)
  sed -e "s|__OPENCODE_BASIC__|${BASIC}|g" \
      -e "s|__CODE_DOMAIN__|${CODE_DOMAIN}|g" \
      -e "s|__REMOTE_DOMAIN__|${REMOTE_DOMAIN}|g" \
      -e "s|__CODE_SITE__|${CODE_SITE}|g" \
      "$1" > "$2"
}

fill local/Caddyfile.fragment /tmp/Caddyfile.code.snippet
fill remote/Caddyfile.fragment /tmp/Caddyfile.remote.snippet

# Caddy-Syntax lokal pruefen (braucht nur docker, kein SSH).
# Fragmente nutzen zentrale Snippets -> Stubs voranstellen.
for f in /tmp/Caddyfile.code.snippet /tmp/Caddyfile.remote.snippet; do
  {
    printf '{\n\temail %s\n}\n\n(security_headers) {\n\theader X-Test test\n}\n(compress) {\n\tencode gzip\n}\n\n' "$ADMIN_EMAIL"
    cat "$f"
  } > /tmp/Caddyfile.check
  # HINWEIS: Check-Datei liegt im Repo-Verz (Docker Desktop/ Rancher mountet /tmp vom Mac nicht).
  cp /tmp/Caddyfile.check ./.__caddy_check
  docker run --rm -v "$PWD/.__caddy_check:/etc/caddy/Caddyfile:ro" caddy:2 \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  rm -f ./.__caddy_check
  echo "Caddy-Check ok: $f"
done

cat <<EOF
================================================================
Portainer-Stack code-remote: remote/.env.production wurde erzeugt
(gitignored, globales Env 1:1 in Portainer pasten):
----------------------------------------------------------------

Caddy-Snippets (mit echten Werten, nur lokal in /tmp):
  /tmp/Caddyfile.code.snippet    -> $CODE_DOMAIN (Mac-Tunnel)
  /tmp/Caddyfile.remote.snippet  -> $REMOTE_DOMAIN (VPS-nativ)
Jeweils ins caddyfile-Repo (Caddyfile) uebernehmen, dort ./sync.sh.

VPS-Handgriffe (deine Shell, $SSH_TARGET):
  docker network create code-remote
  # deployment/docker-compose.yml: caddy zusaetzlich in code-remote haengen, redeployen
  # DNS: $REMOTE_DOMAIN A-Record auf VPS
Danach: https://$REMOTE_DOMAIN/login.html
Erster gh-Login: per Portainer-Console oder: docker exec -it code-dev gh auth login
================================================================
EOF
