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

`gh-config`, `gh-ssh`, `opencode-data/-config/-state` und
`/var/lib/docker/volumes/projects-50g-mnt:/projects` tragen `gh auth`, SSH-Keys
und den OpenCode-Zustand — sie ueberleben Image-Upgrades. Genau darum sind es
Named Volumes. `gh auth login` ist nach einem Stack-Recreate **nicht** noetig
und soll auch nicht dauernd noetig sein; wenn doch, ist ein Volume verloren
gegangen, nicht das Passwort.

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
