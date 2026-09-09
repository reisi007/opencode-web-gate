#!/usr/bin/env bash
# finish-setup.sh: bereitet Portainer-Deploy + Caddy-Snippets aus lokaler .env vor.
# - Kein SSH noetig (VPS-Schritte als Copy-Paste ausgegeben, du fuehrst sie aus).
# - Liest AUSSCHLIESSLICH .env (nie committen, steht in .gitignore).
# - Schreibt echte Secrets NUR nach /tmp (nie ins Repo).
set -euo pipefail
cd "$(dirname "$0")"

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

fail=0
[ -n "$AUTH_HASH" ] || { echo "FEHLER: AUTH_HASH leer in .env"; fail=1; }
[ -n "$AUTH_SECRET" ] || { echo "FEHLER: AUTH_SECRET leer in .env"; fail=1; }
[ -n "$OPENCODE_PASSWORD" ] || { echo "FEHLER: OPENCODE_PASSWORD leer in .env"; fail=1; }
[ "$fail" = 1 ] && exit 1

# Repo auf eingecheckte Secrets pruefen (danach darf nichts mehr kommen)
if git grep -n 'header_up Authorization "Basic ' -- caddy stack remote 2>/dev/null | grep -v __OPENCODE_BASIC__; then
  echo "FEHLER: echter Basic-Hash im Repo gefunden — vor Public entfernen."; exit 1
fi
if git ls-files --error-unmatch .bla >/dev/null 2>&1; then
  echo "FEHLER: .bla noch getrackt (git rm .bla)."; exit 1
fi

BASIC=$(printf 'opencode:%s' "$OPENCODE_PASSWORD" | base64)
export OPENCODE_BASIC="$BASIC"

sed "s|__OPENCODE_BASIC__|${BASIC}|g" caddy/Caddyfile.fragment > /tmp/Caddyfile.code.snippet
sed "s|__OPENCODE_BASIC__|${BASIC}|g" caddy/Caddyfile.remote.fragment > /tmp/Caddyfile.remote.snippet

# Caddy-Syntax lokal pruefen (braucht nur docker, kein SSH).
# Fragmente nutzen zentrale Snippets -> Stubs voranstellen.
for f in /tmp/Caddyfile.code.snippet /tmp/Caddyfile.remote.snippet; do
  {
    printf '{\n\temail florian@reisinger.pictures\n}\n\n(security_headers) {\n\theader X-Test test\n}\n(compress) {\n\tencode gzip\n}\n\n'
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
Portainer-Stack code-remote: Stacks -> Add stack -> Env (Copy-Paste):
----------------------------------------------------------------
AUTH_USER=$AUTH_USER
AUTH_HASH=$AUTH_HASH
AUTH_SECRET=$AUTH_SECRET
OPENCODE_PASSWORD=$OPENCODE_PASSWORD
SESSION_TTL=$SESSION_TTL
IMAGE=$IMAGE
================================================================
ACHTUNG: obiger Block enthaelt Secrets — nur in Portainer einfuegen, nirgendwo posten.

Caddy-Snippets (mit echtem Basic, nur lokal in /tmp):
  /tmp/Caddyfile.code.snippet    -> code.all-the.rest (Mac-Tunnel)
  /tmp/Caddyfile.remote.snippet  -> remote-code.all-the.rest (VPS-nativ)
Jeweils ins caddyfile-Repo (Caddyfile) uebernehmen, dort ./sync.sh.

VPS-Handgriffe (deine Shell, root@reisinger.pictures):
  docker network create code-remote
  # deployment/docker-compose.yml: caddy zusaetzlich in code-remote haengen, redeployen
  # DNS: remote-code.all-the.rest A-Record auf VPS
Danach: https://remote-code.all-the.rest/login.html
Erster gh-Login: per Portainer-Console oder: docker exec -it code-dev gh auth login
================================================================
EOF
