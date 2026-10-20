# AGENTS.md — Regeln fuer `remote/` (VPS-Weg)

Beschreibung und Messwerte stehen in [`README.md`](README.md). Hier nur die
Regeln fuer `docker-compose.yml` / `entrypoint.sh` / `.env.production`.
Allgemeine Auth-Regeln: [`../AGENTS.md`](../AGENTS.md).

## 1. Deploy: Portainer-UI ist der Normalfall, SSH ist der dokumentierte Ausweg

`docker-compose.yml` wird in den Web-Editor gepastet, `.env.production` als
Stack Environment. Ein File, kein Upload. Nach jeder Aenderung: Stack in
Portainer neu deployen — eine Datei im Repo aendert auf dem VPS **nichts**.

`.env.production` ist gitignored und trotzdem die einzige Quelle fuer den
laufenden Stack. `setup.sh` schreibt sie **nicht** (nur `.env`). Jede Zeile muss
`KEY=WERT` ergeben, wenn sie eingefuegt wird.

### Der SSH-Weg

```sh
cd /var/lib/docker/volumes/portainer_data/_data/compose/49   # Stack dev-vm
docker compose --env-file stack.env -p dev-vm up -d --no-deps code-dev
```

**Immer `--no-deps` und immer nur den einen Service, der sich wirklich
geaendert hat.** Grund ist §2: `docker compose --env-file` escaped `$$` **nicht**
— ein volles `up -d` recreated auch `code-auth-remote`, der dann `$$2a$$14$$…`
statt `$2a$14$…` bekommt; `ensure_bcrypt()` prueft auf `$2` und der Sidecar
startet nicht. **Vorher den Diff ansehen, dann entscheiden, welche Services
betroffen sind** — nicht pauschal `up -d`.

### Was ein SSH-Deploy NICHT pflegt: die Portainer-DB

Portainer haelt die Stack-Env in seiner Datenbank und schreibt `stack.env` bei
jedem **UI**-Deploy daraus neu. Ein per SSH deployter Stack laeuft also korrekt,
verliert aber neue Env-Keys beim naechsten Browser-Klick. Siehe §17 fuer den
Patchweg und §9 Fall 1.

## 2. `AUTH_HASH` gehoert als `$$2a$14$…` in `.env.production`

Portainer interpoliert den Env-Wert, bevor er den Container erreicht; der
Sidecar bekommt also `$2a$14$…`. `AUTH_HASH` ist der einzige betroffene Wert
(die anderen enthalten kein `$`).

**Nicht "aufraeumen".** `docker compose --env-file` escaped `$$` *nicht* — wer
lokal testet, sieht den Wert doppelt escaped und macht ihn unescaped, womit der
Login auf `remote-code` kaputt ist (Container-Start bricht ab mit
`AUTH_HASH-Format unsupported`, weil `ensure_bcrypt()` auf `$2` prueft). Im
Zweifel `docker inspect code-auth-remote` gegenpruefen, nicht lokal composen.

## 3. Niemals `extra_hosts` / `host-gateway` zuruecknehmen

`extra_hosts` repariert `127.0.0.1` nicht, es **ergaenzt nur einen Namen fuer
eine Host-IP** — es oeffnet eine Tuer zum ganzen VPS (Portainer-UI auf `8000`
unverschluesselt, Portainer-API auf `9443`, Caddy auf 80/443). Nicht
zuruecknehmen.

`127.0.0.1` in `code-dev` **ist** der Container, und das ist richtig so: ein
Dev-Server (`pnpm dev`) laeuft direkt in `code-dev`. Die Loesung fuer "localhost
laesst sich im Container nicht nutzen" ist nicht Docker, sondern: **Dev-Server
nach `code-dev`, Wegwerf-Container nach DinD.**

`HOST_GATEWAY` ist entfernt und wird nirgends referenziert — nicht wieder
aufnehmen.

## 4. `dind` bleibt rootless — nie `privileged: true`

`privileged: true` ergibt alle Capabilities und sichtbare Host-Blockdevices —
also faktisch Root auf dem Host, mit `/home/webadmin/websites`, den
MariaDB-Volumes, den TLS-Keys, `portainer.db` und der rclone-Config in
Reichweite (`code-dev` hat die Docker-CLI und zeigt per `DOCKER_HOST` auf diesen
Daemon). Rootless lassen.

