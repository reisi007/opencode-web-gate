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
  **Kein Host-Zugriff:** `code-dev` hat bewusst *kein* `extra_hosts` und
  erreicht den VPS nicht. `127.0.0.1` ist der Container selbst — ein
  Dev-Server laeuft daher direkt in `code-dev` und ist sofort ueber
  `127.0.0.1` erreichbar. `dind` laeuft **rootless** (kein `privileged`).
  Siehe *Warum es kein `extra_hosts` gibt* und *`dind` ist rootless*.
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

## Warum es kein `extra_hosts` gibt — und wo Dev-Server laufen

**Kurzfassung:** `127.0.0.1` in `code-dev` ist der Container selbst, nicht der
VPS. Ein Dev-Server, der in `code-dev` laeuft, ist ueber `127.0.0.1` erreichbar —
ohne jede Sonderkonfiguration. Es war nie ein Docker-Problem.

### Die Fehldiagnose, die 2026-09-26 behoben wurde

Der Stack hatte (bis 26.09.2026):

```yaml
    - HOST_GATEWAY=${HOST_GATEWAY:-host.docker.internal}
    extra_hosts:
      - "${HOST_GATEWAY:-host.docker.internal}:host-gateway"
```

Der Kommentar im Compose lautete: *"Loesung fuer 'localhost laesst sich im
Container nicht nutzen'"*. **Das ist falsch.** `extra_hosts` fuegt lediglich
einen zusaetzlichen Namen fuer eine Host-IP hinzu; es repariert `127.0.0.1`
nicht. Es gibt dafuer auch keine Option — die einzige Variante, bei der
`127.0.0.1` der Host ist, ist `network_mode: host`, und das gibt dem Container
**genau den Zugriff, den wir nicht wollen** (alle Host-Ports, inkl.
Bind-Konflikte).

Was `extra_hosts` stattdessen bewirkt hat, war eine **Tuer zum ganzen VPS**:

| Host-Port | Dienst | Von `code-dev` erreichbar? |
|---|---|---|
| 8000 | **Portainer-UI, unverschluesselt** | ja — HTTP 404 (live gemessen) |
| 9443 | **Portainer-API** | ja — HTTP 400 (live gemessen) |
| 80/443 | Caddy | ja |

Und `host.docker.internal` wurde nachweislich **nirgends benutzt** — geprueft in
`/projects` und im OpenCode-State, Ergebnis: keine Treffer.

**Warum es trotzdem auffiel:** die Agenten wollten einen React-Dev-Server
erreichen. Ein Dev-Server laeuft aber in einem der zwei Container:

| Wo laeuft er | Erreichbar wie | Auf `127.0.0.1`? |
|---|---|---|
| in `code-dev` (`pnpm dev`) | direkt | **ja, sofort** |
| im DinD (`docker run -p 3000:3000 …`) | nur per Container-Name **innerhalb** des DinD | **nein** |

`code-dev` hat Node 26 / npm 12 / pnpm 12. Ein Dev-Server braucht also gar kein
Docker. Die Nutzung im DinD sind **Test-Stacks** (`postgres:16-alpine`,
`axllent/mailpit`, `php:8.5-fpm`, `lumina-ci-r5-maskvis:local`), keine
Dev-Server.

### Was gemeinsam ist — und was nicht

```
code-dev  /projects -> dev-vm_code-remote-projects
dind      /projects -> dev-vm_code-remote-projects   ← gleiches Volume
```

**Dateien sind geteilt, Prozesse und Netzraum nicht.** Der DinD hat einen
eigenen Docker-Daemon mit eigener Bridge. Ein `docker run -p 3000:3000` dort
bindet im DinD-Netzraum und ist von `code-dev` aus weder ueber `127.0.0.1`
noch ueber eine Host-IP erreichbar. **Loopback funktioniert containeruebergreifend
nie** — auch nicht mit irgendeinem `extra_hosts`.

### Die drei Regeln fuer die Agenten

