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
  `AUTH_HASH` muss bcrypt oder PBKDF2 sein; ein Klartext-Fallback wird absichtlich
  nicht akzeptiert.
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
   * Block aus `remote/Caddyfile.fragment` in `Caddyfile` uebernehmen,
     DNS `remote-code.example.com` A-Record auf VPS, dort `./sync.sh`.
5. Test: `https://remote-code.example.com/login.html` → Login → OpenCode.
   In OpenCode-Terminal: `gh auth login` (einmalig), dann
   `gh repo clone owner/repo` nach `/projects`, arbeiten, loeschen via `rm -rf`.

## Verbindung, WebSockets und Healthcheck

Die Custom-Auth bleibt der einzige öffentliche Eingang: `code-dev` hat keine
veröffentlichten Docker-Ports; der Browser erreicht den VPS nur über Caddy.
Caddys `forward_auth` macht pro Request einen kurzen GET auf
`code-auth-remote:/check` und proxyt danach den eigentlichen Request. Das ist
auch für WebSocket-Upgrades gedacht — der Auth-Request ist kein dauerhafter
zweiter Stream.

HTTP/2 zwischen Browser und Caddy ist normal. Für den Upstream zu OpenCode wird
im `Caddyfile.fragment` bewusst HTTP/1.1 verwendet: OpenCode antwortet mit
`Keep-Alive: timeout=5`, während Cadys Default länger im Idle-Pool bleibt. Der
gesetzte `keepalive 4s` verhindert, dass Caddy einen bereits geschlossenen
Upstream-Socket wiederverwendet. Für den kurzen `forward_auth`-Preflight ist
Cadys Keepalive explizit aus; der Python-Sidecar arbeitet als HTTP/1.0-Service
ohne Idle-Pool. SSE wird von Caddy automatisch ungepuffert weitergereicht; ein
globales `flush_interval -1` bleibt bewusst weg, weil es redundant wäre und
auch alle normalen Responses beeinflussen würde.

Zusätzlich prüft Caddy alle 30 Sekunden direkt und mit OpenCode-Basic-Auth
`/api/info`. Erst nach drei Fehlversuchen wird der Upstream für neue Requests
als `unhealthy` markiert; der Healthcheck läuft ohne Umweg über die Custom-Auth.
`forward_auth` wird nur beim Start eines Requests bzw. WebSocket-Handshakes
geprüft, nicht erneut für einen bereits laufenden SSE-/WebSocket-Stream.
`stream_timeout 24h` und `stream_close_delay 5m` gelten für WebSocket-Upgrades
(insbesondere PTY), nicht für SSE. Der V2-Client verbindet einen sauber
beendeten PTY-WebSocket erneut.

### Schnelldiagnose auf dem VPS

```bash
# Alle beteiligten Container und ihre Health-Status
# (Caddy-Containername ggf. anpassen)
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'code-dev|code-auth-remote|caddy'

# Status, Neustarts und OOM-Kill getrennt betrachten
docker inspect code-dev --format \
  'status={{.State.Status}} health={{.State.Health.Status}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}'

# Letzte Healthcheck-Ausgaben (die curl-Zeile selbst bleibt passwortfrei)
docker inspect code-dev --format \
  '{{range .State.Health.Log}}{{.Start}} exit={{.ExitCode}} {{.Output}}{{"\n"}}{{end}}'

# Direkter interner OpenCode-Test: umgeht Caddy und Custom-Auth absichtlich
docker exec code-dev sh -lc \
  'curl -fsS --http1.1 --connect-timeout 2 --max-time 4 \
   -u "opencode:${OPENCODE_PASSWORD:-${OPENCODE_SERVER_PASSWORD}}" \
   "http://127.0.0.1:${PORT:-8080}/api/info"'

# Ressourcen/Prozess und OpenCode-Log
docker stats --no-stream code-dev
docker logs --since 30m --timestamps code-dev
docker exec code-dev sh -lc 'tail -n 200 /home/dev/.local/share/opencode/log/opencode.log 2>/dev/null || true'

# Caddy-Fehler/Upstream-Resets (bei zentralem Caddy-Container anpassen)
docker logs --since 30m caddy 2>&1 | \
  grep -Ei 'code-dev|error|reset|timeout|502|503|504' || true
```

OpenCode-Logs können Pfade, Prompts oder Session-Inhalte enthalten; vor dem
Teilen von Ausgaben bitte redacten.

`BrokenPipeError`/`ConnectionResetError` im Auth-Log sind bei einem
abgebrochenen `forward_auth`-Preflight normal: Caddy kann die Verbindung
schließen, wenn der Browser den Request reloadt oder Caddy selbst neu lädt.
Der aktuelle Sidecar behandelt diese Disconnect-Fälle ohne Traceback; wenn sie
weiterhin erscheinen, läuft wahrscheinlich noch das alte Image.

Der Docker-Healthcheck spricht `127.0.0.1` direkt an und läuft **nicht** über
Caddy. Ein internes `200` bei `/api/info` plus Fehler im öffentlichen Pfad
deutet daher auf Caddy/Auth/Upstream-Transport (401/Redirect: insbesondere
`__OPENCODE_BASIC__` bzw. Cookie-Gate prüfen); ein internes Timeout/401/5xx
deutet auf OpenCode, Credentials oder Container-Ressourcen. Docker startet bei
`restart: unless-stopped` wegen `unhealthy` allein nicht neu; entscheidend sind
`RestartCount`, `OOMKilled` und der Exit-Code. Im Browser-DevTools
bei Network mit „Preserve log“ prüfen: `/api/event` sollte `200` mit
`text/event-stream` bleiben, der PTY-WebSocket sollte `101 Switching Protocols`
liefern. Steigt `RestartCount` und zeigen die Logs `opencode watcher: neues
Binary → Container-Neustart`, ist der Auto-Update-Watcher die Ursache; zum
Testen vorübergehend `OPENCODE_AUTOUPDATE=false` setzen. `OOMKilled=true`
hingegen spricht zuerst für das 4-GB-Limit (testweise `MEMORY_LIMIT=8g`), nicht
für HTTP/2.

Das Caddy-Fragment enthält `stream_timeout 24h` und
`stream_close_delay 5m` als Betriebsrichtlinie für WebSocket-Upgrades. Ein
deutlich kürzerer Timeout würde laufende PTY-Sessions unnötig beenden; SSE
wird davon nicht betroffen.

Nach einer Änderung an `Caddyfile.fragment` den Block in die echte globale
Caddyfile übernehmen und dort `./sync.sh` ausführen. Der Healthcheck in
`Dockerfile` braucht dagegen einen Image-Neubau und ein Redeploy mit dem neuen
`IMAGE`; ein bloßes Portainer-Recreate eines alten Images ändert ihn nicht.

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
