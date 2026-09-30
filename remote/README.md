# Remote-Weg / Prod (VPS-nativ)

* Image `opencode-web-dev-baseline` (`Dockerfile` hier): Debian bookworm-slim +
  Node 26.x + pnpm + PHP 8.5 (Sury) + Composer v2 + `gh` + Docker-CLI + **opencode** (v2)
  + CodeGraph-CLI + Python/uv/markitdown + nano.
  Versionen floaten: Daily-CI holt jeweils latest (opencode-Layer per Build-ARG
  gezielt ohne Cache, damit mehrmals taegliche V2-Releases wirklich landen).
* Stack `code-remote` (`docker-compose.yml` hier): `code-dev` + isolierter
  `dind`-Daemon + eigener `code-auth-remote`. Nur Netz `code-remote` — kein `webnet`,
  daher keine Prod-Container per Name erreichbar, Internet via NAT ok.
  `code-dev` ist standardmäßig auf 3 CPU-Kerne, 4 GB RAM **plus 4 GB Swap**
  begrenzt; über `CPU_CORES`, `MEMORY_LIMIT` und `MEMSWAP_LIMIT` im
  Stack-Environment anpassbar. Wichtig: `memswap_limit` muss größer sein als
  `mem_limit`, sonst ist der Swap-Deckel exakt so hoch wie das RAM-Limit.
  Wichtig für die Rechnung: `memswap_limit` ist der **Gesamt**-Deckel, bei 5g/9g
  also 5 GB RAM plus 4 GB echte Swap-Reserve — beides belegt nachweislich
  (`memory.swap.current` stand am 2026-09-30 bei 597 MB). Siehe *RAM- und
  Swap-Limits*.
  **Kein Host-Zugriff:** `code-dev` hat bewusst *kein* `extra_hosts` und
  erreicht den VPS nicht. `127.0.0.1` ist der Container selbst — ein
  Dev-Server laeuft daher direkt in `code-dev` und ist sofort ueber
  `127.0.0.1` erreichbar. `dind` laeuft **rootless** (kein `privileged`).
  Siehe *Warum es kein `extra_hosts` gibt* und *`dind` ist rootless*.
  Secrets kommen als **globales Env** aus `.env.production` (gitignored, MANUELL
  aus Root-`.env` uebernommen: `AUTH_USER/AUTH_HASH/AUTH_SECRET/OPENCODE_PASSWORD/SESSION_TTL/IMAGE`) — nichts im Image.
  `AUTH_HASH` muss bcrypt oder PBKDF2 sein; ein Klartext-Fallback wird absichtlich
  nicht akzeptiert.