## 5. Die drei `security_opt` sind einzeln noetig

`seccomp=unconfined`, `systempaths=unconfined`, `/dev/net/tun` — **alle drei
zusammen** starten den rootless-Daemon ueberhaupt:

- ohne `seccomp=unconfined` blockt der Default-Seccomp `unshare(CLONE_NEWUSER)`
- ohne `systempaths=unconfined` schlaegt der `/proc`-Mount im nested userns fehl
- ohne `/dev/net/tun` findet rootlesskit kein tap-Device fuer slirp4netns

Wer eines davon als "ueberfluessig" entfernt, killt den Daemon im Restart-Loop.

## 6. Kein Host-Pfad als Data-Root

Der rootless-Daemon nutzt ohne `--data-root` sein Default
`$HOME/.local/share/docker` = `/home/rootless/.local/share/docker` (uid 1000).
Ein Mount auf `/var/lib/docker` ist **wirkungslos**; der richtige Mount ist
`dind-data-rootless:/home/rootless/.local/share/docker`.

## 7. Adressierung im DinD: Name, nie Loopback, nie Host-IP

`docker run -p 127.0.0.1:X:Y` im DinD bindet nur im **DinD-Netzraum** und ist von
`code-dev` aus nie erreichbar. Wegwerf-Testcontainer gehoeren per `--network` in
ein geteiltes Netz und werden per Containername angesprochen (`db:5432`,
`mailpit:8025`). Loopback funktioniert containeruebergreifend nie.

## 8. Volumes sind Named Volumes, kein Docker-Wurzelverzeichnis

`gh-config`, `gh-ssh`, `opencode-data/-config/-state` tragen `gh auth`,
SSH-Keys und den OpenCode-Zustand — sie ueberleben Image-Upgrades. Genau darum
sind es Named Volumes. `gh auth login` ist nach einem Stack-Recreate **nicht**
noetig; wenn doch, ist ein Volume verloren gegangen, nicht das Passwort.

**Ausnahme `/projects`:** Bind-Mount auf `/srv/dev-projects`, kein Named Volume.
Siehe §14 — dort steht auch, warum dieser Pfad *nicht* unter
`/var/lib/docker/volumes` liegen darf.

## 9. RAM- und Swap-Limits: `memswap_limit` ist der **Gesamt**-Deckel

- `memory.max = mem_limit` (RAM-Deckel), `memory.swap.max = memswap_limit -
  mem_limit` (reiner Swap-Deckel). `memswap_limit` setzt man, um das
  **Verhaeltnis** zu bestimmen; es muss **groesser** als `mem_limit` sein. Die
  beiden Werte gleich zu setzen ist keine "sichere" Wahl, sondern die
  Dokumentation des Fehlers.
- **Kein gemeinsames Limit fuer code-dev und dind.** Bei OOM waehlt der Kernel
  den GROSSTEN Prozess im cgroup — das ist der dind-Daemon, nicht der schuldige
  Build. Deshalb zwei getrennte Limits: ein runaway Build stirbt nur
  `code-remote-dind`, die `code-dev`-Session laeuft weiter. Limits am
  dind-Container greifen fuer die inneren Container mit, Limits an inneren
  Containern nicht.
- **`code-dev` hat kein harmloses Opfer — sein groesster Prozess ist PID 1**
  (`opencode serve`). PID 1 killen = der Container stirbt = `restart:
  unless-stopped` = **die Sitzung ist weg**. Nichts darf hier den PID-1-Pfad
  ausloesen — **ausser dem RAM-Waechter** (siehe unten).
- **Die RAM-Limits dieses Stacks summieren sich gegen einen Host, der zugleich
  Produktion faehrt.** Wer hier "nur ein bisschen mehr" sagt, muss die Summe
  gegenrechnen, nicht den einzelnen Container.

### Der RAM-Waechter schuetzt den Host — nicht den Container (Entscheidung 2026-10-20)

Regeln fuer `remote/ram-watchdog.sh`:

