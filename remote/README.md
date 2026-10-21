# Remote-Weg / Prod (VPS-nativ)

* Image `opencode-web-dev-baseline` (`Dockerfile` hier): Debian bookworm-slim +
  Node 26.x + pnpm + PHP 8.5 (Sury) + Composer v2 + `gh` + Docker-CLI + **opencode** (v2)
  + CodeGraph-CLI + Python/uv/markitdown + nano.
  Versionen floaten: Daily-CI holt jeweils latest (opencode-Layer per Build-ARG
  gezielt ohne Cache, damit mehrmals taegliche V2-Releases wirklich landen).
* Stack `code-remote` (`docker-compose.yml` hier): `code-dev` + isolierter
  `dind`-Daemon + eigener `code-auth-remote`. Nur Netz `code-remote` — kein `webnet`,
  daher keine Prod-Container per Name erreichbar, Internet via NAT ok.
  `code-dev` ist standardmäßig auf 3 CPU-Kerne, **5 GB RAM plus 4 GB Swap**
  begrenzt; über `CPU_CORES`, `MEMORY_LIMIT` und `MEMSWAP_LIMIT` im
  Stack-Environment anpassbar. Wichtig: `memswap_limit` muss größer sein als
  `mem_limit`, sonst ist der Swap-Deckel exakt so hoch wie das RAM-Limit.
  Wichtig für die Rechnung: `memswap_limit` ist der **Gesamt**-Deckel, bei 5g/9g
  also 5 GB RAM plus 4 GB Swap-Puffer — Swap ist ab dem 2026-10-20 **Puffer,
  nicht Reserve**: er fängt Lastspitzen ab, wenn RAM global knapp wird. Der
  RAM-Deckel liegt seit dem **2026-10-21** wieder **unter** dem nutzbaren
  Host-RAM (7,47 GiB) — 5 GB statt 7 GB, weil der Host geschont werden soll
  (Owner-Entscheidung; Begründung und Messwerte in *RAM- und
  Swap-Limits*).
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

Aktuelles Budget (**Werte in Kraft seit dem 2026-10-21**):

| Container | RAM | Swap | gesamt | cpus |
|---|---|---|---|---|
| `code-dev` | 5120 MB | 4096 MB | 9216 MB | 3 |
| `code-remote-dind` | 1024 MB | 1024 MB | 2048 MB | 2 |
| `code-auth-remote` | unbegrenzt | — | — | — |
| **Summe** | **6144 MB** | **5120 MB** | **11264 MB** | |

`code-auth-remote` bleibt bewusst unbegrenzt — real 11 MB, und ein Deckel
wuerde nur Aerger machen.

**Die Summe der RAM-Limits (6144 MiB = 6,0 GiB) liegt jetzt unter den 7,47 GiB
nutzbaren Host-RAM** — zusammen mit Portal (~0,9 GiB) und OS/dockerd (~0,7 GiB)
sind das ~7,6 GiB, rund 0,1 GiB **über** dem Host. Gegenüber dem Stand vom
2026-10-20 (7g RAM / 9 GiB Swap, ~2,1 GiB über dem Host) sind das rund
**2 GiB weniger Überschuss**. Die Restdifferenz wird über **Swap**
ausgeglichen, nicht über weniger RAM — siehe „Der Host-Hänger vom 2026-10-20“
unten.

RAM und Swap liegen bei `code-dev` bei 5 GiB / 4 GiB, beim DinD bei 1 GiB /
1 GiB: Builds im Daemon sind Batch-Arbeit, Latenz ist egal. **Seit 2026-10-20
ist Swap für `code-dev` ausdrücklich eingeplant** — er ist Puffer, nicht
Reserve. Seit dem 2026-10-21 liegt der RAM-Deckel (5 GiB) **unter** dem
nutzbaren Host-RAM (7,47 GiB); der Swap-Puffer fängt die Restdifferenz und
Lastspitzen ab. „`code-dev` soll nicht swappen" gilt ab hier nicht mehr.

#### Die Owner-Entscheidung vom 2026-10-21: Gesamt-Deckel 9 g

