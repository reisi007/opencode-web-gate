# AGENTS.md — Regeln fuer `remote/` (VPS-Weg)

Beschreibung und Messwerte stehen in [`README.md`](README.md) (485 Zeilen, u. a.
*Warum es kein `extra_hosts` gibt*, *`dind` ist rootless*, *RAM- und Swap-Limits*).
Hier nur die Regeln, die beim Aendern von `docker-compose.yml` / `entrypoint.sh` /
`.env.production` schon einmal eine Fehlermeldung oder ein Sicherheitsloch
erzeugt haben. Allgemeine Auth-Regeln: [`../AGENTS.md`](../AGENTS.md).

## 1. Deploy laeuft ueber Portainer, nicht ueber SSH

`docker-compose.yml` wird in den Web-Editor gepastet, `.env.production` als
Stack Environment. Ein File, kein Upload. Nach jeder Aenderung: Stack in
Portainer neu deployen — eine Datei im Repo aendert auf dem VPS **nichts**.

`.env.production` ist gitignored und trotzdem die einzige Quelle fuer den
laufenden Stack. `setup.sh` schreibt sie **nicht** (nur `.env`). Jede Zeile muss
`KEY=WERT` ergeben, wenn sie eingefuegt wird.

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