1. **Dev-Server → direkt in `code-dev`.** `pnpm dev` / `npm run dev`, dann
   `127.0.0.1:<port>`. Fertig, kein Docker, kein Port-Publishing.
2. **Wegwerf-Testcontainer → DinD, per Name ansprechen.** `docker compose -p
   <projekt> up -d` im DinD, dann im selben Compose-Netz per Service-Namen
   (`db:5432`, `mailpit:8025`). Namen, nie `127.0.0.1`, nie `host.docker.internal`.
3. **Nie `docker run -p 127.0.0.1:…`.** Diese Bindung ist im DinD
   containerlokal und von aussen unerreichbar. Immer `--network` bzw. Compose
   und den Containernamen nutzen.

### `DOCKER_HOST` und der DinD

`code-dev` hat **keinen** Docker-Socket gemountet und **keinen** eigenen
`dockerd`. `DOCKER_HOST=tcp://dind:2375` zeigt auf den Sidecar
`code-remote-dind`. Auch das ist eine häufige Fehlvorstellung: die
Docker-**CLI** ist in `code-dev`, der **Daemon** nicht.

Fuer den Daemon-Durchgriff aus einem Werkzeug ohne CLI (z. B. `curl`):

```bash
# Port 2375 ist die unverschluesselte API des rootless-Daemons.
# Erreichbar ist NUR 2375, nicht 2376 — 2376 laeuft ueber TLS bzw. ist nicht
# von aussen offen.
docker exec code-dev curl -sS -m 3 -o /dev/null -w '%{http_code}\n' http://dind:2375/_ping
```

## `dind` ist rootless — und warum das drei Details braucht

Bis 2026-09-26 lief `code-remote-dind` mit `privileged: true`. Das ergab
`CapEff: 000001ffffffffff` (alle 37 Capabilities) und `/dev/vda4` war sichtbar —
also praktisch Root auf dem Host, auf dem `/home/webadmin/websites`, die
MariaDB-Volumes, die TLS-Keys, `portainer.db` und die rclone-Config liegen.
Da `code-dev` die Docker-CLI hat und `DOCKER_HOST` auf diesen Daemon zeigt, war
das der direkte Weg aus dem Dev-Container in die Prod-Daten.

Jetzt laeuft der Daemon im User-Namespace. Live verifiziert nach dem Deploy:

| Pruefung | Wert |
|---|---|
| `HostConfig.Privileged` | `false` |
| `CapEff` | `0000000000000000` |
| Host-Blockdevices (`/dev/vd*`, `/dev/sd*`) | `[]` |
| `SecurityOptions` | `seccomp, rootless, cgroupns` |
| `docker build` | funktioniert |
| `docker compose` | v5.5.1 |
| `DockerRootDir` | `/home/rootless/.local/share/docker` (= Volume) |
| Host unter Port 9443 aus dem DinD | nicht erreichbar |

### Die drei Eintraege sind NOTWENDIG

Jeder einzeln getestet — ohne alle drei startet es nicht:

| Eintrag | Ohne ihn |
|---|---|
| `security_opt: seccomp=unconfined` | Der Daemon startet gar nicht (Default-seccomp blockt `unshare(CLONE_NEWUSER)`). |
| `security_opt: systempaths=unconfined` | `error mounting "proc" to rootfs: operation not permitted` — Docker maskiert `/proc` im Container, und der `/proc`-Mount im nested userns scheitert. |
| `devices: /dev/net/tun` | `tap0: "open: No such file or directory"` — rootlesskit legt ein tap-Device fuer slirp4netns an. |

### Zwei Fallen, die man nicht sieht

**1. `DOCKER_TLS_CERTDIR=` muss leer sein, `--tls=false` als `command`
wirkungslos.** Der rootless-Entrypoint ueberschreibt bzw. ignoriert das
CMD-Argument. Mit leerem `DOCKER_TLS_CERTDIR` laeuft die API auf **2375
plain HTTP** — damit bleibt `DOCKER_HOST=tcp://dind:2375` unveraendert
gueltig. Ohne das Env laeuft 2376 ueber **HTTPS** und 2375 gar nicht.