* `gh auth` + SSH-Keys liegen in Named Volumes (`gh-config`, `gh-ssh`) und
  ueberleben Image-Upgrades. Einmalig: `docker exec -it code-dev gh auth login`.
  Die **Projekte** liegen seit 2026-09-29 *nicht* mehr in einem Named Volume,
  sondern auf einem 100-GB-Loopback unter `/srv/dev-projects` — siehe
  *100-GB-Loopback fuer `/projects`*.

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
   **Achtung beim Einfuegen:** Portainer interpolated die Env-Werte, deshalb steht
   `AUTH_HASH` in `.env.production` als `$$2a$…` und nicht als `$2a$…`. Nicht
   "aufraeumen" — unescaped ist der Login auf `remote-code` kaputt. Regel und
   Verifikation: [`../AGENTS.md`](../AGENTS.md) Abschnitt 2 und 5.
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
code-dev  /projects -> bind /srv/dev-projects        (100-GB-Loopback, ext4)
dind      /projects -> bind /srv/dev-projects        ← gleicher Mountpoint
```

Bis 2026-09-28 war das noch `dev-vm_code-remote-projects`, ein Named Volume.
Die Beobachtung darunter gilt unverändert, nur der Pfad hat sich geändert.

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

Daher greifen `mem_limit`/`cpus` **an den inneren Containern** nicht. Die Limits
von `code-dev` selbst (`mem_limit`/`memswap_limit`/`cpus`) sind **nicht**
betroffen — das ist ein eigener Container auf dem Host-Daemon.

**Ein Limit am `dind`-Container selbst greift aber sehr wohl fuer die inneren
Container.** Die inneren Prozesse teilen sich denselben cgroup wie der Daemon.
Live gemessen: der `sleep` eines inneren `alpine`-Containers und der
dind-Daemon liegen beide in
`/system.slice/docker-<dind-id>.scope`. Gegenprobe mit 1,8 GB tmpfs in einem
inneren Container bei `mem_limit: 600m` auf dem DinD:

```
memory.peak   629149696   (= exakt die 600-MB-Decke)
oom_kill      1
```

Also: Limit am DinD = Deckel fuer **alles**, was der Agent darin startet.

**Die Fehlerbehandlung ist der Haken.** Bei OOM waehlt der Kernel den
**groessten** Prozess im cgroup, und das ist der dind-Daemon, nicht der
schuldige Build. Deshalb **kein gemeinsames Limit** mit `code-dev`, sondern
zwei getrennte: so stirbt ein runaway Build nur `code-remote-dind`
(`restart: unless-stopped`, startet neu) und die `code-dev`-Session laeuft
weiter.

### RAM- und Swap-Limits

`cgroup`-v2-Semantik, live auf dem VPS gemessen (Direkt-Reads aus
`/sys/fs/cgroup/.../memory.max` und `memory.swap.max`):

| Docker-Argumente | `memory.max` | `memory.swap.max` | Bedeutung |
|---|---|---|---|
| `--memory 200m` | 200 MB | 200 MB | 200 MB RAM + 200 MB Swap |
| `--memory 200m --memory-swap 800m` | 200 MB | 600 MB | 200 MB RAM + 600 MB Swap |
| `--memory 200m --memory-swap 1600m` | 200 MB | 1400 MB | 200 MB RAM + 1400 MB Swap |

**Formel: `memory.swap.max = memswap_limit − mem_limit`.** In cgroup v2 ist
`memory.swap.max` ein **reiner Swap-Deckel**, nicht die Summe.

Hier stand zuerst die gegenteilige Behauptung im Compose und sie war **falsch**:
ohne `memswap_limit` ist Swap weder deaktiviert noch unbegrenzt, sondern der
Deckel ist exakt `mem_limit`. `memswap_limit` setzt man also nicht, um Swap zu
eroeffnen, sondern um das **Verhaeltnis** zu bestimmen und den Gesamt-Fussabd
hart zu deckeln.

Aktuelles Budget (live gemessen, 2026-09-29 nach der zweiten Anhebung):

| Container | RAM | Swap | gesamt | cpus |
|---|---|---|---|---|
| `code-dev` | 4096 MB | 4096 MB | 8192 MB | 3 |
| `code-remote-dind` | 2560 MB | 2560 MB | 5120 MB | 2 |
| `code-auth-remote` | unbegrenzt | — | — | — |
| **Summe** | **6656 MB** | **6656 MB** | **13312 MB** | |

**Die Summe der RAM-Limits (6,66 GB) liegt bei 7,5 GB Host-RAM, zusammen mit
Portal (~0,5 GB) und OS/dockerd (~0,7 GB) aber darüber.** Das ist am
2026-09-29 bewusst so entschieden worden und ist der engste Punkt auf dem
Host: erreichen code-dev und dind ihre Deckeln gleichzeitig — und das ist der
Normalfall, weil der Agent in `code-dev` per cargo baut und parallel im Daemon
per docker baut —, feuert der **Host**-OOM-Killer. Der nimmt global den
größten Prozess, und das kann `mariadbd` sein. Wer das nicht will, senkt dind
auf 2 GB; das kostet nur Reserve im Daemon, der real 196 MB nutzt.

`code-auth-remote` bleibt bewusst unbegrenzt — real 11 MB, und ein Deckel
wuerde nur Aerger machen.

RAM ist bei `code-dev` knapper als Swap, beim DinD umgekehrt: Builds im Daemon
sind Batch-Arbeit, Latenz ist egal; `code-dev` ist interaktiv und soll nicht
swappen.

### Warum 2 GB nicht gereicht haben — und warum 3 GB auch noch nicht reichten

Am 2026-09-29 gemessen: **8 cgroup-OOM-Kills in 24 Stunden, alle in `code-dev`**,
kein anderer Container auffaellig. Ausloeser war jedes Mal ein `cargo build` —
parallele `rustc`/`rust-lld` liegen bei 220–920 MB pro Instanz, bei 3 CPU-Cores
also mehrere gleichzeitig.

Der Haken ist derselbe wie beim DinD weiter oben, nur mit schlimmerem Ausgang:
**der Kernel killt im cgroup den GROESSTEN Prozess, nicht den schuldigen.**
Bei `code-dev` ist das `opencode serve` — und das laeuft als **PID 1**. PID 1
sterben lassen heisst: der Container stirbt, `restart: unless-stopped` startet
neu, die Sitzung ist weg. Ein Tag im Log:

| Zeit (CEST) | Opfer | RSS | Folge |
|---|---|---|---|
| 10:14 | rustc | 470 MB | — |
| 10:25 | rustc | 324 MB | — |
| 10:31 | **opencode (PID 1)** | 299 MB | 💥 Container down |
| 12:59 | rustc ×2 | ~890 MB | — |
| 13:05 | rustc | 571 MB | — |
| 13:06 | **opencode (PID 1)** | 254 MB | 💥 Container down |
| 13:47 | **opencode (PID 1)** | 372 MB | 💥 Container down |

3× rustc, aber 5× PID 1. Deshalb war es von aussen **nicht regelmaessig** —
es hing nur daran, OB zur Zeit gerade Rust kompiliert wurde. Idle liegt
`code-dev` bei ~700 MB (opencode 320 + codegraph-node ~350 + tailscaled 42 +
Rest).

**Und 3 GB hat es nicht geschafft — aber `memory.current` hat es verschleiert.**
Nachmessung am 3g-Deckel:

```
memory.max      3221225472   (3,00 GB)
memory.current  2759196672   (2,57 GB)  = 86 %
memory.peak     3221229568               = Decel berührt
OOM-Kills                       0
```

`rustc`/`rust-lld` brauchen **anon**-Speicher (220–920 MB pro Instanz), und der
ist nicht reclaimbar. Deshalb 4 GB.

### Der Deckel wird an `anon` gemessen, nicht an `memory.current`

`memory.current` enthält den **reclaimbaren File-Cache**. Nach einem
Playwright- oder Vite-Lauf füllt der das Deckel fast voll, ohne dass ein
Speicherproblem existiert. Live gemessen am 2026-09-29 um 16:36 bei
`memory.current` = 95 %:

| | MB | vom 4-GB-Deckel |
|---|---|---|
| reclaimbarer File-Cache (`file`) | 2821 | 69 % |
| **anon — echter Prozess-Speicher** | **929** | **23 %** |
| `slab_unreclaimable` | 5 | — |
| `pagetables` + `shmem` + `slab_reclaimable` | 45 | 1 % |

**OOM-relevant sind nur `anon` + `slab_unreclaimable` = 934 MB von 4096 MB.**
Der Kernel hat 2,8 GB Cache recycled statt zu killen; `oom_kill 0` war das
richtige Ergebnis. `memory.peak` über `memory.max` ist in diesem Zustand
**kein** Alarm, weil `peak` den Cache mitzählt.

Daraus die Regeln:

- **`memory.current` hoch heisst nichts.** Wer daraus „Deckel zu klein" ableitet,
  hebt Limits an, die nicht das Problem sind.
- **`memory.peak > memory.max` ist kein OOM-Beweis.** `peak` zählt Cache mit.
- **Die echte Frage: war `anon` am Limit?** Ein Deckel stimmt, wenn parallele
  Builds zusammen unter ~3 GB `anon` bleiben.
- **Messen:**
  ```sh
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
  grep -E '^(anon|file|slab_unreclaimable) ' $CG/memory.stat
  grep oom_kill $CG/memory.events
  ```

### Der Swap-Deckel greift — eine falsche Diagnose ist korrigiert

Bis 2026-09-30 stand hier, der Swap habe „nie gegriffen", weil
`vm.swappiness=0` sei. **Das war eine Verwechslung von zwei Sysctls.**
`vm.swappiness` ist **10** (persistiert in `/etc/sysctl.conf`, mtime April).
Der Wert `0`, den ich gemessen und falsch etikettiert hatte, war
`vm.overcommit_memory`.

Live gegengeprueft am 2026-09-30: `memory.swap.current` = **597 MB von 4096 MB
genutzt**. `memswap_limit` ist also echte Reserve, keine Zahl.

Das verschiebt die Groessenordnung: `code-dev` bei 4g/8g hatte ein **Gesamt-
budget von 8 GB** — und `opencode serve` als PID 1 wurde am 30.09. um 08:46
trotzdem getoetet. Der Grund ist also nicht der Swap, sondern anon-Druck:
`rustc`/`rust-lld`/`clippy-driver` 220–920 MB pro Instanz, dazu Chrome aus
Playwright-Läufen.

### Recreate ja, aber nicht um jeden Preis

Ein Wechsel der Limits braucht zwingend einen Recreate, der jede laufende
Sitzung im Container beendet (Dateien auf dem Projekt-Volume bleiben erhalten):

```sh
cd /var/lib/docker/volumes/portainer_data/_data/compose/49
docker compose --env-file stack.env -p dev-vm up -d --no-deps code-dev
```

**Fuer einen laufenden RAM-Deckel geht es ohne Recreate.** `memory.max` ist im
laufenden cgroup schreibbar, also laesst sich eine akute OOM-Lage sofort
entschaerfen, ohne eine einzige Sitzung zu beenden (2026-09-29 so gemacht,
waehrend zwei Sessions liefen):

```sh
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
echo 3221225472 > "$CG/memory.max"   # 3 GiB, gilt bis zum naechsten Recreate
```

Das ist **kein Ersatz** fuer die Compose-Aenderung — beim naechsten Recreate
(Watchtower, Stack-Deploy) ist der Wert wieder weg und es zaehlt nur, was in der
Compose-Datei steht. Aber es ist die richtige Massnahme, wenn gerade jemand
arbeitet.

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
hingegen spricht zuerst für das RAM-Limit, nicht für HTTP/2. Standard sind
4096 MB RAM plus 4096 MB Swap (`MEMORY_LIMIT` / `MEMSWAP_LIMIT`); die Werte
standen bis 2026-09-29 auf 2048/3072 und haben dabei reproduzierbar OOM-Kills
ausgeloest, Grund und Messwerte siehe *RAM- und Swap-Limits*. Ein OOM bedeutet
also **nicht**, dass beide erschöpft waren — der Swap-Deckel greift auf diesem
Host — der Swap-Deckel greift. Der schnellste Check, ob die RAM-Deckel die
Ursache war:

```sh
# Woerter "Killed process" im Kernel-Ringpuffer, mit cgroup-Zuordnung
dmesg -T | grep -E "Memory cgroup out of memory" | tail -20
# Wer steckt in welchem cgroup (Opfer-Prozess = das, was zurueckkam)
dmesg -T | grep -oE "oom_memcg=/system.slice/docker-[0-9a-f]+" | sort | uniq -c
# Swap tatsaechlich ungenutzt?
cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope/memory.swap.current
# Die echte Kennzahl: anon (nicht-reclaimbar). current/peak zaehlen Cache mit!
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
grep -E '^(anon|file|slab_unreclaimable) ' $CG/memory.stat
grep oom_kill $CG/memory.events
```

Steht dort `0`, wurde nie Swap benutzt und `MEMORY_LIMIT` ist zu niedrig. Steht
es nahe am Deckel, ist `MEMSWAP_LIMIT` zu niedrig.

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

## 100-GB-Loopback fuer `/projects`

Seit 2026-09-29 liegt `/projects` auf einem eigenen Dateisystem statt im
Docker-Root-Verzeichnis. Zwei Services teilen sich denselben Bind-Mount:
`code-dev` und `dind`.

```
/srv/dev-100g.img     sparse Datei auf vda4, 100 GiB apparent
/srv/dev-projects     Mountpoint (ext4, 1000:1000)
```

| Schicht | Wert |
|---|---|
| Dateisystem | ext4, Label `devprojects`, `-m 0` (keine reservierten Blöcke) |
| Loop-Groesse | 26.214.400 Blöcke × 4096 B = **100,00 GiB** |
| Nach ext4-Metadaten nutzbar | 105.089.261.568 B = **97,87 GiB** |
| davon belegt (Stand 29.09.) | 33 GB = 34 % |
| Inodes | 6.553.600, davon 6.553.589 frei |
| Dateibestand | 162.254 Dateien, 21.979 Verzeichnisse, 4.118 Symlinks |

Die 100 sind die **Loop-Groesse**, nicht der nutzbare Platz — ext4 rechnet
Journal und Inode-Tabellen ab, das sind die 2,13 GiB Differenz.

### Warum ueberhaupt ein Loop

Der Ausloeser war der 50-GB-Versuch vom 2026-09-26: `/projects` waechst durch
`node_modules` und Build-Artefakte unbegrenzt, und weil es im selben
Dateisystem liegt wie Caddy, MariaDB und die 10 Prod-Container, nimmt ein
`rm -rf` im Dev-Container den **gesamten Prod-Stack** mit. Ein eigenes
Dateisystem begrenzt den Schaden auf 100 GB.

### Warum kein Volume und keine echte Partition

* **Kein Named Volume:** `code-remote-projects` ist entfallen. Ein Pfad unter
  `/var/lib/docker/volumes` kann von Docker als verwaist eingestuft und
  wegrationalisiert werden; `/srv/dev-projects` ist fuer ihn ein normaler
  Host-Pfad.
* **Keine Partition auf `vda`:** die ist nicht moeglich. `parted print free`
  zeigt 0,00 GiB freien Bereich — `vda4` belegt 1,20 bis 300 GiB. Und `vda4`
  ist **XFS**, das sich nicht verkleinern kann (`xfsresize` waechst nur,
  `xfs_info` zeigt kein `resize_inode`). Die Partition ist ausserdem die letzte
  der GPT-Tabelle und traegt das Root-Dateisystem, also nicht unmountbar. Wer
  ehrlich 100 GB *physisch getrennten* Platz will, braucht eine zweite
  Cloud-Volume. LVM hilft dabei nicht: es schichtet, es erzeugt keine Bloecke.
* **ext4 statt XFS** auf dem Loop, weil nur ext4 spaeter schrumpfen kann.

### Einrichtung (auf einem frischen VPS)

```bash
truncate -s 100G /srv/dev-100g.img
mkfs.ext4 -L devprojects -m 0 -q /srv/dev-100g.img
mkdir -p /srv/dev-projects
mount /srv/dev-100g.img /srv/dev-projects
chown 1000:1000 /srv/dev-projects
```

`fstab` (die UUID als Quelle **nicht** nehmen, siehe `AGENTS.md` §14.1):

```
/srv/dev-100g.img /srv/dev-projects ext4 loop,defaults,noatime 0 2
```

Datenumzug vom alten Volume, dann verifizieren und das alte loeschen:

```bash
docker stop code-dev code-remote-dind
rsync -a /var/lib/docker/volumes/dev-vm_code-remote-projects/_data/ /srv/dev-projects/
rsync -a --dry-run --itemize-changes \
      /var/lib/docker/volumes/dev-vm_code-remote-projects/_data/ /srv/dev-projects/