- **Nur der RAM-Waechter darf PID 1 beenden.** Kein anderer Pfad im Stack.
- **Zwei Trigger, zwei Reihenfolgen:**
  - *Container-Trigger* (`anon + slab_unreclaimable` gegen `memory.max`):
    sofort SIGTERM an PID 1. Ersetzt den abrupten Kernel-OOM-Kill, dessen
    Opfer immer PID 1 waere, durch einen geordneten Shutdown.
  - *Host-Trigger* (`MemAvailable` des Hosts unter der Schwelle): erst die
    Speicherfresser-Kinder beenden, **erst danach** PID 1.
- **Nicht an `memory.current` messen.** Der Page-Cache zaehlt mit; wer nach
  `memory.current` sortiert, trifft die falschen Prozesse. Fuer "welcher
  Prozess frisst echten Speicher" gilt `anon` (Private_Dirty aus
  `smaps_rollup`), nicht RSS.
- **B3 (PID 1 beenden) nur, wenn der Container auch schuld ist.** Ist der
  Host-Druck fremd (dind, Portal-Stack, dockerd), behebt ein Container-Neustart
  nichts — er vernichtet nur die Sitzung und haelt die Schleife am Laufen.
- **Kein Neustart im Kreis.** Der Host-Druck muss ueber mehrere Messungen
  anhalten, und direkt nach einem Container-Neustart fasst der Waechter nichts
  an.
- **Der Host-Swap ist eine Warnung, kein Eskalationsgrund.**
- **Nur PID 1 als Ziel.** Endet der Waechter auf einem Kindprozess, laeuft der
  Container ohne Wächter weiter — das waere genau der Verlust, den die
  Eskalation verhindern soll.

### Der RAM-Deckel wird an `anon` gemessen, nicht an `memory.current`

- **`memory.current` hoch heisst nichts.** Es enthaelt den **reclaimbaren
  File-Cache** — nach jedem Vite-, Playwright- oder `cargo`-Lauf nahe am Deckel,
  ohne echtes Speicherproblem. OOM-relevant sind nur `anon` +
  `slab_unreclaimable`.
- **`memory.peak` ueber `memory.max` ist KEIN Alarm**, solange `anon` niedrig
  war — `peak` zaehlt Cache mit. Ein OOM entsteht nur, wenn `anon` den Deckel
  erreicht.
- Die echte Frage ist: war `anon` am Limit? Messen so:
  ```sh
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
  grep -E '^(anon|file|slab_unreclaimable) ' $CG/memory.stat
  grep -E 'oom_kill' $CG/memory.events
  ```
- **Merksatz fuer Messungen: `vm.overcommit_memory` und `vm.swappiness` sind
  zwei verschiedene Sysctls.** Bei RAM-Diagnosen immer das vorherige Kommando
  mitlesen, sonst wird die naechste Massnahme auf einer Verwechslung gebaut.

### Zwei Faelle, in denen die DB gepatcht wird — und wann NICHT

Nach dem Schema in §17.4:

- **Fall 1: Neuer Env-Key, der per SSH-Deploy kam.** Der Stack laeuft korrekt,
  aber Portainer kennt den Key nicht und schreibt `stack.env` bei jedem
  UI-Deploy ohne ihn neu.
- **Fall 2: Sichtbarkeit.** Werte, die bisher nur als Compose-Default
  existierten, in die Env heben, damit sie in der UI sichtbar und editierbar
  sind. Nachteil: ab jetzt schlaegt der DB-Wert der Datei still.
- **Nicht** patchen, wenn nur ein Compose-Default geaendert wurde: der Default
  greift ohnehin, und der Weg durch die DB erzeugt nur eine zweite Quelle der
  Wahrheit.
- **Immer `.env.production` mitziehen** (§1). Stehen die Keys nur in der DB und
  nicht in der Datei, loescht der naechste Paste sie wieder.

### Akute OOM-Lage ohne Recreate entschaerfen

`memory.max` ist im laufenden cgroup schreibbar:

```sh
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
echo 4294967296 > "$CG/memory.max"   # 4 GiB
```

**Nur eine Bruecke:** bei jedem `docker restart` wendet Docker die
`HostConfig`-Limits erneut an und ueberschreibt den Direktwert. Ein direkt
geschriebenes `memory.max` gilt bis zum naechsten *Restart*, nicht bis zum
naechsten *Recreate*. Die Compose-Datei ist der einzige Ort, der dauerhaft
wirkt.