**2. Das Volume haengt an `/home/rootless/.local/share/docker`, nicht an
`/var/lib/docker`.** Der rootless-Daemon startet ohne `--data-root` und nutzt
seinen Default `$HOME/.local/share/docker` (`HOME=/home/rootless`, uid 1000).
Ein Mount auf `/var/lib/docker` ist **wirkungslos**: das Volume bleibt leer
und alle Images/Builds liegen im Writable-Layer — weg bei jedem Recreate. Genau
das ist zuerst passiert (gemessen: 11,9 MB im Layer, 0 Byte im Volume).
Das Volume `dind-data-rootless` ist deshalb auch neu, denn das alte
`dind-data` war `root:root` und fuer uid 1000 unbeschreibbar.

### Funktionale Einschraenkung: keine cgroups

Rootless-Docker kann ohne systemd im Container **keine cgroups** durchsetzen:

> `WARNING: Running in rootless-mode without cgroups. Systemd is required to
> enable cgroups in rootless-mode.`

Daher greifen `mem_limit`/`cpus` fuer Container **im DinD** nicht mehr. Die
Limits von `code-dev` selbst (`mem_limit: ${MEMORY_LIMIT}`, `cpus:
${CPU_CORES}`) sind **nicht** betroffen — das ist ein eigener Container auf dem
Host-Daemon. Wenn ein Build den Host ueberlaesst: `MEMORY_LIMIT`/`CPU_CORES`
im Stack-Environment anpassen.

## Aufräumen: `dind-image-gc.sh`

Watchtower (Stack 10) raeumt nur den **Host**-Daemon ab. Die Bilder *im DinD*
verwaltet niemand — die sind über den Agenten-Workflow stark gewachsen. Live
gemessen vor der Migration:

```
TYPE            TOTAL   ACTIVE   SIZE      RECLAIMABLE
Images          19      0        8.203GB   5.585GB (68%)
Local Volumes   15      0        76.44GB   76.44GB (100%)   ← das war der Grossteil
```

**Die 76 GB waren keine Images, sondern 15 verwaiste anonyme Volumes.** Ursache:
`docker run` legt bei Images mit `VOLUME` ein anonymes Volume an, und
`docker rm` **ohne** `-v` nimmt es nicht mit. 526 dokumentierte `docker run`
im Agent-Log — genau dieses Muster.

### Einrichtung

```bash
install -m 0755 dind-image-gc.sh /usr/local/bin/dind-image-gc.sh
# taeglich 04:17 (nicht :00 — vermeidet die Minute, in der andere Jobs laufen)
17 4 * * * /usr/local/bin/dind-image-gc.sh >> /var/log/dind-image-gc.cron.log 2>&1
```

> Der `2>&1` ist Absicht. Der bestehende Backup-Cron auf diesem Server nutzt
> `2>&0` — das ist kein Tippfehler, sondern verwirft stderr nach `/dev/null`
> (fd 0 in cron). Fehlerwaechter sehen dann nichts.

### Verhalten

| Objekt | Regel |
|---|---|
| Images | `image prune -a --filter until=14d` |
| Build-Cache | `builder prune -a --filter until=14d` |
| Volumes | **Alterspruefung selbst** (siehe unten) |
| Container/Netze | `prune --filter until=14d` |

`docker volume prune` kennt **keinen** `until`-Filter (nur `label=`) — ein
`--filter until=14h` liefert `Error response from daemon: invalid filter
'until'`. Das Skript listet daher dangling Volumes, liest `CreatedAt` und
löscht nur jenseits der Retention. Zweite Sicherung: `docker volume rm`
verweigert den Dienst, wenn ein Volume doch noch benutzt wird.

Aufruf: `dind-image-gc.sh [--dry-run] [--host-daemon]`.
Retention über `RETENTION_DAYS` (Default 14). Log nach
`/var/log/dind-image-gc.log` mit logrotate-Regel (8 Wochen).

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
