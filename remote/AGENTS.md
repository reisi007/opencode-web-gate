# AGENTS.md — Regeln fuer `remote/` (VPS-Weg)

Beschreibung und Messwerte stehen in [`README.md`](README.md) (485 Zeilen, u. a.
*Warum es kein `extra_hosts` gibt*, *`dind` ist rootless*, *RAM- und Swap-Limits*).
Hier nur die Regeln, die beim Aendern von `docker-compose.yml` / `entrypoint.sh` /
`.env.production` schon einmal eine Fehlermeldung oder ein Sicherheitsloch
erzeugt haben. Allgemeine Auth-Regeln: [`../AGENTS.md`](../AGENTS.md).

## 1. Deploy: Portainer-UI ist der Normalfall, SSH ist der dokumentierte Ausweg

`docker-compose.yml` wird in den Web-Editor gepastet, `.env.production` als
Stack Environment. Ein File, kein Upload. Nach jeder Aenderung: Stack in
Portainer neu deployen — eine Datei im Repo aendert auf dem VPS **nichts**.

`.env.production` ist gitignored und trotzdem die einzige Quelle fuer den
laufenden Stack. `setup.sh` schreibt sie **nicht** (nur `.env`). Jede Zeile muss
`KEY=WERT` ergeben, wenn sie eingefuegt wird.

### Der SSH-Weg (am 2026-09-29 erstmals bewusst genutzt, Entscheidung des Menschen)

```sh
cd /var/lib/docker/volumes/portainer_data/_data/compose/49   # Stack dev-vm
docker compose --env-file stack.env -p dev-vm up -d --no-deps code-dev
```

**Immer `--no-deps` und immer nur den einen Service, der sich wirklich
geaendert hat.** Grund ist §2, nicht Bequemlichkeit: `docker compose
--env-file` escaped `$$` **nicht**. Ein volles `up -d` recreated auch
`code-auth-remote`, und der bekommt dann `$$2a$$14$$…` statt `$2a$14$…` —
`ensure_bcrypt()` prueft auf `$2` und der Sidecar startet nicht. Am
2026-09-29 gemessen: der Diff enthielt genau **vier** inhaltliche Zeilen, alle
in `code-dev`; mit `--no-deps` blieb `code-auth-remote` auf `Started 27.09.`,
beide Sidecars weiter `$2a$14$…`. **Vorher den Diff ansehen, dann entscheiden,
welche Services betroffen sind** — nicht pauschal `up -d`.

### Was ein SSH-Deploy NICHT pflegt: die Portainer-DB

Portainer haelt die Stack-Env in seiner Datenbank und schreibt `stack.env` bei
jedem **UI**-Deploy daraus neu. Ein per SSH deployter Stack laeuft also korrekt,
verliert aber neue Env-Keys beim naechsten Browser-Klick. Siehe §17 fuer den
Patchweg und fuer die Falle, dass die Compose-Datei gar nicht in der DB steht.

## 2. `AUTH_HASH` gehoert als `$$2a$14$…` in `.env.production`

Portainer interpolated den Env-Wert, bevor er den Container erreicht; der
Sidecar bekommt also `$2a$14$…`. `AUTH_HASH` ist der einzige betroffene Wert
(die anderen enthalten kein `$`).

**Nicht "aufraeumen".** `docker compose --env-file` escaped `$$` *nicht* — wer
lokal testet, sieht den Wert doppelt escaped und macht ihn unescaped, womit der
Login auf `remote-code` kaputt ist (Container-Start bricht ab mit
`AUTH_HASH-Format unsupported`, weil `ensure_bcrypt()` auf `$2` prueft).
Im Zweifel `docker inspect code-auth-remote` gegenpruefen, nicht lokal composen.

## 3. Niemals `extra_hosts` / `host-gateway` zuruecknehmen

War entfernt am 2026-09-26, weil die Begründung falsch war: `extra_hosts`
repariert `127.0.0.1` nicht, es **ergaenzt nur einen Namen fuer eine Host-IP**.
Es hat keine Tuer zum localhost geoeffnet, sondern eine zum ganzen VPS —
Portainer-UI auf `8000` unverschluesselt, Portainer-API auf `9443`, Caddy auf
80/443. Live verifiziert, dann entfernt.

`127.0.0.1` in `code-dev` **ist** der Container, und das ist richtig so: ein
Dev-Server (`pnpm dev`) laeuft direkt in `code-dev` und ist ueber `127.0.0.1`
sofort erreichbar. Die eigentliche Loesung fuer "localhost laesst sich im
Container nicht nutzen" war nie Docker, sondern: **Dev-Server nach `code-dev`,
Wegwerf-Container nach DinD.**

`HOST_GATEWAY` war bis 2026-09-26 in `.env.production` und ist entfernt — der
Stack hatte kein `extra_hosts` mehr, der Key wurde nirgends referenziert
(kein Container auf dem VPS mit dem Eintrag, keine Compose-Datei unter
`/data/compose`, keine `daemon.json`). Nicht wieder aufnehmen.

## 4. `dind` bleibt rootless — `privileged: true` war ein Host-Root

