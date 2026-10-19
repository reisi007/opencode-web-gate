# AGENTS.md — Regeln fuer `local/` (Mac-Weg)

Beschreibung des Aufbaus steht in [`README.md`](README.md). Hier nur die Regeln
fuer `run.sh` / `bootstrap.sh` / das Caddy-Fragment.
Allgemeine Auth-Regeln: [`../AGENTS.md`](../AGENTS.md).

## 1. Der Tunnel gehoert autossh, nicht der Master-Connection

`TUNNEL_OPTS` in `run.sh` bleibt mit `ControlMaster=no` + `ControlPath=none`.
Haengt der Forward an der Master-Connection, stirbt er mit ihr, ohne dass
autossh neu verbindet. `WATCH_OPTS` darf `ControlMaster=auto` +
`ControlPersist` behalten — das ist eine zweite, unabhaengige Verbindung nur fuer
Waechter und `diagnose.sh`. Nicht "vereinfachen", auch wenn es doppelt aussieht.

## 2. Ein Forward pro `BIND:REMOTE`

`run.sh` beendet vor dem Start verwaiste `autossh`/`ssh`-Instanzen mit derselben
Bind-Adresse. Zwei ssh-Prozesse auf demselben VPS-Port machen sich mit
`ExitOnForwardFailure` gegenseitig die Bind kaputt. Die Bereinigung nicht
entfernen.

## 3. `opencode serve` nie manuell starten

`ensure_opencode` in `run.sh` ist der einzige Startpfad (Pflicht, nicht optional).
Ein manuell gestarteter `opencode serve` konkurriert mit dem supervisten um
`LOCAL_PORT`, und der Watchdog ist nicht der Besitzer des Prozesses — er beendet
ihn dann ohne Neustart. `OPENCODE_CMD` in `.env` ueberschreibt **nur** die
Kommandozeile, nicht die Pflicht.

Der superviste Serve ist ein Kind von `run.sh` und teilt dessen Prozessgruppe —
ein `launchctl bootout` nimmt ihn mit (§12). Eine Aussage wie "opencode laeuft
weiter" nach einem Stopp waere darum falsch.

## 4. Watchdog: Prozesserkennung und Schwelle

Nur `ps -eo pid=,comm=` mit dem Anker `(^|/)opencode(-cli)?$`, dann im awk-Body
gegen die **ganze Zeile** pruefen. Beides ist erzwungen:

- **Kein `pgrep -f opencode`.** `-f` matcht die Kommandozeile und trifft damit
  `run.sh` selbst, `opencode-usage` (node/tsx) und codegraph. Ein Kill auf dieses
  Muster reisst den Tunnel-Supervisor und fremde Dienste mit.
- **Kein `$2` als comm-Feld.** `comm` ist der ausfuehrbare Pfad; jeder Pfad mit
  Leerzeichen (z. B. unter `"/Applications/My Tools/…"`) wuerde an `$2`
  abgeschnitten.
- **`pgrep -f` greift auf macOS ins Leere**, wenn argv/Environment am
  Kernel-Textlimit abgeschnitten sind — als Erkennungsbasis unbrauchbar.

Der Anker fasst auch `serve --service` (zweite v2-API-/Web-Server-Instanz,
PPID 1 — das Server-Kind der laufenden TUI) mit: zaehlen ja, wegkillen nein.

### Die Schwelle liegt im Skript, die `.env` ist nur der Override

`WATCHDOG_MAX_RSS_MIB` ist mit **4 GiB** vorbelegt (`run.sh`, gerechnet in KiB).
Der Default steht im **Skript**; `.env.example` fuehrt den Key **auskommentiert**.
Eine aktive Zeile in `.env` waere eine zweite Quelle der Wahrheit (derselbe
stille Drift wie `MEMORY_LIMIT` in der Portainer-DB, `remote/AGENTS.md` §9
Fall 2) und schlaegt den Skript-Default still — sichtbar nur an
`watchdog: aktiv (Schwelle … MiB)` in `/tmp/code-tunnel.log`. Nicht-numerische
Werte, fuehrende Nullen (`08` waere oktal und reisst unter `set -e` den Start
mit) und alles unter 256 MiB fallen auf den Default zurueck. Wirksam wird ein
neuer Wert erst nach `launchctl kickstart -k gui/$(id -u)/com.code-tunnel`
(nimmt den supervisten Serve als Kind der Prozessgruppe mit, §12 — die TUI und
ihr `serve --service`-Kind laufen weiter).

