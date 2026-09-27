# AGENTS.md — Regeln fuer `local/` (Mac-Weg)

Beschreibung des Aufbaus steht in [`README.md`](README.md). Hier nur die Regeln,
die beim Aendern von `run.sh` / `bootstrap.sh` / dem Caddy-Fragment schon einmal
etwas kaputt gemacht haben. Allgemeine Auth-Regeln: [`../AGENTS.md`](../AGENTS.md).

## 1. Der Tunnel gehoert autossh, nicht der Master-Connection

`TUNNEL_OPTS` in `run.sh` ist mit `ControlMaster=no` + `ControlPath=none`
**absichtlich** so gesetzt. `WATCH_OPTS` darf `ControlMaster=auto` +
`ControlPersist` behalten — das ist eine zweite, unabhaengige Verbindung nur fuer
Waechter und `diagnose.sh`.

Warum: haengt der Forward an der Master-Connection, stirbt er mit ihr, ohne dass
autossh neu verbindet. Symptom war "Tunnel liegt tot, obwohl autossh laeuft".
Nicht "vereinfachen", auch wenn es doppelt aussieht.

## 2. Ein Forward pro `BIND:REMOTE`

`run.sh` beendet vor dem Start verwaiste `autossh`/`ssh`-Instanzen mit derselben
Bind-Adresse. Zwei ssh-Prozesse auf demselben VPS-Port machen sich mit
`ExitOnForwardFailure` gegenseitig die Bind kaputt. Wer die Bereinigung entfernt,
bekommt sporadische Tunnel-Ausfaelle und kann sie schwer zuordnen.

## 3. `opencode serve` nie manuell starten

`ensure_opencode` in `run.sh` ist der einzige Startpfad (Pflicht, nicht optional).
Ein manuell gestarteter `opencode serve` konkurriert mit dem supervisten um
`LOCAL_PORT`, und der Watchdog ist nicht der Besitzer des Prozesses — er beendet
ihn dann ohne Neustart. `OPENCODE_CMD` in `.env` ueberschreiben **nur** die
Kommandozeile, nicht die Pflicht.

Er ist zugleich ein Kind von `run.sh` (`run.sh:127`, `&` im Vordergrund) und
teilt dessen Prozessgruppe. Ein `launchctl bootout` nimmt die Gruppe mit, der
superviste Serve also mit — siehe §12. Das ist kein Fehler, aber eine Aussage
wie "opencode laeuft weiter" nach einem Stopp waere falsch.

## 4. Watchdog: wie der opencode-Prozess gefunden wird

Nur `ps -eo pid=,comm=` mit dem Anker `(^|/)opencode(-cli)?$`, dann im awk-Body
gegen die **ganze Zeile** pruefen. Beides ist erzwungen:

- **Kein `pgrep -f opencode`.** `-f` matcht die Kommandozeile und trifft damit
  `run.sh` selbst, `opencode-usage` (node/tsx) und codegraph. Ein Kill auf dieses
  Muster reisst den Tunnel-Supervisor und fremde Dienste mit.
- **Kein `$2` als comm-Feld.** `comm` ist der ausfuehrbare Pfad; jeder Pfad mit
  Leerzeichen (z. B. unter `"/Applications/My Tools/…"`) wuerde an `$2`
  abgeschnitten.
- **`pgrep -f` greift auf macOS ins Leere**, wenn argv/Environment am
  Kernel-Textlimit abgeschnitten sind — das Muster steht dann nicht mehr im argv.
  Als Erkennungsbasis unbrauchbar.

### Der Anker matcht drei Prozesse, nicht "die beiden Binaries"

Live am 2026-09-27 auf diesem Mac:

| PID | Kommando | Rolle |
|---|---|---|
| 13972 | `opencode serve --hostname 127.0.0.1 --port 8080` | der superviste Serve, `:$LOCAL` |
| 75117 | `…/opencode serve --service` | **zweite** v2-API-/Web-Server-Instanz, PPID 1, `localhost:49374` |
| 51034 | `opencode` | TUI/CLI |