## 10. Autoupdate: SIGTERM an PID 1 ist der Mechanismus

`entrypoint.sh` startet den Watcher, der bei neuem Binary **idle** per
`kill -TERM 1` den Container beendet, worauf `restart: unless-stopped` frisch
mit dem neuen Binary startet. `server_idle` fragt `/api/session/active` mit
Basic-Auth (`opencode` + Serverpasswort) ab und **vertagt bei aktiver Session**
— ein Update darf keinen laufenden Run abbrechen. `idle` nicht auf `always`
umstellen.

`OPENCODE_DISABLE_AUTOUPDATE=true` im Image verhindert nur den *In-Process*-
Autoupdate des Servers, nicht diesen Block.

## 11. Auth-Checks im Caddy-Fragment nicht vereinfachen

- `health_headers { Authorization … }` **muss** bleiben: ohne ihn ist
  `/api/info` 401 und der Healthcheck meldet dauerhaft unhealthy.
- `stream_timeout 24h` + `stream_close_delay 5m` gelten fuer WebSocket-Upgrades
  (insbesondere PTY), **nicht** fuer SSE. Kein globales `flush_interval -1`.
- Upstream auf HTTP/1.1 mit `keepalive 4s`: OpenCode antwortet mit
  `Keep-Alive: timeout=5`, Cadys 2h-Default wuerde abgelaufene Sockets
  wiederverwenden (502/WS-Resets).
- `__REMOTE_DOMAIN__` / `__CODE_SITE__` / `__OPENCODE_BASIC__` /
  `__CORS_ORIGIN__` sind Platzhalter und werden von Hand in die **globale**
  Caddyfile uebernommen. Der `__OPENCODE_BASIC__`-Wert gehoert nie ins Repo.
  `__CORS_ORIGIN__` ist die eigene PWA-Origin (`https://ocweb.all-the.rest`),
  keine Liste. Voraussetzung: der `caddy`-Service haengt an `webnet` **und**
  `code-remote`, beide `external: true`. Ein unersetzter Platzhalter ist kein
  Log-Fehler — mit `grep -n '__[A-Z_]*__' Caddyfile` gegenpruefen,
  `sync.sh validate` faengt das nicht.

## 12. `AUTH_HASH` ist bcrypt oder PBKDF2 — kein Klartext-Fallback

Beide Sidecars failen closed: unbekanntes Format -> `SystemExit`, bcrypt-Hash
ohne Modul -> refuses to start. Das ist gewollt. Kein "Fallback auf
Klartext-Vergleich" einbauen, um einen Start zu erzwingen — der Fehler soll an
der Ursache sichtbar sein.

## 13. Nicht verwechseln: `AUTH_HASH` ist nicht `OPENCODE_PASSWORD`

`AUTH_HASH` = Login-Seite (Cookie-Gate, bcrypt, `AUTH_USER`).
`OPENCODE_PASSWORD` = `opencode serve`-Serverpasswort, das Caddy per
`header_up Authorization` injiziert; sie duerfen pro Weg verschieden sein, der
Login der Login-Seite hat damit nichts zu tun. Ein 401 auf `/api/login` ist ein
`AUTH_HASH`-Problem, ein 401 auf `/api/info` ein Basic-Problem. Diagnosebefehle
stehen in [`../AGENTS.md`](../AGENTS.md) Abschnitt 5.

## 14. `/projects` liegt auf einem 100-GB-Loopback — die sieben Regeln

**Wer hier etwas aendert, ohne die Regeln zu kennen, macht den Dev-Container
leer.** Messwerte und Performance: [`README.md`](README.md), Abschnitt
„100-GB-Loopback fuer `/projects`“.

1. **`fstab`-Quelle ist die DATEI, nicht die UUID.** Die UUID haengt am
   Loop-Device, das erst durch `losetup` entsteht — `mount -a` hat sie zum
   Boot-Zeitpunkt also gar nicht. Korrekt ist `/srv/dev-100g.img
   /srv/dev-projects ext4 loop,defaults,noatime 0 2`. Der Dateipfad ist zugleich
   stabiler, weil `/dev/loopN` pro Boot neu nummeriert wird.