Vorher stand `privileged: true`: das ergab `CapEff 000001ffffffffff` (alle 37
Capabilities) **und** sichtbares `/dev/vda4` — also faktisch Root auf dem Host,
mit `/home/webadmin/websites`, den MariaDB-Volumes, den TLS-Keys, `portainer.db`
und der rclone-Config in Reichweite. `code-dev` hat die Docker-CLI und zeigt per
`DOCKER_HOST` auf diesen Daemon, das war der direkte Weg in die Prod-Daten.

Live verifiziert ist `0000000000000000`, keine Host-Blockdevices,
`SecurityOptions: seccomp, rootless, cgroupns`.

## 5. Die drei `security_opt` sind einzeln noetig

`seccomp=unconfined`, `systempaths=unconfined`, `/dev/net/tun` — jeweils einzeln
getestet, **alle drei zusammen** startet der rootless-Daemon ueberhaupt:

- ohne `seccomp=unconfined` blockt der Default-Seccomp `unshare(CLONE_NEWUSER)`
- ohne `systempaths=unconfined` schlaegt der `/proc`-Mount im nested userns fehl
- ohne `/dev/net/tun` findet rootlesskit kein tap-Device fuer slirp4netns

Wer eines davon als "ueberfluessig" entfernt, killt den Daemon im Restart-Loop.

## 6. Kein Host-Pfad als Data-Root

Der rootless-Daemon nutzt ohne `--data-root` sein Default
`$HOME/.local/share/docker` = `/home/rootless/.local/share/docker` (uid 1000).
Ein Mount auf `/var/lib/docker` ist **wirkungslos** — gemessen: 11,9 MB im
Writable-Layer, 0 Byte im Volume, alles weg bei jedem Recreate. Der richtige
Mount ist `dind-data-rootless:/home/rootless/.local/share/docker`.

## 7. Adressierung im DinD: Name, nie Loopback, nie Host-IP

`docker run -p 127.0.0.1:X:Y` im DinD bindet nur im **DinD-Netzraum** und ist von
`code-dev` aus nie erreichbar. Wegwerf-Testcontainer gehoeren per `--network` in
ein geteiltes Netz und werden per Containername angesprochen (`db:5432`,
`mailpit:8025`). Loopback funktioniert containeruebergreifend nie.

## 8. Volumes sind Named Volumes, kein Docker-Wurzelverzeichnis

`gh-config`, `gh-ssh`, `opencode-data/-config/-state` tragen `gh auth`,
SSH-Keys und den OpenCode-Zustand — sie ueberleben Image-Upgrades. Genau darum
sind es Named Volumes. `gh auth login` ist nach einem Stack-Recreate **nicht**
noetig und soll auch nicht dauernd noetig sein; wenn doch, ist ein Volume
verloren gegangen, nicht das Passwort.

**Ausnahme `/projects`:** das ist seit 2026-09-29 ein Bind-Mount auf
`/srv/dev-projects` (100-GB-Loopback), kein Named Volume. Siehe §14 — dort
steht auch, warum ausgerechnet dieser Pfad *nicht* unter
`/var/lib/docker/volumes` liegen darf.

## 9. RAM- und Swap-Limits: `memswap_limit` ist der **Gesamt**-Deckel

Live aus `/sys/fs/cgroup/…` gelesen:

```
memory.max      = mem_limit                 (RAM-Deckel)
memory.swap.max = memswap_limit - mem_limit (reiner Swap-Deckel)
```

`memswap_limit` setzt man, um das **Verhaeltnis** zu bestimmen — nicht um Swap zu
eroeffnen. Ohne den Wert ist der Swap-Deckel exakt `mem_limit` (vorher stand
4g/4g, und `code-dev` hat nachweislich 385 MB Swap benutzt,
`memory.swap.current`). `memswap_limit` muss groesser als `mem_limit` sein; die
beiden Werte gleich zu setzen ist keine "sichere" Wahl, sondern die
Dokumentation des Fehlers.

**Kein gemeinsames Limit fuer code-dev und dind.** Bei OOM waehlt der Kernel den
GROSSTEN Prozess im cgroup, und das ist der dind-Daemon, nicht der schuldige
Build. Deshalb zwei getrennte Limits: so stirbt ein runaway Build nur
`code-remote-dind` und die `code-dev`-Session laeuft weiter. Die Limits am
dind-Container greifen fuer die inneren Container mit (gleicher cgroup, live
gemessen), Limits an inneren Containern greifen nicht (kein systemd im Container).

**`code-dev` hat kein „harmloses Opfer" — sein groesster Prozess ist PID 1.**
Dieselbe OOM-Logik wie beim DinD, nur dass der Treffer hier `opencode serve` ist
und der laeuft als **PID 1**. PID 1 killen = der Container stirbt =
`restart: unless-stopped` = **die Sitzung ist weg**. Am 2026-09-29 gemessen: 8
OOM-Kills in 24 h, Ausloeser jedes Mal `cargo build` (parallele `rustc`/`rust-lld`
mit 220–920 MB pro Instanz bei 3 Cores). Opfer-Bilanz: 3x rustc, aber **5x
PID 1**. Deshalb war die Erscheinung von aussen „nicht regelmaessig" — sie
hing nur daran, OB gerade Rust kompiliert wurde. Limits deshalb in zwei
Schritten angehoben: 2g/5g → **3g/6g** (gegen die Kills), dann 3g/6g →
**4g/8g** (README, *RAM- und Swap-Limits*).