- Die Schwelle ist ein Runaway-Waechter, kein RAM-Budget: der RSS folgt der
  **Last der aktiven Session**, nicht der Zeit.
- **RSS-Summen mehrerer Prozesse sind keine Speichermenge** (geteilte Seiten
  zaehlt macOS pro Prozess). Ehrlich ist der Footprint: `top -l 1 -pid <pid>
  -stats mem`.
- **codegraph ist nicht abgedeckt und darf es auch nicht sein:** zaehlen ja,
  wegkillen nein — das zerstoert die MCP-Verbindungen laufender Runs.
- Wer hier nachmisst, misst `serve --service` (RSS pro Prozess), nicht die Summe
  und nicht `codegraph`.

## 5. Watchdog: Bash 3.2 und die PID-Uebergabe

macOS-Bash kennt kein `BASHPID`. `$$` in einer Subshell ist die PID des
**Eltern**prozesses, ein `ps -o ppid= -p $$` liefert deshalb den Grosselternteil
(launchd) — der Vergleich waere immer falsch. Deshalb wird `$$` als **Argument**
uebergeben und per `kill -0` geprueft. Diese Form nicht "vereinfachen".

launchd SIGTERMt nur `run.sh`, nicht die Watchdog-Subshell — deshalb der
`kill -0`-Selbstcheck, sonst laufen nach jedem Neustart zwei Watchdogs auf
denselben PIDs. Das deckt den Fall `kill`/Ctrl+C im Vordergrund ab; bei
`launchctl bootout` nimmt die Prozessgruppe die Subshell mit (§12).

## 6. Watchdog: das Restart-Budget ist Absicht

`WATCHDOG_MAX_RESTARTS=3` pro `WATCHDOG_WINDOW=300`, danach pausiert der Watchdog
statt zu feuern. Ein `serve`, der sofort wieder ueber die Schwelle springt, ist
ein **Speicherleck-Symptom**, kein Neustart-Bedarf. Die Schwelle nicht
hochdrehen, damit die Logzeile verschwindet.

TUI-Sessions und die zweite Instanz `serve --service` werden bei Ueberschreitung
**beendet, nicht neu gestartet** — es gibt kein TTY zum Nachfuellen, und die
`--service`-Instanz laeuft unabhaengig von `run.sh` (PPID 1), gehoert also nicht
dem Watchdog. Kein Relaunch erfinden.

## 7. LaunchAgent: die gerenderte plist nie editieren

`scripts/com.code-tunnel.plist` ist eine **Vorlage** mit `__REPO__` / `__PATH__`;
`bootstrap.sh` rendert sie nach `~/Library/LaunchAgents/com.code-tunnel.plist`.
Aenderungen gehoeren in die Vorlage, sonst ueberschreibt der naechste
`bootstrap.sh`-Lauf sie.

- `Umask 077` in der plist gilt nur fuer **neue** Dateien. Bestehende Logs aus
  frueheren Laeufen bleiben world-readable — `run.sh` chmod-et sie deshalb
  explizit auf 600. `/tmp/code-tunnel-opencode.log` kann Session-Inhalte
  enthalten.
- `RunAtLoad` + `KeepAlive` + `ThrottleInterval` sind die drei Invarianten.
  `ThrottleInterval` ist kein Beiwerk: ohne sie startet launchd nach einem
  Absturz in einer Schleife.
- `bootstrap.sh` muss no-op bleiben, wenn Agent geladen + Forward steht + Key
  unveraendert ist. Nach einem **Key-Wechsel** greift der Fast-Path nicht (der
  laufende Agent hat `.env` schon gelesen) — der Tunnel-Restart dort ist
  gewollt, keine Doppelstart-Bug.

## 8. Doppelklick startet mit minimalem PATH