**`MEMSWAP_LIMIT` = 9 g — nicht 16 g.** Begründung des Eigentümers: der Host
soll geschont werden, 4 GiB Swap reichen. Das ist die seit dem Recreate vom
2026-10-21 **gemessene** Konfiguration, die in Betrieb ist — der recreatete
Container hatte `memory.max` = **5,0 GiB** und `memory.swap.max` = **4,0 GiB**,
also 9 GiB gesamt.

Drei Belegungen, ein Wert:

| Beleg | RAM | Gesamt (`MEMSWAP_LIMIT`) | Swap (`= memswap_limit − mem_limit`) |
|---|---|---|---|
| Compose-Fallback (`remote/docker-compose.yml`) | `5g` | `9g` | 4 GiB |
| `.env.example` (Paste-Vorlage) | `5g` | `9g` | 4 GiB |
| laufender Stack-Env (Portainer, 2026-10-21) | `5g` | `9g` | 4 GiB |

**Die Kopplung ist der Grund, warum nicht nur eine Zahl geändert wurde.**
`MEMSWAP_LIMIT` ist der **Gesamt**-Deckel, der Swap-Deckel ist
`memswap_limit − mem_limit` (Formel oben). Ein blinder Wechsel nur auf
`MEMSWAP_LIMIT` hätte bei unverändertem `MEMORY_LIMIT=7g` nur **2 GiB** Swap
gelassen — weniger als die gemessene Reserve (4 GiB) und weniger als der
bisherige Fallback (9 GiB). Deshalb wandert der RAM-Fallback mit:
**5 GiB RAM + 4 GiB Swap = 9 GiB gesamt**. Der alte Fallback 7g/16g ist damit
**ersetzt**, nicht nur die eine Zahl.

**Merke für den nächsten Paste:** der Compose-Default greift nur, wenn
`MEMORY_LIMIT`/`MEMSWAP_LIMIT` in der Stack-Env **fehlen**. Die
Portainer-Vorlage `remote/.env.production` (gitignored, nicht im Repo) muss
deshalb dieselben Werte tragen — sonst überschreibt sie den Fallback wieder
und die Maßnahme wirkt stillschweigend nicht.

