# Zweiter Weg neben Mac-Tunnel: VPS-nativ auf remote-code.all-the.rest.
# Mac (`code.all-the.rest` + run.sh) bleibt unveraendert.

## Was das ist

* Image `opencode-web-dev-baseline` (`remote/Dockerfile`): Debian bookworm-slim +
  Node 26.x + PHP 8.5 (Sury) + Composer v2 + `gh` + Docker-CLI + OpenCode latest.
  Versionen floaten: Weekly-CI holt jeweils latest (Stand lokal: Node v26.8.1, PHP 8.4.23, gh 2.98.0).
* Stack `code-remote` (`stack/docker-compose.remote.yml`): `code-dev` + isolierter
  `dind`-Daemon + eigener `code-auth-remote`. Nur Netz `code-remote` — kein `webnet`,
  daher keine Prod-Container per Name erreichbar, Internet via NAT ok.
* `gh auth` + SSH-Keys + Projekte liegen in Named Volumes (`gh-config`, `gh-ssh`,
  `code-remote-projects`) und ueberleben Image-Upgrades. Einmalig:
  `docker exec -it code-dev gh auth login`.

## Deploy (alles ohne SSH, nur Portainer + 1x VPS-Handgriff)

1. `./finish-setup.sh` lokal laufen lassen (liest nur `.env`, committet nichts).
   Gibt aus: Portainer-Env-Block + Caddy-Snippets nach `/tmp`.
2. Image: Weekly-CI (`.github/workflows/build-baseline.yml`, montags 04:00 UTC,
   `ghcr.io/reisi007/opencode-web-dev-baseline:latest`) — oder einmalig per
   `workflow_dispatch`. Portainer-Stack mit `IMAGE` auf dieses Tag zeigen,
   Auto-Update per Portainer-Webhook/Polling.
3. Portainer → Stacks → Add stack `code-remote` → Inhalt von
   `stack/docker-compose.remote.yml` pasten → Env aus Schritt 1 eintragen → Deploy.
4. Caddy (caddyfile-Repo, braucht 1x VPS-Handgriff per deiner shell):
   * Netz `code-remote` anlegen: `docker network create code-remote`
   * `deployment/docker-compose.yml`: `networks: [webnet, code-remote]` am
     `caddy`-Service + beide als `external: true` deklarieren, Stack redeployen.
   * Snippet aus `/tmp/Caddyfile.remote.snippet` in `Caddyfile` uebernehmen,
     DNS `remote-code.all-the.rest` A-Record auf VPS, dort `./sync.sh`.
5. Test: `https://remote-code.all-the.rest/login.html` → Login → OpenCode.
   In OpenCode-Terminal: `gh auth login` (einmalig), dann
   `gh repo clone owner/repo` nach `/projects`, arbeiten, loeschen via `rm -rf`.

## Git-Verwaltung

Checkout/Loeschen sind normale Verzeichnisse unter `/projects/<repo>`.
`gh` ist als `dev`-User installiert, Auth in Volume. Bei Image-Upgrade
Container recreaten — Volumes bleiben, kein Re-Login noetig.