`run.sh` exportiert `~/.opencode/bin` + Homebrew-Pfade selbst, weil
`start-tunnel.command` aus dem Finder heraus mit einem reduzierten PATH startet.
Diese Zeile nicht entfernen, sonst findet der Doppelklick `opencode` nicht.

## 9. Was in diesem Ordner escaped wird — und was nicht

- `../.env`: **`AUTH_HASH` unescaped** (`$2a$14$…`), aber in **einfache
  Anfuehrungszeichen** gesetzt (`AUTH_HASH='$2a$14$…'`). Hier laeuft kein
  Portainer-Interpolationsschritt — und `run.sh` & Co. sourcen die Datei unter
  `set -euo pipefail`. Ohne Quotes expandiert Bash `$2` beim Sourcen und bricht
  mit `$2: unbound variable` ab; der Tunnel startet dann gar nicht mehr.
  `setup.sh` schreibt den Wert deshalb gequotet, genau so gehoert er in die
  Datei.
- `docker-compose.yml`: **`$$` im `command:`-Heredoc** — Compose substituiert
  sonst, weil der Wert im eingebetteten Python steht (`AUTH_HASH.startswith("$2")`).
  Das ist ein anderes `$$` als in `remote/.env.production` und bleibt
  unangetastet.

## 10. `Caddyfile.fragment` ist eine Vorlage, kein Caddyfile

Platzhalter `__CODE_DOMAIN__`, `__CODE_SITE__`, `__OPENCODE_BASIC__`,
`__CORS_ORIGIN__` werden von Hand in die **globale** Caddyfile auf dem VPS
uebernommen, danach `./sync.sh` (validate + reload). `__OPENCODE_BASIC__` ist
`base64("opencode:$OPENCODE_PASSWORD")` — der echte Wert gehoert **nie** ins
Repo. `__CORS_ORIGIN__` ist die eigene PWA-Origin
(`https://ocweb.all-the.rest`), keine Liste. Die Datei laeuft nicht als eigenes
Caddyfile, sie wird nicht deployed, sie ist Text.

- **Ein unersetzter Platzhalter ist kein Fehler im Log.** `__CORS_ORIGIN__` als
  Wert ergibt syntaktisch gueltiges Caddy; die Antwort traegt dann
  `Access-Control-Allow-Origin: __CORS_ORIGIN__`, und der Browser lehnt sie ab,
  ohne dass Caddy etwas meldet. Platzhalter deshalb nach dem Uebernehmen mit
  `grep -n '__[A-Z_]*__' Caddyfile` gegenpruefen — die `validate`-Stufe von
  `sync.sh` faengt das nicht.
- `health_headers { Authorization … }` im Healthcheck nicht entfernen: ohne den
  Header ist `/api/info` durch das Basic-Passwort 401 und der Healthcheck meldet
  dauerhaft unhealthy.
- `__OPENCODE_BASIC__` ist der **Mac**-Wert aus `../.env`, nicht der Remote-Wert:
  der Tunnel-Block `code.all-the.rest` und der `remote-code`-Block injizieren
  getrennt ihre jeweiligen Werte — die beiden Bloecke **nicht** angleichen. Zwei
  Werte also getrennt rotieren; die Stellen im Tunnel-Block sind `header_up`
  (zweimal: `@api_ok` und die Cookie-Gate-Catch-all) plus `health_headers`.

## 11. `sync.sh` veroeffentlicht sofort

`apps/web/dist/` geht per **rsync/ssh** live auf den VPS (`root@` Port 22, Ziel
`SYNC_SITES_ROOT/SYNC_SITE_DIR` = `/home/webadmin/websites/code.all-the.rest/`,
im caddy-Container als `/srv/websites` gemountet). `login.html` ist die
securityrelevante Tuer des Gates (Cookie-Seite statt Browser-Popup,
bcrypt-Passwort geht nie an OpenCode). Was dort liegt, ist nach `sync.sh`
produktiv — Review vor dem Sync, nicht danach. `./sync.sh --dry-run` vor jedem
echten Sync.

- **Der Fremddatei-Check vor `--delete`** bleibt: `sync.sh` bricht ab, wenn im
  Zielverzeichnis etwas liegt, das nicht `*.html` ist. Sonst wuerde ein falsches
  `SYNC_SITE_DIR` still die Site eines anderen Projekts leeren.