2. **`loop` in den Mount-Options ist Pflicht.** Ohne die Option setzt `mount`
   beim Boot kein Loop-Device auf.
3. **Der Pfad muss in `fstab` und `docker-compose.yml` identisch sein.** Im
   Compose steht `- /srv/dev-projects:/projects` **zweimal** — bei `code-dev`
   und bei `dind`. Nur einer von beiden aendern laesst die Dateien auseinander
   laufen.
4. **ext4, nicht XFS.** Nur ext4 hat `resize_inode` und kann damit `resize2fs`
   nach unten; XFS kann ausschliesslich wachsen.
5. **Bind-Mount auf `/srv`, niemals auf einen Pfad unter
   `/var/lib/docker/volumes`.** Docker kann einen Volume-Pfad als verwaist
   einstufen und wegrationalisieren; deshalb heisst §8 fuer `/projects`
   „Ausnahme“.
6. **Der Mountpoint muss `1000:1000` sein.** `code-dev` laeuft als uid 1000
   (`dev`); ein root-owned Mountpoint mit `755` laesst den Agenten nur lesen,
   nicht schreiben — das faellt erst beim ersten Schreibversuch auf.
7. **Single Point of Failure.** Der Loop ist die *einzige* Kopie der Projekte.
   Faellt der Mount beim Boot aus, startet `code-dev` mit leerem `/projects` —
   und `gh repo clone` holt nur den Code zurueck, nicht `node_modules`,
   `.env`-Fragmente oder uncommittete Arbeit. Boot-Schutz fehlt (offen,
   `agents.todo.md`).

### Nicht ins pCloud-Backup

`/usr/local/bin/volume-backup.sh` arbeitet mit einer **Allowlist** (4 explizit
benannte Volumes plus `/home/webadmin/portal`, `/home/webadmin/websites`,
`/opt/stacks`, `portainer_data/_data/compose`); `dev-vm_*` steht als
„Dev-Sandbox“ in der Ausschluss-Liste, `/srv` in keiner Quelle. Die 100-GB-Datei
wird also **bewusst nicht** gesichert — richtig so. Wer das Skript anfasst, darf
die Allowlist **nicht** auf „alles unter /var/lib/docker“ umbauen.

## 15. Tailscale im Userspace-Modus — sechs Regeln

`code-dev` ist ueber die Tailnet-IP erreichbar, damit lokal gestartete
Dev-Server (`pnpm dev`, `next dev`, `vite`) von Mac, PC und Handy aus sichtbar
sind. Vollstaendige Begruendung: [`TAILSCALE-PLAN.md`](TAILSCALE-PLAN.md).

1. **Userspace-Modus, kein TUN.** `tailscaled --tun=userspace-networking`.
   Das braucht **kein** `/dev/net/tun` und **keine** Capabilities. Taucht bei
   `code-dev` `cap_add: NET_ADMIN` oder `devices: /dev/net/tun` auf, ist die
   Begruendung "fuer Tailscale noetig" falsch — dann laeuft der TUN-Modus und
   die Isolation aus §3/§4 ist nicht mehr die von heute.
2. **`--accept-dns=false` ist Pflicht.** Ohne das Flag schreibt `tailscaled`
   `/etc/resolv.conf` um und Docker-DNS (`127.0.0.11`) faellt im **ganzen**
   Container aus — OpenCode loest dann keine Provider mehr auf. MagicDNS laeuft
   clientseitig, die Namensaufloesung auf dem Client funktioniert trotzdem.
3. **State liegt im Named Volume `tailscale-state`**, gemountet auf
   `/home/dev/.local/share/tailscale`. Ohne dieses Volume waere die 100.x-Adresse
   nach jedem Recreate eine neue (siehe §8). Der Pfad steht deshalb auch in der
   Chown-Liste des Entrypoints.
4. **`TS_AUTHKEY` nur aus `.env.production`,** nie ins Image, nie ins Repo. Und
   **nicht ephemer**: der Node soll seine Tailnet-IP dauerhaft behalten. Leer =
   der Stack laeuft ohne Tailnet, alles wie bisher.