# leerer Output = bit-identisch. Erst DANACH das alte Volume entfernen:
docker volume rm dev-vm_code-remote-projects
```

### Boot-Persistenz pruefen

Der einzige ehrliche Beweis ist ein `mount -a` ohne vorheriges Mounten:

```bash
umount /srv/dev-projects && mount -a && findmnt /srv/dev-projects
```

### Performance gegenueber einem normalen Dateisystem

Der Pfad beim Schreiben ist `ext4 → Loop-Device → XFS-Datei → Platte`, also
**zwei Journale in der Kette**. Gemessen wurde das nicht synthetisch, die
Zahlen sind Erfahrungswerte fuer Image-Workloads:

| Workload | Overhead |
|---|---|
| Sequentielle Writes (`pnpm install`, `git clone`, Build-Artefakte) | ~0–5 % |
| Metadatenlastig, viele kleine Dateien (`node_modules`) | ~5–15 % |
| `fsync`-lastige Builds | spuerbar, nicht kritisch |

Zwei Dinge halten den Overhead klein: `truncate` erzeugt die Datei **sparse**
(100 GiB apparent, anfangs 518 MB belegt, inzwischen 34 GB), und der Kernel
aktiviert auf Loop-Devices automatisch **Direct I/O** — damit entfaellt die
doppelte Page-Cache-Schicht. Aeltere Howtos mit „Loop ist langsam“ stammen von
vor Linux 4.10.

### Der Preis: er kauft einen Deckel, keinen Platz

Vorher 61 GB belegt auf `/`, nachher 65 GB. Die Daten liegen auf ext4 statt
XFS, und ext4 belegt rund 2 GB mehr, weil XFS File-Tails ueber Extents packt.
Dafuehr gibt es 97,87 GiB, die `rm -rf` nicht sprengen kann.

### Der offene Punkt

Der Loop ist die **einzige** Kopie der Projekte. Faellt der Mount beim Boot
aus, startet `code-dev` mit leerem `/projects`, und `gh repo clone` holt nur den
Code zurueck — nicht `node_modules`, `.env`-Fragmente oder uncommittete Arbeit.
Ein Boot-Check existiert bisher nicht. Details: `AGENTS.md` §14.

### Historie

* **2026-09-26** (`3d3a046`): 50-GB-Loopback eingefuehrt, Log-Limits dazu.
* **2026-09-27** (`c5d3c7b`): **verworfen.** Begruendung dort: das waechsende
  Verzeichnis sind nicht die Logs, sondern die Projekte selbst; ausserdem
  hostseitiger `fstab`-Zustand, ein Dateisystem im Dateisystem, und der Pfad
  musste in Compose und `fstab` identisch bleiben. Nach dem Revert 24 % statt
  98 % Belegung.
* **2026-09-29**: bewusst wieder aufgegriffen, mit 100 GB statt 50, ext4
  statt XFS und als Bind-Mount auf `/srv` statt als Volume-Pfad. Die drei
  damaligen Einwaende gelten unveraendert — sie wurden nicht ausgeraeumt,
  nur in Kauf genommen.

## Persistenz (Updates loggen nichts aus)

| Inhalt | Ordner | Volume |
|---|---|---|
| `gh auth` | `/home/dev/.config/gh` | `gh-config` |
| SSH-Keys | `/home/dev/.ssh` | `gh-ssh` |
| Projekte | `/projects` | **Bind-Mount `/srv/dev-projects`** (100-GB-Loopback, ext4) |
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