`opencode serve` ist laut `serve --help` "Start the v2 API and web server"; die
unabhaengige `--service`-Instanz ist **nicht** vom Desktop, sondern eine eigene
Web-Server-Instanz. Sie war mit 1286 MiB der groesste Brocken auf diesem Mac.

**Frueher stand hier die Begruendung ueber einen "Desktop-Server" unter
`Application Support/ai.opencode.desktop`. Das war falsch: die Desktop-App ist
deinstalliert (`/Applications/OpenCode.app` existiert nicht, nur noch der
Datenrest im Library-Ordner).** Die Mechanik war trotzdem richtig — der Anker
fasst `serve --service` mit — nur die Begruendung beschrieb einen Prozess, den
es nicht mehr gibt. Bei der naechsten Desktop-Reinstallation nicht zur
Gewohnheit machen.

### Die Schwelle ist ein Runaway-Waechter, kein RAM-Budget

10,6 h minuetlich gemessen ueber alle opencode-Prozesse: **kein unbegrenztes
Wachstum.** Footprint-Summe 884 -> 694 MiB, Swap 1819 -> 1763 MiB, 88 % RAM frei,
sieben Stunden exakt waagerecht. `serve --service` stieg auf 1284 MiB und fiel auf
1248 zurueck. Der RSS folgt der **Last der aktiven Session**, nicht der Zeit —
ein stuendlicher Neustart haette also 24 Unterbrechungen fuer einen Plattlauf
gekauft.

- **RSS-Summen mehrerer Prozesse sind keine Speichermenge.** Geteilte Seiten
  zaehlt macOS pro Prozess. Ehrlich ist der Footprint:
  `top -l 1 -pid <pid> -stats mem`. Die Schwelle pro Prozess ist robust, weil
  sie geteilte Seiten nicht ueberzaehlt.
- **codegraph ist nicht abgedeckt und darf es auch nicht sein:** 1350-1540 MiB in
  12-17 Prozessen, mehr als alle opencode-Prozesse zusammen. Zaehlen ja,
  wegkillen nein — das zerstoert die MCP-Verbindungen laufender Runs.

## 5. Watchdog: Bash 3.2 und die PID-Uebergabe

macOS-Bash kennt kein `BASHPID`. `$$` in einer Subshell ist die PID des
**Eltern**prozesses, ein `ps -o ppid= -p $$` liefert deshalb den Grosselternteil
(launchd) — der Vergleich waere immer falsch, der Watchdog stirbt nach dem ersten
Poll. Deshalb wird `$$` als **Argument** uebergeben und per `kill -0` geprueft.
Diese Form nicht "vereinfachen".

Nebenbei: launchd SIGTERMt nur `run.sh`, nicht die Watchdog-Subshell — deshalb
der `kill -0`-Selbstcheck, sonst laufen nach jedem Neustart zwei Watchdogs auf
denselben PIDs.

**Nachtrag (gemessen 2026-09-27):** Das gilt fuer ein `kill` auf die run.sh-PID.
`launchctl bootout` stoppt den Job ueber die **Prozessgruppe** und nimmt die
Subshell dort mit — siehe §12. Der Selbstcheck ist trotzdem richtig, denn er
deckt den anderen Fall ab (kill, Ctrl+C im Vordergrund).

## 6. Watchdog: das Restart-Budget ist Absicht

`WATCHDOG_MAX_RESTARTS=3` pro `WATCHDOG_WINDOW=300`, danach pausiert der Watchdog
statt zu feuern. Ein `serve`, der sofort wieder ueber 2 GiB springt, ist ein
**Speicherleck-Symptom**, kein Neustart-Bedarf. Die Schwelle nicht hochdrehen,
damit die Logzeile verschwindet.

TUI-Sessions und die zweite Instanz `serve --service` werden bei Ueberschreitung
**beendet, nicht neu gestartet** — es gibt kein TTY zum Nachfuellen, und die
`--service`-Instanz laeuft unabhaengig von `run.sh` (PPID 1), gehoert also nicht
dem Watchdog. Die Logzeile sagt das bewusst laut. Kein Relaunch erfinden.

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