5. **Ein Tailscale-Problem darf `opencode serve` nie blockieren.** Die Funktion
   gibt in jedem Fehlerfall `return 0` und loggt eine Warnung. Der Weg ist
   additiv, keine Voraussetzung fuer den Betrieb.
6. **`forward_auth` bleibt unangetastet.** Der Tailnet-Weg umgeht Caddy
   komplett; er ist ein **Zusaetzlich**-Eingang, kein Ersatz. Wer die
   Cookie-Kette entfernt, macht `remote-code.<domain>` ungeschuetzt — die
   injizierte `header_up Authorization` ist kein Ersatz fuer ein Gate. Ebenso
   §11 unveraendert lassen. Verworfene Alternative („Domain selbst als
   Tailscale-Endpunkt"): `TAILSCALE-PLAN.md` Abschnitt 6.

Sichtbar ueber den Tailnet-Weg ist jeder Port, auf dem in **`code-dev` selbst**
etwas lauscht (der Userspace-Netzstack leitet auf das Loopback *dieses*
Containers weiter). Nicht sichtbar: `dind` und seine Testcontainer sowie
`code-auth-remote:8081` — andere Netzraeume, siehe §7. Wer von aussen auf eine
DB im DinD will, braucht einen Forwarder **in** `code-dev`, nicht `extra_hosts`.

## 16. Git-Identitaet kommt aus dem Image, nicht aus `~/.gitconfig`

`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` /
`GIT_COMMITTER_EMAIL` stehen als `ENV` im `Dockerfile`; der Entrypoint schreibt
dieselben Werte zusaetzlich per `git config --global`. `/home/dev` ist selbst
**kein** Mount (nur die sechs Unterverzeichnisse sind Volumes), eine
`~/.gitconfig` waere also nach jedem Stack-Recreate weg.

- **`GIT_AUTHOR_*` schlaegt jede `user.name`/`user.email` aus `.git/config`.**
  Wer fuer EINEN Commit einen anderen Autor will, braucht
  `env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL git commit ...` — ein
  `git config user.name` im Repo genuegt nicht. Wer dauerhaft umstellt, setzt
  die Variablen im Stack-Env.
- **`git push` ohne Prompt:** `gh auth setup-git` schreibt seinen
  Credential-Helper nach `~/.gitconfig`, das keinen Recreate ueberlebt. Der
  Entrypoint setzt den Helper deshalb bei jedem Start neu. Wer das entfernt,
  muss nach jedem Recreate `gh auth setup-git` von Hand laufen lassen.
- **`/tmp/opencode`** wird `root:root 755` angelegt; das Image setzt `mkdir -p
  /tmp/opencode && chmod 1777 /tmp/opencode` (wie `/tmp` mit Sticky Bit), damit
  uid 1000 schreiben kann. Nicht entfernen; im laufenden Container laesst sich
  das einmalig mit `sudo chmod 1777 /tmp/opencode` nachziehen.

## 17. Die Portainer-DB ist eine Quelle der Wahrheit — und die haesslichste

Die Datei `/var/lib/docker/volumes/portainer_data/_data/portainer.db` (BoltDB)
enthaelt **alle** Stacks. Wer hier etwas aendert, beruehrt sie.

1. **Bucket-Keys sind 8 Byte Big-Endian, kein ASCII.** `dev-vm` (ID 49) liegt
   unter `00 00 00 00 00 00 00 31`. Wer `Get([]byte("49"))` benutzt, bekommt
   **nichts** — immer iterieren und im JSON nach `Name` suchen.
2. **Fuer Compose-Stacks existiert KEIN `FileContent`.** Die Compose-Datei liegt
   **nur** auf der Platte (`ProjectPath=/data/compose/<id>`). Wer im Editor
   `Save` klickt, ohne vorher die Datei aus dem Repo-HEAD einzufuegen, deployt
   einen **leeren** Stack.
3. **Portainer sperrt die DB exklusiv** — auch read-only. Zum Lesen: Portainer
   kurz stoppen, Kopie nehmen, wieder starten. **Und:** `Timeout` in bbolt
   **blockiert**, es bricht nicht ab; nur ein `db.Close()` vor der naechsten
   `Open` hilft.
4. **Der Patch, wenn ein SSH-Deploy neue Env-Keys mitbringt** (§9 Fall 1):

   ```sh
   D=/var/lib/docker/volumes/portainer_data/_data
   cp -a "$D/portainer.db" "$D/portainer.db.bak-$(date +%Y%m%d-%H%M%S)"  # VOR dem Stop
   docker stop portainer
   cp -a "$D/portainer.db" "$D/portainer.db.bak-$(date +%Y%m%d-%H%M%S)"  # AKTUELLER Stand
   # Schreib-Container als root auf dem Volume; kein Go auf Mac und VPS
   docker run --rm -v "$D:/data" -v /w:/w -w /w golang:1.24-alpine \
     sh -c 'go mod init p >/dev/null 2>&1; go get go.etcd.io/bbolt@v1.4.0 && go run . /data/portainer.db dev-vm KEY=WERT'
   docker start portainer
   ```

   **Das `go mod init` ist Pflicht, nicht Kosmetik:** in `golang:1.24-alpine`
   bricht `go get` ohne Modul ab mit *"'go get' is no longer supported outside a
   module"*. Der zweite Backup ist nicht ueberfluessig: Portainer schreibt im
   `SnapshotInterval` (5 min), ein Patch auf einem aelteren Stand rolled seine
   letzten Writes zurueck.
5. **Zwei Regeln, die den Patch gefaehrlich machen, wenn man sie nicht kennt:**
   - **Nur ein Feld anfassen.** Den Datensatz als
     `map[string]json.RawMessage` lesen und **ausschliesslich** den Schluessel
     `Env` ersetzen. Ein Unmarshal/Marshal-Roundtrip ueber ein Struct kann Felder
     umsortieren oder weglassen.
   - **Vorher/nachher fingerabdrucken.** Ueber **alle** Keys aller uebrigen
     Buckets einen SHA256 bauen und vergleichen; bei Abweichung abbrechen.
6. **Werkzeug:** es gibt auf keinem der beiden Rechner Go. `bbolt` als
   Wegwerf-Container ist der Weg; `strings` findet zwar Klartext, taugt aber
   nicht zum Schreiben.
7. **Was der Patch behebt und was nicht:** die **Env** ist danach persistent.
   Die **Compose-Datei** ist es nicht — sie steht nicht in der DB (Punkt 2).
   Nach einem UI-Deploy muss `remote/docker-compose.yml` aus dem HEAD trotzdem
   eingefuegt werden.

## 18. Ein dokumentierter Env-Key ohne Mapping ist kein Container-Env

`stack.env` (und jede andere Stack-Env-Quelle) liefert **nur
Interpolationswerte** fuer `${VAR}` in der Compose-Datei. Es erzeugt **kein**
Container-Env. Eine Variable sieht der Container nur, wenn sie im
`environment:`-Block des Service **explizit gemappt** ist.

- **Wer eine Env oben in der Datei dokumentiert, mappt sie im selben Commit.**
- Fuer jede neue Zeile im `environment:`-Block gilt: **leer muss harmlos
  bleiben.** Ein verhaltensaendernder Fallback gehoert in `entrypoint.sh`, nicht
  in die Compose-Datei — in der Compose-Datei darf nichts stehen, das Zugriff
  oeffnet. Fuer `CORS_ORIGIN` heisst das: Mapping ohne `:-`, leer bleibt leer.
- Die bestehenden `:-`-Defaults in der Datei bleiben unberuehrt.
- `CORS_ORIGIN` traegt **ausschliesslich** die eigene PWA-Origin
  `https://ocweb.all-the.rest` — keine fremden Origins, keine Sammel- oder
  Wildcard-Liste.

## 19. OPTIONS wird vor `forward_auth` beantwortet — Blanket, mit benannten Grenzen

Gilt fuer **beide** Sites (`code` **und** `remote-code`). Vor dem
Catch-all-`handle` steht ein `@options method OPTIONS`-Block mit statischem 204
und den `Access-Control-Allow-*`-Headern.

Warum: ein Preflight traegt per Spezifikation nie Cookies; `forward_auth` sieht
damit keinen `auth`-Cookie, antwortet 401, `handle_response @denied` macht daraus
`redir * /login.html 302` — und der Browser bricht den Preflight ab. Der Block
ist die einzige Stelle, an der die Origin ohne Cookie durchgelassen werden kann.
**ACAO an echten Responses soll** separat aus `opencode serve --cors` kommen
(§18 / `local/run.sh`).

**Grenzen — beide sind gewollt und keine Bugs:**

1. **Die pfadspezifischen Handles stehen davor** (`/login.html`, `/api/login`,
   `/api/me`, `/api/logout`, `/sw.js`) — als Quellreihenfolge, nicht als Absicht;
   ihr OPTIONS trifft diesen Block **nie**. Wer die Reihenfolge nicht von der
   Quelle abhaengig haben will, muss `route`-Bloecke oder `handle`-Reihenfolge
   bewusst setzen. Was ein solches OPTIONS bekommt, ist pro Route verschieden und
   **ohne** CORS-Header: `/api/login`, `/api/me`, `/api/logout` -> der Sidecar
   antwortet `501 Unsupported method`; `/sw.js` -> `respond` dieses Blocks,
   200; `/login.html` -> `file_server`. Heute harmlos (Login same-origin).
   **Latente Falle:** wird das Login cross-origin, sind genau die drei API-Routen
   betroffen und brauchen ein eigenes `OPTIONS`-Handling.
2. **Der Blanket-OPTIONS umgeht `forward_auth` fuer alle uebrigen Pfade.**
   Unkritisch: die Antwort ist statisch, bodyless und origin-gebunden (kein `*`),
   der Upstream sieht die Anfrage nie. **Aber** kuenftige Endpunkte, die selbst
   auf OPTIONS antworten sollen (WebDAV-Discovery o.ae.), werden hier maskiert.
   Wer `PROPFIND`/`OPTIONS`-Semantik braucht, muss den Matcher verengern
   (`@options { method OPTIONS; not path /dav* }`), statt blind zu erweitern.

Offene Punkte: `agents.todo.md`.

## 20. Hugging Face: Token kommt als `HF_TOKEN`, nicht per `hf auth login`

`hf` liest den Token aus der Env. `hf auth login` **haelt nicht**: `~/.cache` ist
**kein** Volume (§16), der Token landet in `/home/dev/.cache/huggingface/token`
und ist beim naechsten Recreate weg. Deshalb **drei** Stellen, nicht eine:

1. **`HF_TOKEN` im `environment:`-Block** von `code-dev` (ohne `:-`, leer bleibt
   leer — §18). Der Wert kommt aus der Stack-Env.
2. **`HF_TOKEN` in `.env.production`** — Paste-Vorlage fuer die Portainer-UI,
   gitignored, Klartext. Kein `$$`-Escaping noetig, der Token hat kein `$`.
3. **`huggingface_hub[cli]` im Image** (Dockerfile, per
   `pip --break-system-packages` ins System-Python, nicht pipx) — sonst ist `hf`
   nach jedem Recreate weg.

`huggingface_hub` liest `HF_TOKEN` aus der Env **vor** jedem gespeicherten Token
— ein `hf auth login` ist damit weder noetig noch sinnvoll. `transformers` und
`diffusers` sehen die Variable ebenfalls.

### Live-Hotfix ohne Neustart

Wer im **laufenden** Container arbeitet, liegt nur im Writable-Layer und
ueberlebt keinen Recreate:

```sh
docker exec code-dev bash -lc 'sudo python3 -m pip install \
  --break-system-packages --no-cache-dir "huggingface_hub[cli]"'
```

**`hf auth login` interaktiv im `docker exec` haengt** — nicht verwenden.
Nicht-interaktiv schreibt man den Token per stdin direkt in die Token-Datei
(0600), damit er nie in der Prozessliste steht:

```sh
# lokal, Token nie in einer Prozessliste:
printf '%s' "$HF_TOKEN" | ssh root@reisinger.pictures \
  'docker exec -i code-dev bash -lc "umask 077 \
     && cat > /home/dev/.cache/huggingface/token \
     && chmod 600 /home/dev/.cache/huggingface/token"'
ssh root@reisinger.pictures 'docker exec code-dev hf auth whoami'
```

CLI-Syntax in 2.x: `hf auth login` / `hf auth whoami` / `hf download`; das alte
`huggingface-cli login` gibt es nicht mehr.

Offene Punkte: `agents.todo.md`.