**Und 3 GB hat nur knapp gereicht.** Nachmessung am 3g-Deckel:
`memory.peak` auf der Decel, `memory.current` bei 86 % — aber 0 OOM-Kills.
Damit war 3 GB zu niedrig, weil `rustc`/`rust-lld` **anon**-Speicher
brauchen und der nicht reclaimbar ist. Wer einen RAM-Deckel als „fixiert"
abhakt, muss also `anon` prüfen — nicht die Kill-Zahl und nicht
`memory.peak`. Beide sind irrefuehrend, siehe den naechsten Abschnitt.

**Und 3 GB hat nur knapp gereicht.** Nachmessung am 3g-Deckel:
`memory.peak` auf der Decel, `memory.current` bei 86 % — aber 0 OOM-Kills.
Damit war 3 GB zu niedrig, weil `rustc`/`rust-lld` anon-Speicher brauchen und
der nicht reclaimbar ist. Auf **4 GB** ist derselbe Lastfall entspannt.

### Der RAM-Deckel wird an `anon` gemessen, nicht an `memory.current`

**Die wichtigste Korrektur an dieser ganzen Analyse.** `memory.current`
enthält den **reclaimbaren File-Cache** — bei einem Playwright- oder
Vite-Lauf füllt der das Deckel fast voll, ohne dass irgendwo ein echtes
Speicherproblem existiert. Live gemessen am 2026-09-29, 16:36, bei 95 %
`memory.current`:

| | MB | Anteil am 4-GB-Deckel |
|---|---|---|
| reclaimbarer File-Cache (`file`) | 2821 | 69 % |
| **anon (echter Prozess-Speicher)** | **929** | **23 %** |
| `slab_unreclaimable` | 5 | — |
| `pagetables` + `shmem` + `slab_reclaimable` | 45 | 1 % |

**OOM-relevant sind nur `anon` + `slab_unreclaimable` — hier 934 MB von 4096 MB,
23 %.** Für echte Allokation waren noch 3,1 GB frei. Der Kernel hat den Cache
recycled statt zu killen, `oom_kill 0` war also das richtige Ergebnis.

Daraus die Regeln, die beim Korrigieren teuer wurden:

- **`memory.current` hoch heisst nichts.** Nach jedem Vite-, Playwright- oder
  `cargo`-Lauf ist es nahe an voll, weil Cache aus `node_modules` und
  Target-Verzeichnissen liegt. Wer daraus „der Deckel ist zu klein" ableitet,
  hebt Limits an, die nicht das Problem sind.
- **`memory.peak` über `memory.max` ist KEIN Alarm**, solange `anon` niedrig
  war. `peak` zählt Cache mit. Ein OOM entsteht nur, wenn `anon` die Decel
  erreicht. **Die erste Fassung dieser Notiz behauptete das Gegenteil** und
  wurde am selben Abend durch eine Fehlalarm-Meldung widerlegt: 95 %
  `memory.current` gemeldet, obwohl nur 23 % nicht-reclaimbar waren.
- **Die echte Frage ist: war `anon` am Limit?** `rustc`/`rust-lld` brauchen
  220–920 MB **anon** pro Instanz, das ist der Grund fuer jeden Kill hier.
  Ein 4-GB-Deckel ist genau dann richtig, wenn parallele Builds zusammen
  unter ~3 GB `anon` bleiben.
- **Messen so:**
  ```sh
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
  grep -E '^(anon|file|slab_unreclaimable) ' $CG/memory.stat
  grep -E 'oom_kill' $CG/memory.events
  ```

**Die 4 GB machen den Host zur knappsten Stelle im ganzen Setup.**
code-dev 4g + dind 2,5g + Portal ~0,5g + OS ~0,7g = ~7,7 GB bei 7,5 GB. Erreichen
beide Dev-Container ihre Deckeln gleichzeitig — Normalfall, weil der Agent in
`code-dev` per cargo baut und parallel im Daemon per docker baut —, feuert der
**Host**-OOM-Killer, und der nimmt global den größten Prozess: `mariadbd`.
Ein Dev-Build wäre dann ein Produktionsausfall. Am 2026-09-29 bewusst so
entschieden (Entscheidung des Menschen), ohne dind zu senken. **Merksatz: die
RAM-Limits dieses Stacks summieren sich gegen einen Host, der zugleich
Produktion fährt.** Wer hier nächstes Mal „nur ein bisschen mehr" sagt, muss die
Summe gegenrechnen, nicht den einzelnen Container.

Merksatz fuer die naechste Anpassung: **`code-dev` ist interaktiv, also darf hier
nichts den PID-1-Pfad ausloesen.** Ein Weg, den jemand „zur Haushalts-
optimierung" vorschlaegt und der erst beim naechsten `cargo build` auffaellt.

### Der Swap-Deckel funktioniert — eine falsche Diagnose ist hier korrigiert

**Bis 2026-09-30 stand hier, der Swap-Deckel sei Dekoration, weil
`vm.swappiness=0` sei. Das war falsch, und der Fehler war eine Verwechslung.**