- `../.env`: **`AUTH_HASH` unescaped** (`$2a$14$…`). Hier laeuft kein
  Portainer-Interpolationsschritt.
- `docker-compose.yml`: **`$$` im `command:`-Heredoc** — Compose sonst, weil der
  Wert im eingebetteten Python steht (`AUTH_HASH.startswith("$2")`). Das ist ein
  anderes `$$` als in `remote/.env.production` und bleibt unangetastet.

## 10. `Caddyfile.fragment` ist eine Vorlage, kein Caddyfile

Platzhalter `__CODE_DOMAIN__`, `__CODE_SITE__`, `__OPENCODE_BASIC__` werden von
Hand in die **globale** Caddyfile auf dem VPS uebernommen, danach `./sync.sh`
(validate + reload). `__OPENCODE_BASIC__` ist `base64("opencode:$OPENCODE_PASSWORD")`
— der echte Wert gehoert **nie** ins Repo. Die Datei laeuft nicht als eigenes
Caddyfile, sie wird nicht deployed, sie ist Text.

Nicht entfernen: `health_headers { Authorization … }` im Healthcheck. Ohne den
Header ist `/api/info` durch das Basic-Passwort 401 und der Healthcheck meldet
dauerhaft unhealthy, obwohl alles laeuft.

## 11. `sync.sh` veroeffentlicht sofort

`apps/web/dist/` geht per **rsync/ssh** live auf den VPS (`root@` Port 22,
Ziel `SYNC_SITES_ROOT/SYNC_SITE_DIR` = `/home/webadmin/websites/code.all-the.rest/`,
im caddy-Container als `/srv/websites` gemountet). `login.html` ist die
securityrelevante Tuer des Gates (Cookie-Seite statt Browser-Popup, bcrypt-Passwort
geht nie an OpenCode). Was dort liegt, ist nach `sync.sh` produktiv — Review vor
dem Sync, nicht danach.

Der frühere Weg (rclone-SFTP ueber SFTPGo auf Port 2222, User `webadmin`) ist
tot: derselbe Host-Key ist an drei Key-Typen rotiert, rclone brach mit
`knownhosts: key mismatch` ab. Migration wie in `all-the.rest` und
`portal.reisinger.pictures`, Hintergrund dort: `strato-vps/README.md`.

Zwei Dinge nicht wegoptimieren:

- **Der Fremddatei-Check vor `--delete`.** `sync.sh` bricht ab, wenn im
  Zielverzeichnis etwas liegt, das nicht `*.html` ist. Der Publish ist sofort
  (siehe oben), und ein falsches `SYNC_SITE_DIR` würde sonst still die Site
  eines anderen Projekts leeren.
- **Der GNU-rsync-Guard.** macOS liefert `/usr/bin/rsync` = openrsync, das
  `--chown`/`--chmod` nicht im nötigen Umfang kann. Der Guard darf **nicht**
  per `rsync --version | grep -q` gebaut werden: unter `set -o pipefail`
  beendet `grep -q` den Upstream per SIGPIPE, die Pipeline gilt als
  fehlgeschlagen, der Guard schlägt immer an. Deshalb erst in eine Variable.

`./sync.sh --dry-run` vor jedem echten Sync. Beim Testen beachten: `LOCAL_DIST`
steht in `.env`, und `source ../.env` überschreibt einen exportierten Wert —
`LOCAL_DIST=… ./sync.sh` wird still ignoriert.

Siehe [`../AGENTS.md`](../AGENTS.md) fuer die `$$`-Regel in der Portainer-Kopie
und die Pflicht, dass `code` und `remote-code` denselben Login teilen.

## 12. Stoppen heisst `disable` **vor** `bootout` — und nicht nur das

`stop-tunnel.command` ist der einzige Stopp-Pfad (Doppelklick oder
`./stop-tunnel.command`). Zwei Dinge, die ein blosses
`launchctl bootout gui/$(id -u)/com.code-tunnel` nicht leistet und die deshalb
nicht "vereinfacht" werden duerfen:

