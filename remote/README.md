# Remote-Weg / Prod (VPS-nativ)

* Image `opencode-web-dev-baseline` (`Dockerfile` hier): Debian bookworm-slim +
  Node 26.x + pnpm + PHP 8.5 (Sury) + Composer v2 + `gh` + Docker-CLI + **opencode2** (`@beta`)
  + CodeGraph-CLI + Python/uv/markitdown + nano.
  Versionen floaten: Weekly-CI holt jeweils latest.
* Stack `code-remote` (`docker-compose.yml` hier): `code-dev` + isolierter
  `dind`-Daemon + eigener `code-auth-remote`. Nur Netz `code-remote` — kein `webnet`,
  daher keine Prod-Container per Name erreichbar, Internet via NAT ok.
  Secrets kommen als **globales Env** aus `.env.production` (gitignored, MANUELL
  aus Root-`.env` uebernommen: `AUTH_USER/AUTH_HASH/AUTH_SECRET/OPENCODE_PASSWORD/SESSION_TTL/IMAGE`) — nichts im Image.
* `gh auth` + SSH-Keys + Projekte liegen in Named Volumes (`gh-config`, `gh-ssh`,
  `code-remote-projects`) und ueberleben Image-Upgrades. Einmalig:
  `docker exec -it code-dev gh auth login`.

## Deploy (alles ohne SSH, nur Portainer + 1x VPS-Handgriff)

1. Passwort/Hash in Root-`.env` setzen (siehe Root-README), `.env.production`
   (hier) manuell angleichen, Caddy-Basic in globaler Caddyfile setzen.
2. Image: Weekly-CI (`.github/workflows/build-baseline.yml`, montags 04:00 UTC,
   `ghcr.io/reisi007/opencode-web-dev-baseline:latest`) — oder einmalig per
   `workflow_dispatch`. Portainer-Stack mit `IMAGE` auf dieses Tag zeigen,
   Auto-Update per Portainer-Webhook/Polling.
3. Portainer → Stacks → Add stack `code-remote` → Inhalt von
   `docker-compose.yml` (dieser Ordner) pasten → `.env.production` als Environment → Deploy.
4. Caddy (caddyfile-Repo, braucht 1x VPS-Handgriff per deiner shell):
   * Netz `code-remote` anlegen: `docker network create code-remote`
   * `deployment/docker-compose.yml`: `networks: [webnet, code-remote]` am
     `caddy`-Service + beide als `external: true` deklarieren, Stack redeployen.
   * Snippet aus `/tmp/Caddyfile.remote.snippet` in `Caddyfile` uebernehmen,
     DNS `remote-code.example.com` A-Record auf VPS, dort `./sync.sh`.
5. Test: `https://remote-code.example.com/login.html` → Login → OpenCode.
   In OpenCode-Terminal: `gh auth login` (einmalig), dann
   `gh repo clone owner/repo` nach `/projects`, arbeiten, loeschen via `rm -rf`.

## Git-Verwaltung

Checkout/Loeschen sind normale Verzeichnisse unter `/projects/<repo>`.
`gh` ist als `dev`-User installiert, Auth in Volume. Bei Image-Upgrade
Container recreaten — Volumes bleiben, kein Re-Login noetig.

## Persistenz (Updates loggen nichts aus)

| Inhalt | Ordner | Volume |
|---|---|---|
| `gh auth` | `/home/dev/.config/gh` | `gh-config` |
| SSH-Keys | `/home/dev/.ssh` | `gh-ssh` |
| Projekte | `/projects` | `code-remote-projects` |
| opencode-Config (`opencode.json`, editierbar via `nano`) | `/home/dev/.config/opencode` | `opencode-config` |
| opencode-Daten (Auth, Sessions) | `/home/dev/.local/share/opencode` | `opencode-data` |
| opencode-State | `/home/dev/.local/state/opencode` | `opencode-state` |

## CodeGraph pro Projekt (optional)

CLI ist im Image. Einmalig je Projekt, im Projekt-Terminal (interaktiv,
nur fuer opencode auswaehlen):

```bash
codegraph init      # Index anlegen (.codegraph/)
codegraph install   # Agent-Wiring — nur opencode
```