`vm.swappiness` ist **10** (persistiert in `/etc/sysctl.conf`, mtime April,
also seit langem). Was tatsaechlich `0` war: `vm.overcommit_memory` — ein
voellig anderes Sysctl, das ich beim Messen im falschen Achsenfalsch
mitgelesen und dann als swappiness ausgegeben habe. Die Beobachtung selbst
war echt (`memory.swap.current` stand bei 0, waehrend der OOM-Killer feuerte),
die Erklaerung darum war es nicht: es war schlicht **kein Swap noetig** in
diesem Moment, nicht **Swap unmoeglich**.

Live gegengeprueft am 2026-09-30: `memory.swap.current` im Container = **597 MB
von 4096 MB** genutzt. Der Swap-Deckel greift also ganz normal.

Konsequenz fuer die Groessenordnung: `memswap_limit` ist kein Dekor, sondern
echte Reserve. Wer `code-dev` von 4 GB auf 5 GB RAM hebt, tut das gegen **9 GB
Gesamtbudget**, nicht gegen 4 GB. Und umgekehrt — die 4 GB haben `opencode` als
PID 1 am 2026-09-30 um 08:46 trotz 4 GB **plus** 4 GB Swap getoetet. Das ist
kein Swap-Problem, das ist anon-Druck aus der Rust-Toolchain plus Chrome.

**Merksatz fuer Messungen auf diesem Stack: `vm.overcommit_memory` und
`vm.swappiness` sind zwei verschiedene Sysctls.** Bei RAM-Diagnosen immer das
vorherige Kommando mitlesen, sonst wird die naechste Massnahme auf einer
Verwechslung gebaut.

### Zwei Faelle, in denen die DB gepatcht wird — und wann NICHT

Nach dem Schema in §17.4 wird die DB in zwei Faellen angefasst:

1. **Neuer Env-Key, der per SSH-Deploy kam.** Der Stack laeuft korrekt, aber
   Portainer kennt den Key nicht und schreibt `stack.env` bei jedem UI-Deploy
   ohne ihn neu. Beispiel 2026-09-29: `TS_AUTHKEY`/`TS_TAILSCALE_HOSTNAME`.
2. **Sichtbarkeit.** Werte, die bisher nur als Compose-Default existierten, in
   die Env heben, damit sie in der UI sichtbar und editierbar sind. Beispiel
   2026-09-30: `MEMORY_LIMIT=5g` und `MEMSWAP_LIMIT=9g`.

**Nicht** patchen, wenn nur ein Compose-Default geaendert wurde: der Default
greift ohnehin, und der Weg durch die DB erzeugt nur eine zweite Quelle der
Wahrheit. Der Nachteil von Fall 2 ist genau das — ab jetzt schlaegt der
DB-Wert der Datei, still. Wer `mem_limit` in der Datei auf 6g aendert, waehrend
die DB 5g sagt, deployt 5g und glaubt, es stimme.

**Der vierte Schritt wird oft vergessen: `.env.production` mitziehen.** Die
Datei ist die Paste-Vorlage fuer die UI (§1). Stehen die Keys nur in der DB
und nicht in der Datei, loescht der naechste Paste sie wieder. Bei Fall 2 am
2026-09-30 mitgemacht, sonst waere der Patch nach einem UI-Paste stillschweigend
weg gewesen.

Geprueft wurde am 2026-09-30 ausserdem Punkt 2 noch einmal: `FileContent`
existiert im dev-vm-Record **nicht**, `ProjectPath` ist `/data/compose/49` — und
`/data` ist im Portainer-Container genau das `portainer_data`-Volume. Der
Web-Editor laedt also die Datei, die auf der Platte liegt. Ein UI-Recreate
sieht die aktuelle Compose-Datei, nicht einen Stand aus der DB.

### Akute OOM-Lage ohne Recreate entschaerfen

`memory.max` ist im laufenden cgroup schreibbar. Fuer eine akute Lage, in der
gerade gearbeitet wird, ist das der einzige Weg, der niemanden bricht:

```sh
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' code-dev).scope
echo 4294967296 > "$CG/memory.max"   # 4 GiB
```

**Nur eine Bruecke, und sie ist obendrein fehleranfaellig** (2026-09-29
gemessen): bei jedem `docker restart` wendet Docker die `HostConfig`-Limits
erneut an und überschreibt den Direktwert. Im Test haben **drei Restarts**
innerhalb von 90 Minuten das geschriebene Limit zurückgesetzt — auf den Wert
der Compose-Datei von Erstellungszeit. Der OOM-Killer feuerte deshalb weiter,
während `memory.max` korrekt aussah. **Ein direkt geschriebenes `memory.max`
gilt bis zum nächsten *Restart*, nicht bis zum nächsten Recreate.** Wer das
als Fix verbucht, hält sich für behoben, wo nichts behoben ist: die
Compose-Datei ist der einzige Ort, der dauerhaft wirkt.

## 10. Autoupdate: SIGTERM an PID 1 ist der Mechanismus

`entrypoint.sh` startet den Watcher, der bei neuem Binary **idle** per
`kill -TERM 1` den Container beendet, worauf `restart: unless-stopped` frisch
mit dem neuen Binary startet. `server_idle` fragt `/api/session/active` mit
Basic-Auth (`opencode` + Serverpasswort) ab und **vertagt bei aktiver Session**.
Das ist Absicht: ein Update darf keinen laufenden Run abbrechen. `idle` nicht
auf `always` umstellen, um "Deploy-Beschleunigung" zu gewinnen.