- **Der GNU-rsync-Guard** bleibt: macOS liefert `/usr/bin/rsync` = openrsync, das
  `--chown`/`--chmod` nicht im noetigen Umfang kann. Nicht per
  `rsync --version | grep -q` bauen — unter `set -o pipefail` beendet `grep -q`
  den Upstream per SIGPIPE, die Pipeline gilt als fehlgeschlagen, der Guard
  schlaege immer an. Deshalb erst in eine Variable.
- Beim Testen beachten: `LOCAL_DIST` steht in `.env`, und `source ../.env`
  ueberschreibt einen exportierten Wert — `LOCAL_DIST=… ./sync.sh` wird still
  ignoriert.

Fuer die `$$`-Regel in der Portainer-Kopie und die Pflicht, dass `code` und
`remote-code` denselben Login teilen: [`../AGENTS.md`](../AGENTS.md).

## 12. Stoppen heisst `disable` **vor** `bootout` — und nicht nur das

`stop-tunnel.command` ist der einzige Stopp-Pfad (Doppelklick oder
`./stop-tunnel.command`). Zwei Dinge, die ein blosses
`launchctl bootout gui/$(id -u)/com.code-tunnel` nicht leistet und die deshalb
nicht "vereinfacht" werden duerfen:

- **`disable` zuerst.** Die gerenderte plist bleibt in `~/Library/LaunchAgents`
  liegen — launchd laedt sie beim naechsten Login wieder, `RunAtLoad` feuert, der
  Tunnel ist zurueck. `bootstrap.sh` macht `launchctl enable` vor
  `launchctl bootstrap`, das ist die Rueckfahrt; ohne `enable` dort startet
  gar nichts.
- **Aufraeumen danach.** `bootout` SIGTERMt die Prozessgruppe und reisst
  autossh/ssh mit — im Agent-Pfad bleibt also nichts uebrig. Der Schritt ist
  fuer den Finder-Fallback (`run.sh` im Vordergrund) und fuer Waisen
  aeilterer Laeufe noetig. Reihenfolge darin: **erst `autossh`, dann `ssh`** —
  ein allein gekilltes `ssh` im Forward laesst autossh sofort neu verbinden.

Drei Fallen, jeweils mit derselben Ursache — die Erkennung ist absichtlich eng:

- **Die Watchdog-Subshell hat dasselbe argv wie `run.sh`** (fork ohne exec).
  Wer per `ps` nach dem Supervisor sucht, findet beide. Das ist hier gewuenscht,
  darf aber nicht als "zwei Supervisor" fehlgedeutet werden.
- **Kein `pkill -f run.sh`.** Das Muster trifft jedes Fenster, in dem der Pfad
  nur vorkommt. `runsh_pids` prueft stattdessen argv-Positionen: Feld 1 = Shell,
  Feld 2 = `run.sh`-Pfad, danach hoechstens `--tunnel-only`. Gegenprobe
  `sh -c 'sleep 3 # /run.sh'` darf **nicht** matchen.
- **Kein pauschales `pkill ssh`** — das wuerde fremde ssh-Sitzungen (Git,
  VS-Code-Remote) mitreissen. Die Forward-Signatur muss mit `run.sh`
  uebereinstimmen (`-R BIND:REMOTE` plus `$TARGET` am Zeilenende, §2), sonst
  raeumt der Stopp eine andere Menge auf als der Start.

**Was der Stopp sichtbar macht, ist nicht der 502.** Ohne Cookie greift
`forward_auth` zuerst: `https://CODE_DOMAIN/` liefert `302 → /login.html`, mit
und ohne Tunnel. Den Tunnel sieht erst ein *angemeldeter* Request — dann 502 aus
dem Proxy, und `handle_errors` liefert `tunnel-down.html`; ebenso setzt der
aktive Healthcheck (30 s Intervall, 3 Fehlschlaege) den Upstream auf `down`.
Wer nach dem Stopp `curl -o /dev/null -w '%{http_code}' https://CODE_DOMAIN/`
laufen laesst und 502 erwartet, hat das Gate und nicht den Tunnel gemessen.