**Was das materiell ändert:** eine Installation **ohne** Stack-Env bekommt
künftig **5 GiB** Container-RAM statt **7 GiB** — 2 GiB **weniger** RAM für
den Container und **mehr** für den Host (7,47 GiB nutzbar). Die
**Swap-Reserve bleibt bei 4 GiB** (statt 2 GiB bei einem blinden
`MEMSWAP_LIMIT`-Wechsel). Das ist die gewollte Richtung („Host schonen") und
**keine** Verschlechterung der Swap-Reserve.

### Warum 2 GB nicht gereicht haben — und warum 3 GB auch noch nicht reichen

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
`vm.swappiness` war **10** (persistiert in `/etc/sysctl.conf`, mtime April).
Der Wert `0`, den ich gemessen und falsch etikettiert hatte, war
`vm.overcommit_memory`.

**Stand 2026-10-20: `vm.swappiness` ist 60** (ebendort persistiert). Grund steht
im Abschnitt „Der Host-Hänger vom 2026-10-20“ — bei swappiness 10 hat der
Kernel den Swapfile praktisch nie angefasst.

Live gegengeprueft am 2026-09-30: `memory.swap.current` = **597 MB von 4096 MB
genutzt**. `memswap_limit` ist also echte Reserve, keine Zahl.

Das verschiebt die Groessenordnung: `code-dev` bei 4g/8g hatte ein **Gesamt-
budget von 8 GB** — und `opencode serve` als PID 1 wurde am 30.09. um 08:46
trotzdem getoetet. Der Grund ist also nicht der Swap, sondern anon-Druck:
`rustc`/`rust-lld`/`clippy-driver` 220–920 MB pro Instanz, dazu Chrome aus
Playwright-Läufen.

### Der Host-Hänger vom 2026-10-20 — was wirklich passiert ist

Am 2026-10-20 um **16:05:52 CEST** ist der Host **2 min 44 s komplett
eingefroren** (rsyslog ohne eine einzige Zeile, dockerd konnte keine
Health-Checks mehr forken, der Cron-Job bekam HTTP 502) und wurde um 16:08:36
hart neugestartet. Die Zeitleiste steht in `agents.todo.md`. Die drei
wesentlichen Befunde:

**1. Der alte Wächter hat die cgroup geschützt — nicht den Host.** Er
beobachtete `memory.current` und löste bei 90 % aus. **Diese Größe ist
richtig** für den cgroup-Deckel: `memory.max` gilt für `memory.current`, und
der Container stand beim Auslösen tatsächlich bei 90–95 %:

| Zeit (CEST) | `memory.current` | Anteil am 7-GiB-Deckel |
|---|---|---|
| 13:17:30 | 6.800.273.408 B | 90 % |
| 16:05:20 | 7.042.101.248 B | 93 % |
| 17:19:37 | 7.164.485.632 B | 95 % |

**Der Fehler war nicht die Messung, sondern die Prämisse:** der Wächter hielt
das Erreichen des cgroup-Deckels für einen Punkt, an dem man sich noch
vergnügen kann. Aber der Deckel (7 GiB) ist **mehr als der nutzbare Host-RAM**
(7,47 GiB), und daneben laufen dind (1g), der Portal-Stack (~0,9g) und
OS/dockerd (~0,7g). Als der Wächter bei 6,3 GiB im code-dev auslöste, stand
der Host bei **783 MB MemAvailable und 6,3 GB Swap** — er war am Abgrund, und
das SIGTERM an PID 1 kam zu spät.

*Zur Cache-Frage (eine Korrektur der ersten Fassung dieser Doku):*
`memory.current` enthält den reclaimbaren Page-Cache, und der Anteil ist
zeitabhängig — in einem frischen Container (Messung 17:45 CEST nach dem
Neustart) `anon` 970 MB / `file` 1164 MB / `current` 2389 MB, also **49 %
Cache**; in einem Container mit stundenlangem Build wächst der Cache-Anteil.
**Die `anon`/`file`-Aufteilung zum Auslösezeitpunkt ist nicht rekonstruierbar**,
weil der alte Wächter sie nicht protokolliert hat. Die Aussage „der Wächter
hat 92 % Cache gemessen" ist damit **nicht belegbar** und war in der ersten
Fassung dieses Abschnitts falsch. Die neue Regel in `remote/AGENTS.md` §9
lautet daher nicht „`memory.current` ist falsch", sondern: **für die
Eskalation zählt `MemAvailable` des Hosts, und für „welcher Prozess frisst
echten Speicher" zählt `anon`, nicht RSS.**

**2. Der Wächter konnte den Host nicht retten, weil seine Schwelle zu hoch war.**
90 % von 7g = **6,3 GiB** bei **7,47 GiB** nutzbarem Host-RAM. Bei diesem
Stand war der Host bereits überzeichnet: code-dev 7g + dind 1g + Portal 0,9g +
OS 0,7g = 9,6 GiB. Live im Incident: `MemAvailable` **783 MB** bei **6,3 GB**
Host-Swap. Die „Rettung" kam zu spät — sie rettete den Container und
trotzdem nicht den Host.

**3. Der Swap wurde nie benutzt.** `SwapFree` stand beim Crash auf den vollen
10 GB. `vm.swappiness=10` heißt: der Kernel swapped erst, wenn RAM **global**
knapp wird — also erst, wenn es zu spät ist.

#### Die drei Massnahmen (2026-10-20)

| # | Massnahme | Wo |
|---|---|---|
| 1 | `memswap_limit` 12g → **16g** (9 GB Swap für code-dev) | `remote/docker-compose.yml` **und** `remote/.env.production` |
| 2 | `vm.swappiness` 10 → **60**, Swapfile 10 GB → **16 GB** | `/etc/sysctl.conf`, `/swapfile` |
| 3 | `ram-watchdog.sh` misst jetzt den **Host** statt den cgroup-Deckel (Host-Eskalation per Default praktisch aus) | `remote/ram-watchdog.sh` |

**Maßnahme 1 muss an zwei Stellen stehen.** Der Compose-Default `:-16g` greift
nur, wenn `MEMSWAP_LIMIT` in der Stack-Env **fehlt** — die Paste-Vorlage
`remote/.env.production` setzt ihn aber explizit. Wer nur die Datei ändert,
lässt den alten Wert 12g über die Vorlage in die Portainer-Stack-Env zurück —
die Massnahme wirkt dann stillschweigend nicht.

> **Stand 2026-10-21:** Diese Drift-Stelle ist geschlossen. Der Compose-Default
> lautet jetzt `MEMORY_LIMIT:-5g` / `MEMSWAP_LIMIT:-9g`, die Vorlage
> `.env.example` nennt dieselben Werte, und der laufende Stack-Env ebenfalls —
> alle drei Belegungen sind deckungsgleich (5 GiB RAM + 4 GiB Swap). Der
> historische Wert 16g oben beschreibt den Stand vom 2026-10-20; die
> Owner-Entscheidung vom 2026-10-21 hat ihn auf 9g **zurückgenommen** (Host
> schonen, 4 GiB Swap reichen). Details: „Die Owner-Entscheidung vom
> 2026-10-21" oben.

Der neue Wächter hat **zwei Trigger**:

- **A) Container** — `anon + slab_unreclaimable` ≥ `RAM_WATCHDOG_THRESHOLD_PERCENT`
  (85 %) von `memory.max`. Das ist die OOM-relevante Größe. Reaktion: SIGTERM an
  PID 1, nach 30 s SIGKILL — ein geordneter Shutdown statt des abrupten
  Kernel-Kills, dessen Opfer immer PID 1 wäre.