- **`disable` zuerst.** Die gerenderte plist bleibt in `~/Library/LaunchAgents`
  liegen — launchd laedt sie beim naechsten Login wieder, `RunAtLoad` feuert,
  der Tunnel ist zurueck. `bootstrap.sh` macht `launchctl enable` vor
  `launchctl bootstrap`, das ist die Rueckfahrt; ohne `enable` dort startet
  gar nichts (siehe dort, Kommentar "enable VOR bootstrap").
- **Aufraeumen danach.** `bootout` SIGTERMt die Prozessgruppe und reisst
  autossh/ssh mit — im Agent-Pfad bleibt also nichts uebrig. Der Schritt ist
  fuer den Finder-Fallback (`run.sh` im Vordergrund) und fuer Waisen
  aeilterer Laeufe noetig. Reihenfolge darin: **erst `autossh`, dann `ssh`** —
  ein allein gekilltes `ssh` im Forward laesst autossh sofort neu verbinden.

Gemessen am 2026-09-27 an diesem Mac (Live-Stopp des laufenden Agenten):

| Prozess | nach dem Stopp |
|---|---|
| `run.sh --tunnel-only` (PPID 1) | weg, von `bootout` mitgenommen |
| Watchdog-Subshell (PPID = run.sh) | weg, gleiche argv — siehe unten |
| `autossh` + `ssh` mit `-R 172.18.0.1:18731` | weg |
| `opencode serve --port 8080` (supervist) | **weg** — Kind von `run.sh`, gleiche Gruppe |
| `opencode serve --service` (PPID 1) | laeuft weiter |
| TUI-Sessions | laufen weiter |
| `launchctl print gui/$UID/com.code-tunnel` | „Could not find service" |
| `launchctl print-disabled` | `"com.code-tunnel" => disabled` |
| `ss -tln \| grep :18731` auf dem VPS | kein Treffer |

Drei Fallen, jeweils mit derselben Ursache — die Erkennung ist absichtlich eng:

- **Die Watchdog-Subshell hat dasselbe argv wie `run.sh`** (fork ohne exec).
  Wer per `ps` nach dem Supervisor sucht, findet beide. Das ist hier gewuenscht
  (spart das 60-s-Selbstcheck-Warten aus §5), darf aber nicht als "zwei
  Supervisor" fehlgedeutet werden.
- **Kein `pkill -f run.sh`.** Das Muster trifft jedes Fenster, in dem der Pfad
  nur vorkommt. `runsh_pids` prueft stattdessen argv-Positionen: Feld 1 = Shell,
  Feld 2 = `run.sh`-Pfad, danach hoechstens `--tunnel-only`. Gegenprobe
  `sh -c 'sleep 3 # /run.sh'` darf **nicht** matchen.
- **Die Forward-Signatur muss mit `run.sh` uebereinstimmen** (`-R BIND:REMOTE`
  plus `$TARGET` am Zeilenende, §2), sonst raeumt der Stopp eine andere Menge
  auf als der Start. Kein pauschales `pkill ssh` — das wuerde fremde
  ssh-Sitzungen (Git, VS-Code-Remote) mitreissen.

**Was der Stopp sichtbar macht, ist nicht der 502.** Ohne Cookie greift
`forward_auth` zuerst: `https://CODE_DOMAIN/` liefert `302 → /login.html`, mit
und ohne Tunnel. Den Tunnel sieht erst ein *angemeldeter* Request — dann 502 aus
dem Proxy, und `handle_errors` liefert `tunnel-down.html`
(`Caddyfile.fragment` Z. 91-100). Ebenso der aktive Healthcheck: 30 s Intervall,
3 Fehlschlaege, dann Upstream `down` (Z. 61-66). Wer nach dem Stopp
`curl -o /dev/null -w '%{http_code}' https://CODE_DOMAIN/` laufen laesst und
502 erwartet, hat das Gate und nicht den Tunnel gemessen.