`OPENCODE_DISABLE_AUTOUPDATE=true` im Image verhindert nur den *In-Process*-
Autoupdate des Servers, nicht diesen Block.

## 11. Auth-Checks im Caddy-Fragment nicht vereinfachen

- `health_headers { Authorization … }` **muss** bleiben: ohne ihn ist
  `/api/info` 401 und der Healthcheck meldet dauerhaft unhealthy (das war ein
  Bug, siehe Commit `8b30173`).
- `stream_timeout 24h` + `stream_close_delay 5m` gelten fuer WebSocket-Upgrades
  (insbesondere PTY), **nicht** fuer SSE. Kein globales `flush_interval -1`.
- Upstream auf HTTP/1.1 mit `keepalive 4s`: OpenCode antwortet mit
  `Keep-Alive: timeout=5`, Cadys 2h-Default wuerde abgelaufene Sockets
  wiederverwenden (502/WS-Resets).
- `__REMOTE_DOMAIN__` / `__CODE_SITE__` / `__OPENCODE_BASIC__` sind Platzhalter
  und werden von Hand in die **globale** Caddyfile uebernommen. Der
  `__OPENCODE_BASIC__`-Wert gehoert nie ins Repo. Voraussetzung: der `caddy`-
  Service haengt an `webnet` **und** `code-remote`, beide `external: true`.

## 12. `AUTH_HASH` ist bcrypt oder PBKDF2 — kein Klartext-Fallback

Beide Sidecars failen closed: unbekanntes Format -> `SystemExit`, bcrypt-Hash
ohne Modul -> refuses to start. Das ist gewollt. Kein "Fallback auf
Klartext-Vergleich" einbauen, um einen Start zu erzwingen — der Fehler soll an
der Ursache sichtbar sein.

## 13. Nicht verwechseln: `AUTH_HASH` ist nicht `OPENCODE_PASSWORD`

`AUTH_HASH` = Login-Seite (Cookie-Gate, bcrypt, `AUTH_USER`).
`OPENCODE_PASSWORD` = `opencode serve`-Serverpasswort, das Caddy per
`header_up Authorization` injiziert. Sie duerfen pro Weg verschieden sein, der
Login der Login-Seite hat damit nichts zu tun. Ein 401 auf `/api/login` ist ein
`AUTH_HASH`-Problem, ein 401 auf `/api/info` ein Basic-Problem. Diagnosebefehle
stehen in [`../AGENTS.md`](../AGENTS.md) Abschnitt 5.

## 14. `/projects` liegt auf einem 100-GB-Loopback — die sieben Regeln

Seit 2026-09-29 haengt `/projects` an `/srv/dev-projects`, einem 100-GB-Loopback
mit ext4. Der alte 50-GB-Versuch wurde am 2026-09-27 mit `c5d3c7b` **verworfen**
und am 2026-09-29 mit 100 GB bewusst wieder aufgegriffen. Messwerte und
Performance: [`README.md`](README.md), Abschnitt „100-GB-Loopback fuer
`/projects`“.

**Wer hier etwas aendert, ohne die Regeln zu kennen, macht den Dev-Container
leer.** Deshalb einzeln:

1. **`fstab`-Quelle ist die DATEI, nicht die UUID.** Die UUID haengt am
   Loop-Device, das erst durch `losetup` entsteht — `mount -a` hat sie zum
   Boot-Zeitpunkt also gar nicht. Mit UUID als Quelle getestet:
   `failed to setup loop device for /dev/loop0`. Korrekt ist
   `/srv/dev-100g.img /srv/dev-projects ext4 loop,defaults,noatime 0 2`.
   Nebenstelle: der Dateipfad ist zugleich stabiler als jede UUID-Variante,
   weil `/dev/loopN` pro Boot neu nummeriert wird.
2. **`loop` in den Mount-Options ist Pflicht.** Ohne die Option setzt `mount`
   beim Boot kein Loop-Device auf. Das ist kein „kosmetischer“ Eintrag.
3. **Der Pfad muss in `fstab` und `docker-compose.yml` identisch sein.** Im
   Compose steht `- /srv/dev-projects:/projects` **zweimal** — bei `code-dev`
   und bei `dind`. Nur einer von beiden aendern laesst die Dateien auseinander
   laufen; `code-dev` sieht dann einen anderen Bestand als der DinD-Daemon.
4. **ext4, nicht XFS.** Nur ext4 hat `resize_inode` und kann damit
   `resize2fs` nach unten. XFS kann ausschliesslich wachsen — das ist der
   Grund, warum der Weg ueber eine zweite Platte die einzige Alternative mit
   echtem Platz waere und ein Loop ueberhaupt noetig macht (XFS auf der
   bestehenden `vda4` laesst sich nicht schrumpfen, die Partition ist die
   letzte der GPT-Tabelle und haelt das Root-FS).
5. **Bind-Mount auf `/srv`, niemals auf einen Pfad unter
   `/var/lib/docker/volumes`.** Docker kann einen Volume-Pfad als verwaist
   einstufen und wegrationalisieren; `/srv/dev-projects` ist fuer ihn ein
   ganz normaler Host-Pfad. Deshalb heisst §8 fuer `/projects` „Ausnahme“.