- **B) Host** — `MemAvailable` des Hosts < `RAM_WATCHDOG_HOST_AVAILABLE_MB`
  (**100 MB per Default — damit ist der Host-Trigger praktisch aus**).
  `/proc/meminfo` im Container zeigt die **Host-Werte**
  (verifiziert 2026-10-20: `MemTotal` 7832632 kB, identisch mit dem Host).
  MemAvailable < 100 MB kommt auf einem Host mit 7,47 GB RAM praktisch nicht
  vor — die Eskalation ist damit **praktisch aus**. Ein gesetzter
  `RAM_WATCHDOG_HOST_AVAILABLE_MB` **schärft den Trigger** nur, er ist keine
  Voraussetzung dafür (etwa in der Portainer-Stack-Env). Reaktion, wenn der
  Trigger scharf ist:
  Eskalationsleiter — erst die **Speicherfresser-Kinder** beenden (CodeGraph-
  MCP-Server, Dev-Server, Builds), sortiert nach **anon** (Private_Dirty), die
  größten zuerst, bis die Zielsumme (`RAM_WATCHDOG_CHILD_RSS_MB` = 300 MB)
  erreicht ist; erst als **letzte** Maßnahme PID 1. „Host soll immer leben,
  notfalls der Container."
- **Der Host-Swap ist Warnung, kein Eskalationsgrund.** Mit `swappiness=60` und
  9 GiB Swap-Deckel ist ein Swap-Füllstand von mehreren GB der Normalzustand
  jeder Lastspitze (live im Incident: 6,3 GB Swap bei 783 MB MemAvailable).
  Er wird protokolliert (`RAM_WATCHDOG_HOST_MAX_SWAP_PERCENT` = 80 %), löst
  aber nichts aus.

**Entscheidung des Eigentümers (2026-10-21): B2/B3 sind per Default praktisch
aus (Schwelle 100 MB).**
Der Host hat 16 GB Swap und 7,47 GB RAM — das reicht; es sollen keine Builds
und keine Sitzungen mehr für den Host geopfert werden. `htop` am 2026-10-21:
Mem 3,38 G von 7,47 G, Swap 1,0 G von 16,0 G. Der Wächter hat an diesem Tag
trotzdem dreimal ausgelöst: 15:31 B2 (TERM an einen `tsc` mit 951 MB anon),
15:32 B2 (TERM an einen `tsc` mit 1,33 GB anon) und 15:32:06 B3 (SIGTERM an
PID 1 → Container-Neustart → **die Sitzung war weg**). Der Live-Container
läuft deshalb mit einem Live-Hotfix (`RAM_WATCHDOG_HOST_AVAILABLE_MB=100`), der
**keinen Container-Neustart überlebt**: `entrypoint.sh` startet den Wächter bei
**jedem** Container-Start neu — `docker restart` genauso wie ein Recreate —,
und solange das deployed Image den alten Default 1000 MB hat, ist B nach jedem
Neustart wieder scharf. Dauerhaft ist der Zustand erst, wenn das neue Image
deployt ist. **B schärfen:** den
Wert in der Portainer-Stack-Env setzen (`RAM_WATCHDOG_HOST_AVAILABLE_MB=…`) —
er **schärft** den Trigger, er ist keine Voraussetzung dafür; der Codepfad
B2/B3 ist unverändert vorhanden. **Der Wert 1000 MB ist der Stand vor dem
21.10. und keine Empfehlung:** er hat am 21.10. unter paralleler Build-Last
ausgelöst (MemAvailable 623–914 MB), Builds werden dann unterbrochen — die
Grenze zwischen „normaler Build" und „Host hängt" ist bei diesem Workload
nicht sauber zu ziehen. **Zwei Vorbedingungen:** der Stack-Env-Wert erreicht
den Container erst, wenn die Compose-Datei aus dem Repo (mit dem Mapping im
`environment:`-Block) deployed ist — vorher bleibt er wirkungslos; und nach
**jedem** Paste von `.env.production` als Stack Environment ist der Wert
erneut zu setzen, weil Keys, die nur in der Portainer-DB stehen, dabei
gelöscht werden.

