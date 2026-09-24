# Remote-Weg / Prod (VPS-nativ)

* Image `opencode-web-dev-baseline` (`Dockerfile` hier): Debian bookworm-slim +
  Node 26.x + pnpm + PHP 8.5 (Sury) + Composer v2 + `gh` + Docker-CLI + **opencode** (v2)
  + CodeGraph-CLI + Python/uv/markitdown + nano.
  Versionen floaten: Daily-CI holt jeweils latest (opencode-Layer per Build-ARG
  gezielt ohne Cache, damit mehrmals taegliche V2-Releases wirklich landen).
* Stack `code-remote` (`docker-compose.yml` hier): `code-dev` + isolierter
  `dind`-Daemon + eigener `code-auth-remote`. Nur Netz `code-remote` — kein `webnet`,
  daher keine Prod-Container per Name erreichbar, Internet via NAT ok.
  `code-dev` ist standardmäßig auf 3 CPU-Kerne und 4 GB RAM begrenzt; über
  `CPU_CORES` und `MEMORY_LIMIT` im Stack-Environment anpassbar.
  Secrets kommen als **globales Env** aus `.env.production` (gitignored, MANUELL
  aus Root-`.env` uebernommen: `AUTH_USER/AUTH_HASH/AUTH_SECRET/OPENCODE_PASSWORD/SESSION_TTL/IMAGE`) — nichts im Image.
* `gh auth` + SSH-Keys + Projekte liegen in Named Volumes (`gh-config`, `gh-ssh`,
  `code-remote-projects`) und ueberleben Image-Upgrades. Einmalig:
  `docker exec -it code-dev gh auth login`.

## Deploy (alles ohne SSH, nur Portainer + 1x VPS-Handgriff)

1. Passwort/Hash in Root-`.env` setzen (siehe Root-README), `.env.production`
   (hier) manuell angleichen, Caddy-Basic in globaler Caddyfile setzen.
2. Image: Daily-CI (`.github/workflows/build-baseline.yml`, 04:00 UTC taeglich,
   `ghcr.io/reisi007/opencode-web-dev-baseline:latest`) — oder einmalig per
   `workflow_dispatch`. Portainer-Stack mit `IMAGE` auf dieses Tag zeigen,
   Auto-Update per Portainer-Webhook/Polling (z.B. taeglich), damit der
   Container das frische Image auch zieht.
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

## Abo-Modelle & Updates (nur remote)

Wichtig vorweg: **Modelle werden nicht installiert.** Der Modellkatalog kommt
mit dem opencode-Binary (plus Provider-Anbindung) — fehlende Abo-Modelle
heissen fast immer: Binary zu alt oder Provider nicht verbunden.

1. Einmalig im OpenCode-Terminal (Web-GUI) den Provider verbinden — bleibt im
   Volume `opencode-data` erhalten, ueberlebt also Container-Recreates:
   `/connect` → **OpenCode Go** → API-Key aus <https://console.opencode.ai>
   Danach `/models` zur Auswahl (`opencode-go/<modell>`, z.B. als Default in
   `opencode.jsonc`: `"model": "opencode-go/kimi-k3"`).
2. Version pruefen: `opencode --version` + `opencode auth list`. Neue Modelle
   brauchen ggf. erst ein neueres Binary.
3. Updates laufen zweigleisig, nichts manuell noetig:
   * **Containerstart:** `entrypoint.sh` holt bei jedem (Re-)Start das neueste
     Binary (`OPENCODE_AUTOUPDATE`, default `true`, Opt-out `false`). Ein
     Recreate in Portainer reicht daher fuer ein Update — ideal bei mehrmals
     taeglichen V2-Releases. Fehlschlag blockiert den Start nie (Fallback:
     Image-Stand, Log: `/tmp/opencode-update.log` im Container).
   * **Watcher untertags:** Alle `OPENCODE_UPDATE_INTERVAL` Sekunden (default
     `1200` = 3x/Stunde, `1800` = 2x/Stunde, Minimum 300) prueft ein
     Hintergrund-Watcher im Fenster `OPENCODE_UPDATE_HOURS` (default `5-21`,
     Containerzeit = UTC, d.h. ca. 06–22 MEZ Wien) auf neue Releases. Bei
     Update + idle Server (`/api/session/active` leer) beendet er den
     Container, die Restart-Policy startet frisch mit neuem Binary. Laeuft
     gerade Arbeit, wird der Neustart aufs naechste Intervall vertagt
     (oder per `OPENCODE_UPDATE_RESTART=always` erzwingen — kann Runs
     abbrechen).
   * **Image:** Daily-CI baut `:latest` neu (opencode-Layer ohne Cache).
     Portainer-Polling/Webhook ziehen lassen.
   Hinweis: `OPENCODE_DISABLE_AUTOUPDATE=true` im Image bleibt Absicht — es
   verhindert nur das ungesteuerte In-Process-Update des laufenden Servers.

## pnpm

Das Image-pnpm (v12, CI-gepinnt) wird immer verwendet: Repo-Pins via
`packageManager`/`devEngines` lösen keinen Versionsswitch aus
(`PM_ON_FAIL=ignore`), damit `pnpm install` als `dev` nie ins
root-owned Global-Dir schreiben will.

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