6. **Der Mountpoint muss `1000:1000` sein.** `code-dev` laeuft als uid 1000
   (`dev`). Ein root-owned Mountpoint mit `755` laesst den Agenten zwar
   lesen, aber nicht schreiben — und das faellt erst beim ersten Schreibversuch
   auf. Beim Anlegen des Mountpoints explizit setzen.
7. **Single Point of Failure, siehe unten.** Der Loop ist die *einzige* Kopie
   der Projekte. Faellt der Mount beim Boot aus, startet `code-dev` mit leerem
   `/projects` — und `gh repo clone` holt nur den Code zurueck, nicht
   `node_modules`, `.env`-Fragmente oder uncommittete Arbeit.

### Was der Weg gekauft hat — und was nicht

Er hat **keinen Platz gespart, sondern einen Deckel.** Vorher 61 GB belegt,
nachher 65 GB: die Daten liegen jetzt auf ext4 statt XFS, und ext4 belegt
etwa 2 GB mehr (XFS packt File-Tails ueber Extents). Dafuehr gibt es jetzt
97,87 GiB nutzbare Kapazitaet, die `rm -rf` nicht sprengen kann. Die Zahl
100 ist die **Loop-Groesse**, nicht der nutzbare Platz — ext4 rechnet Journal
und Inode-Tabellen ab.

### Der Boot-Schutz, der noch fehlt

Regel 7 ist real und derzeit **nicht abgesichert**. Es gibt keinen Check, der
einen ausgefallenen Mount erkennt, bevor der Agent mit leerem `/projects`
arbeitet. Naheliegend waere eine Pruefung in `bootstrap.sh` oder ein
systemd-`ExecStartPre` auf `code-dev` auf `findmnt /srv/dev-projects`. **Nicht
erfunden und nicht als erledigt fuehren.**

### Nicht ins pCloud-Backup

Absichtlich, und es muss auch so bleiben: `/usr/local/bin/volume-backup.sh`
arbeitet mit einer **Allowlist** (4 explizit benannte Volumes plus
`/home/webadmin/portal`, `/home/webadmin/websites`, `/opt/stacks`,
`portainer_data/_data/compose`). `dev-vm_*` steht dort explizit als
„Dev-Sandboxen, ~115 GB Muell“ in der Auschluss-Liste. `/srv` ist in keiner
Quelle enthalten, die 100-GB-Datei wird also **nicht** gesichert — richtig so,
sonst frisst sie das pCloud-Konto. Wer das Skript anfasst, darf die
Allowlist **nicht** auf „alles unter /var/lib/docker“ umbauen.

## 15. Tailscale im Userspace-Modus — sechs Regeln

`code-dev` ist ueber die Tailnet-IP erreichbar, damit lokal gestartete
Dev-Server (`pnpm dev`, `next dev`, `vite`) von Mac, PC und Handy aus sichtbar
sind. Vollstaendige Begruendung: [`TAILSCALE-PLAN.md`](TAILSCALE-PLAN.md).
Live noch nicht verifiziert — siehe `agents.todo.md`.

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
   Chown-Liste des Entrypoints — sonst waere das frisch gemountete Volume
   root-gehoert und `tailscaled` kaeme als uid 1000 nicht hinein.
4. **`TS_AUTHKEY` nur aus `.env.production`,** nie ins Image, nie ins Repo. Und
   **nicht ephemer**: der Node soll seine Tailnet-IP dauerhaft behalten, sonst
   verschwindet er nach jedem Disconnect aus der Admin-Console. Leer = der Stack
   laeuft ohne Tailnet, alles wie bisher.
5. **Ein Tailscale-Problem darf `opencode serve` nie blockieren.** Die Funktion
   gibt in jedem Fehlerfall `return 0` und loggt eine Warnung. Der Weg ist
   additiv, kein Voraussetzung fuer den Betrieb.