**B3 wird nur ausgelöst, wenn code-dev auch schuld ist**
(`RAM_WATCHDOG_CONTAINER_SHARE_MIN_PCT` = 50 %): Hält code-dev weniger als die
Hälfte des Host-Speicherverbrauchs, kommt der Druck von außen (dind,
Portal-Stack, dockerd) — ein Container-Neustart würde nichts freimachen und
nur die Sitzung vernichten. Zusammen mit `RAM_WATCHDOG_HOST_HOLD_COUNT` = 3
(Druck muss anhalten) und `RAM_WATCHDOG_STARTUP_GRACE_S` = 180 s (nichts direkt
nach einem Neustart) kann die **Neustart-Schleife** damit nicht entstehen.

**Verifikation (2026-10-20):** Die Codepfade sind gegen **Dummy-Prozesse**
verifiziert, **nie gegen das echte PID 1** — in einem Wegwerf-Container, in dem
PID 1 ein `sleep` mit gefälschtem argv[0] ist. Beleg:
`HOST-DRUCK (1/3)` → `HOST-DRUCK (2/3)` → `HOST-DRUCK (3/3)` → Eskalation;
`HOST-DRUCK, aber erst 0s nach Container-Start — keine Eskalation`;
`B2: TERM an PID 20 (107940 kB, fakenode)` mit den beiden kleineren Dummies
weiterhin am Leben.

**Was dabei kaputtging (und im Repo dokumentiert ist):** der erste Testlauf
fand im **Produktions-**Container statt, weil das Kind-Matching dort nicht
neutralisiert war — die 4 realen CodeGraph-Server wurden beendet, und ein
zweiter Testlauf schickte ein SIGTERM an das echte PID 1 (der Container startete
neu). **Lehre: Trigger-Tests laufen ausschließlich in einem Wegwerf-Container,
niemals gegen die laufende Instanz.** Siehe `agents.todo.md`.

#### Was CodeGraph wirklich kostet

Live am 2026-10-20 gemessen (`smaps_rollup`, nicht `ps`):

| | RSS | davon **anon** |
|---|---|---|
| `opencode serve` (PID 1) | 566 MB | **426 MB** |
| 4 × CodeGraph-MCP-Server | 440 MB | 230 MB |
| 4 × CodeGraph-Bridge | 220 MB | 64 MB |
| **CodeGraph gesamt** | **660 MB** | **294 MB** |

Der Rest der 660 MB ist **mmap'd SQLite-Index + Node-Binary** — reclaimbarer
Page-Cache, den der Kernel unter Druck fallen lässt. **opencode selbst ist mit
426 MB anon der größere Posten.** Pro gleichzeitiger Session kostet CodeGraph
~74 MB anon; bei 7 offenen Sessions sind das ~515 MB.

Es gibt **kein** Deinstallieren-Empfehlung: die CLI-Alternative ist schlechter
(`codegraph explore` per CLI: **276 MB Peak-RSS pro Aufruf**, 1,2 s — ein
kompletter MCP-Server kostet dauerhaft 164 MB), und `codegraph serve` ohne
`--mcp` startet **keinen** HTTP-Server (nur stdio) — ein geteilter Daemon für
alle Sessions existiert in v1.6.2 nicht.

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
5120 MB RAM plus 4096 MB Swap (`MEMORY_LIMIT` / `MEMSWAP_LIMIT`); die Werte
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