6. **`forward_auth` bleibt unangetastet.** Der Tailnet-Weg umgeht Caddy
   komplett; er ist ein **Zusaetzlich**-Eingang, kein Ersatz. Wer die
   Cookie-Kette entfernt, macht `remote-code.<domain>` ungeschuetzt — die
   injizierte `header_up Authorization` ist kein Ersatz fuer ein Gate, weil der
   Browser das Passwort nie zu sehen bekommt. Ebenso §11 unveraendert lassen.
   Begruendung und die verworfene Alternative („Domain selbst als Tailscale-
   Endpunkt"): `TAILSCALE-PLAN.md` Abschnitt 6.

### Was der Tailnet-Weg sichtbar macht — und was nicht

Sichtbar: jeder Port, auf dem in **`code-dev` selbst** etwas lauscht. Der
Userspace-Netzstack leitet auf das Loopback *dieses* Containers weiter.

Nicht sichtbar: `dind` und seine Testcontainer (`db:5432`, `mailpit:8025`) sowie
`code-auth-remote:8081` — andere Netzraeume, siehe §7. Wer von aussen auf eine
DB im DinD will, braucht einen Forwarder **in** `code-dev`, nicht `extra_hosts`.

## 16. Git-Identitaet kommt aus dem Image, nicht aus `~/.gitconfig`

`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_NAME` /
`GIT_COMMITTER_EMAIL` stehen als `ENV` im `Dockerfile`; der Entrypoint
schreibt dieselben Werte zusaetzlich per `git config --global`.

**Warum nicht `~/.gitconfig` allein:** `/home/dev` ist selbst **kein** Mount
(verifiziert: `mount | grep 'on /home/dev '` liefert nichts, nur die sechs
Unterverzeichnisse sind Volumes). Eine `~/.gitconfig` waere damit nach jedem
Stack-Recreate weg — Git faellt dann auf `user.name` aus dem Repo-Config
zurueck, oder bricht bei einem frischen `git init` ganz ohne Identitaet ab.

**Gemessen (Git 2.x, Wegwerf-Repos mit `HOME` auf leerem Verzeichnis):**

| Konstellation | Ergebnis |
|---|---|
| nur `ENV` | `Florian Reisinger <florian.reisinger.at@gmail.com>` |
| `ENV` + `git config --global` | identisch (beide Wege nennen dieselbe Person) |
| `ENV` + abweichende lokale `user.name` | **`ENV` gewinnt** |

**Konsequenz aus der letzten Zeile:** `GIT_AUTHOR_*` schlaegt jede
`user.name`/`user.email` aus `.git/config`. Wer fuer EINEN Commit einen anderen
Autor will, braucht darum `env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL git
commit ...` — ein `git config user.name` im Repo genuegt nicht. Wer dauerhaft
umstellt, setzt die Variablen im Stack-Env (die schlagen wiederum das Image).

Kein Geheimnis, nur Anzeigename und Mailadresse fuer die Commit-Metadaten.

### Und `git push` ohne Prompt

`gh auth setup-git` schreibt seinen Credential-Helper nach **`~/.gitconfig`**
(verifiziert: `git config --list --show-origin | grep credential` zeigt
`/home/dev/.gitconfig`). Dieselbe Datei ueberlebt keinen Recreate. Live
beobachtet: Nach einem Container-Neustart war der Helper weg und `git push
origin main` brach ab mit

```
fatal: could not read Username for 'https://github.com': No such device or address
```

obwohl `gh auth status` weiterhin gueltig war (Token in `gh-config`, ein
Volume, also persistent). Der Entrypoint setzt den Helper deshalb bei jedem
Start neu. Wer das entfernt, muss nach jedem Recreate `gh auth setup-git`
von Hand laufen lassen, sonst pushen nur noch Sessions, die es einmal gemacht
haben.

Fuer einen Commit mit anderem Autor: `env -u GIT_AUTHOR_NAME -u
GIT_AUTHOR_EMAIL git commit ...` (ENV schlaegt `user.name`, siehe Tabelle
oben).

### Ist `/tmp/opencode` nicht beschreibbar?

`/tmp/opencode` (Scratch der Agent-Tools) wird **root:root 755** angelegt, nicht
als `dev`. Das Image setzt deshalb `mkdir -p /tmp/opencode && chmod 1777
/tmp/opencode` — 1777 wie `/tmp` selbst mit Sticky Bit, damit uid 1000 schreiben
kann, ohne die Rechte anderer zu gefaehrden. Wer das entfernt, sperrt jeden
Schreibzugriff darauf als `dev`; im laufenden Container laesst es sich einmalig
mit `sudo chmod 1777 /tmp/opencode` nachziehen, bis das naechste Image gebaut ist.

## 17. Die Portainer-DB ist eine Quelle der Wahrheit — und die haesslichste

Gemessen an Portainer **2.45.1** (`portainer/portainer-ce:lts`, DB 1 MiB, BoltDB
in `/var/lib/docker/volumes/portainer_data/_data/portainer.db`). Wer hier etwas
aendert, beruehrt die Datei, in der **alle** Stacks liegen.

**1. Bucket-Keys sind 8 Byte Big-Endian, kein ASCII.** `dev-vm` (ID 49) liegt
unter `00 00 00 00 00 00 00 31`. Wer `Get([]byte("49"))` benutzt, bekommt
**nichts** und schliesst faelschlich „Stack nicht gefunden". Immer iterieren
und im JSON nach `Name` suchen.

**2. Fuer Compose-Stacks existiert KEIN `FileContent`.** Das Feld fehlt im
Datensatz ganz (nicht 0 Byte, nicht `""`). Die Compose-Datei liegt **nur** auf
der Platte, `ProjectPath=/data/compose/<id>`. Folgen: (a) ein UI-Deploy laedt
sie von dort, (b) wer im Editor `Save` klickt, ohne vorher die Datei aus dem
Repo-HEAD einzufuegen, deployt einen **leeren** Stack.

**3. Portainer sperrt die DB exklusiv.** `bbolt.Open` bekommt im Betrieb
`timeout` — auch read-only. Zum Lesen: Portainer kurz stoppen, Kopie nehmen,
wieder starten, die Kopie auswerten. **Und:** `Timeout` in bbolt **blockiert**,
es bricht nicht ab. Ein `Timeout` im eigenen Code rettet nicht, nur ein
`db.Close()` vor der naechsten `Open`.

**4. Der Patch, wenn ein SSH-Deploy neue Env-Keys mitbringt** (2026-09-29 so
gemacht, fuer `dev-vm` um `TS_AUTHKEY`/`TS_TAILSCALE_HOSTNAME`):

```sh
D=/var/lib/docker/volumes/portainer_data/_data
cp -a "$D/portainer.db" "$D/portainer.db.bak-$(date +%Y%m%d-%H%M%S)"  # VOR dem Stop
docker stop portainer
cp -a "$D/portainer.db" "$D/portainer.db.bak-$(date +%Y%m%d-%H%M%S)"  # AKTUELLER Stand
# Schreib-Container als root auf dem Volume; auf Mac und VPS ist kein Go
# installiert, deshalb golang:1.24-alpine als Wegwerf-Container
docker run --rm -v "$D:/data" -v /w:/w -w /w golang:1.24-alpine \
  sh -c 'go mod init p >/dev/null 2>&1; go get go.etcd.io/bbolt@v1.4.0 && go run . /data/portainer.db dev-vm KEY=WERT'

**Das `go mod init` ist Pflicht, nicht Kosmetik** (2026-09-30 gemessen). In
`golang:1.24-alpine` bricht `go get` ohne Modul ab mit *"'go get' is no longer
supported outside a module"* — der §17-Befehl stammt aus aelteren Go-Versionen
und laeuft so nicht mehr. Ohne die Zeile passiert gar nichts und man haelt den
Patch fuer misslungen.
docker start portainer
```

Der zweite Backup ist nicht ueberfluessig: Portainer schreibt im
`SnapshotInterval` (5 min) auf die DB, und ein Patch auf einem aelteren Stand
rolled seine letzten Writes zurueck.

**5. Zwei Regeln, die den Patch gefahrlich machen, wenn man sie nicht kennt:**

- **Nur ein Feld anfassen.** Den Datensatz als
  `map[string]json.RawMessage` lesen und **ausschliesslich** den Schluessel
  `Env` ersetzen. Ein Unmarshal/Marshal-Roundtrip ueber ein Struct kann Felder
  umsortieren oder weglassen, und es sieht im Log harmlos aus.
- **Vorher/nachher fingerabdrucken.** Ueber **alle** Keys aller uebrigen
  Buckets einen SHA256 bauen und vergleichen; bei Abweichung abbrechen. Am
  2026-09-29 waren das 23 Keys, nach dem Patch identisch. Ohne diese Kontrolle
  ist ein "hat geklappt" keine Aussage.

**6. Werkzeug:** es gibt auf keinem der beiden Rechner Go. `bbolt` als
Wegwerf-Container ist der Weg; `strings` auf der DB findet zwar Klartext, taugt
aber nicht zum Schreiben.

**7. Was der Patch behebt und was nicht:** die **Env** ist danachpersistent. Die
**Compose-Datei** ist es nicht — die steht nicht in der DB (Punkt 2). Nach
einem UI-Deploy muss `remote/docker-compose.yml` aus dem HEAD trotzdem
eingefuegt werden.

## 18. Ein dokumentierter Env-Key ohne Mapping ist kein Container-Env

`stack.env` (und jede andere Stack-Env-Quelle) liefert **nur Interpolationswerte**
fuer `${VAR}` in der Compose-Datei. Es erzeugt **kein** Container-Env. Eine
Variable sieht der Container nur, wenn sie im `environment:`-Block des Service
**explizit gemappt** ist — also genau dort, wo `OPENCODE_PASSWORD`,
`TS_AUTHKEY` und `PORT` stehen.

**Beleg (2026-10-07):** `CORS_ORIGIN`. `entrypoint.sh` baut daraus
`--cors ${CORS_ORIGIN}`, die Datei dokumentierte den Key im Env-Kopf — aber im
`environment:`-Block von `code-dev` stand nichts. Der Key existierte damit
**nur als Entrypoint-Logik plus Kommentar**, in **keiner** Env-Datei: `.env`,
`remote/.env.production` und Commit `62ea52a` enthalten null `CORS_ORIGIN`-
Zeilen. Im Container war er also **nicht vorhanden**, `--cors` nie gesetzt,
der PWA-Zugriff blieb blockiert. Live geprueft: kein CORS-Eintrag in der
laufenden Compose-Datei, `CORS_ORIGIN` nicht im Container-Env.

**Eingetragen wird ausschliesslich die eigene PWA-Origin**
`https://ocweb.all-the.rest` (Entscheidung 2026-10-07). Keine fremden Origins —
der Key gehoert nicht als Sammel- oder Wildcard-Liste in den Stack.

**Regel:** Wer eine Env oben in der Datei dokumentiert, mappt sie im selben
Commit. Umgekehrt gilt fuer jede neue Zeile im `environment:`-Block: **leer
muss harmlos bleiben.** Ein verhaltensaendernder Fallback gehoert in
`entrypoint.sh`, nicht in die Compose-Datei — in der Compose-Datei darf nichts
stehen, das Zugriff oeffnet. Fuer `CORS_ORIGIN` heisst das: Mapping ohne `:-`,
leer bleibt leer. Die bestehenden `:-`-Defaults in der Datei bleiben
unberuehrt; sie greifen beim Rendern und stehen im gerenderten Config sehr
wohl im Container-Env (so entstehen die Defaults, die §9 Fall 2 zur
Sichtbarkeit in die Env hebt).
