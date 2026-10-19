# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

## 2026-10-16

- [x] **Lokaler RAM-Waechter: Schwelle 2 GiB -> 4 GiB (Entscheidung des
  Menschen), per `WATCHDOG_MAX_RSS_MIB` uebersteuerbar.** Anlass war die
  Beobachtung "die Session wird sehr oft neu gestartet" — die Ursache steht im
  Log: der lokale Waechter (`local/run.sh`) hat am selben Tag **15x** zwischen
  12:56 und 14:04 zugeschlagen (2051-2543 MiB RSS), jedes Mal `serve --service`,
  das Server-Kind der laufenden TUI — **nie** der superviste `:8080`-Serve
  (PID 20243, stabil ~500 MiB, Kind von `run.sh`). Neu gestartet hat den Prozess
  die TUI, nicht der Waechter (die Logzeile sagt "manueller Neustart noetig",
  Sekunden spaeter stand trotzdem eine neue PID). Entscheidung: Default
  **4096 MiB im Skript** (einzige Quelle der Wahrheit), `WATCHDOG_MAX_RSS_MIB`
  **auskommentiert** in `.env.example` als bewusster Override — eine aktive
  Zeile in `.env` waere der stille Drift aus `remote/AGENTS.md` §9 Fall 2.
  Dazu Untergrenze 256 MiB und fuehrende Nullen entschaerft (`10#`, "08" waere
  sonst oktal und reisst unter `set -e` den ganzen Start mit). Umgesetzt in
  `local/run.sh`, dokumentiert in `local/AGENTS.md` §4 (inkl. der Widerlegung
  meiner ersten Fassung "2 GiB hat nie ausgeloest") und §6. Live verifiziert:
  `launchctl kickstart -k gui/$(id -u)/com.code-tunnel` am 2026-10-16 14:10 →
  Log "watchdog: aktiv (Schwelle 4096 MiB)", Tunnel danach aktiv.
- [ ] **OFFEN: haelt `serve --service` unter 4 GiB?** Gemessen ist nur, dass es
  unter 2 GiB nicht zur Ruhe kommt (frisch respawnt: 1871 MiB nach 5 min). Der
  Waechter wird also seltener feuern — ob die Churn aufhoert, ist offen. Nach-
  messen ueber 1-2 h: `ps -o rss=` des TUI-Kinds gegen die Kill-Zeilen in
  `/tmp/code-tunnel.log`. Reisst es wieder, ist nicht "die Zahl zu klein",
  sondern ein Wachstum im Kind (dann melden, nicht weiter hochdrehen — §6).

## 2026-10-15

## 2026-10-10

- [ ] **HF-Zugang in `code-dev`: Live-Hotfix erledigt, Repo-Seite angepasst,
  Deploy fehlt (Entscheidung 2026-10-10).** Gewuenscht war `hf login` im
  Dev-Container auf dem Remote-VPS. **Live ohne Neustart erledigt:**
  `huggingface_hub[cli]` 2.2.0 per `pip --break-system-packages` in `code-dev`
  installiert, Token als `reisi007` hinterlegt — `hf auth whoami` =
  `reisi007`, `hf download` eines kleinen Testfiles erfolgreich.
  **Haelt nur bis zum naechsten Recreate:** beides liegt im Writable-Layer, und
  `~/.cache` ist kein Volume (`remote/AGENTS.md` §16). Repo angepasst:
  `remote/Dockerfile` (CLI ins Image), `remote/docker-compose.yml`
  (`HF_TOKEN=${HF_TOKEN}`, dokumentiert im Kopf), `remote/.env.production`
  (`HF_TOKEN=…`, gitignored), Regel in `remote/AGENTS.md` §20.
- [ ] **Portainer-Deploy ausstaendig (der eigentliche naechste Schritt).**
  `HF_TOKEN` ist ein neuer Env-Key, den die Portainer-DB noch nicht kennt
  (§17). Compose **und** Env in der UI pasten (Stack `dev-vm` → Update), sonst
  schreibt der naechste Browser-Deploy `stack.env` ohne ihn. Die `hf`-CLI
  braucht danach keinen manuellen Rebuild: `build-baseline.yml` baut auf Push
  von `remote/Dockerfile` automatisch neu (und taeglich per cron). Ein Recreate
  vor beidem verliert `hf` und das Token wieder. `hf auth login` interaktiv im
  `docker exec` ist unbrauchbar (haengt, 90-s-Timeout) — Weg in
  `remote/AGENTS.md` §20.

## 2026-10-09

## 2026-10-08

- [ ] **Verworfen (nicht nachtraeglich implementieren):** den opencode-Wert
  zusaetzlich als OR-Wert im `@api_ok` stehenlassen (Caddy kann `Authorization`
  mit mehreren Werten als OR — getestet). Der Nutzer wollte **ersetzen**,
  nicht ergaenzen.
- [ ] **`remote/Caddyfile.fragment` + `local/Caddyfile.fragment` driften vom
  Live-Stand (2026-10-08).** Sie dokumentieren noch `basic_auth` +
  `__OPENCODE_BASIC_HASH__` (bcrypt am Edge) und den opencode-Wert als
  Edge-Kennung; live ist die Edge-Kennung die Login-Kennung. Zu portieren,
  inkl. Platzhalter (`__OPENCODE_USER__`/`__OPENCODE_BASIC_HASH__` entfallen
  zugunsten eines Edge-Credential-Platzhalters).
- [ ] **Ergaenzung zum Credential-Rotations-Ticket (2026-10-07,
  `caddyfile/Caddyfile` Heads 441/451/…):** der `@api_ok`-base64-Wert ist jetzt
  das reversible base64 der **Login-Kennung** — dasselbe History-Rewrite-Ticket
  deckt ihn mit ab.
## 2026-10-07

- [ ] Portainer-DB-Patch nach `remote/AGENTS.md` §9 **Fall 1** (neuer Env-Key,
  der per SSH-Deploy kam), Schema §17.4 — sonst schreibt der naechste UI-Deploy
  den Key wieder weg. (`.env.production` ist bereits mitgezogen.)
- [ ] **`Access-Control-Allow-Origin`/`-Allow-Credentials` auf der echten
  authentifizierten Response ist unbewiesen.** Der 302-Preflight ist gemessen,
  die Header einer eingeloggen Response nicht — braucht eine Session
  (DevTools oder `curl` mit Cookie). **Nichts** ueber die `--cors`-Interna
  behaupten, `serve --help` schweigt dazu. Ergaenzung zu §19 „Offen":
  ```sh
  curl -sS -b 'auth=<HMAC-Cookie>' -H 'Origin: https://ocweb.all-the.rest' \
    https://remote-code.all-the.rest/api/info | grep -i access-control
  ```
- [ ] **`Allow-Headers`-Liste ist geraten** (`Authorization, Content-Type`).
  Aus dem echten `Access-Control-Request-Headers` ableiten (DevTools-Netz-Tab
  der PWA). Fehlt dort ein Header, faellt der Preflight trotz korrektem ACAO
  durch. Als Kommentar in beiden `@options`-Bloecken notiert.
- [ ] **Lokaler Weg braucht noch einen `serve`-Neustart**, damit `run.sh` das
  `--cors` an den laufenden Prozess haengt (`local/run.sh:117` baut die
  Kommandozeile, der CORS-Append steht in Z. 118-132; wirkt erst beim
  naechsten Start durch). Der `CORS_ORIGIN`-Key selbst ist lokal in `.env`
  gesetzt, der Remote-Key braucht weiterhin den Portainer-DB-Patch siehe oben.
- [ ] **Echte Basic-Credentials in `caddyfile/Caddyfile` (Heads 441/451/562/573,
  vorbestehend, nicht aus einem Task-Diff).** Entscheidung 2026-10-07:
  **Später** — eigenes Ticket: rotieren (beide Wege + Portainer + `.env`) und
  History-Rewrite, sonst liegen die Klartext-Credentials dauerhaft in der
  Git-Historie. Fund aus Caddy-Verify N7, dort nicht angefasst.

## 2026-10-02

- [ ] **Trigger-Tests IMMER gegen einen Dummy-Prozess, nie gegen PID 1.**
  Am 2026-10-02 bei der Verifikation des neuen `ram-watchdog.sh` gescheitert:
  Der Wächter war bereits gegen einen Dummy-Prozess (`trap "" TERM`, also ein
  Prozess, der SIGTERM ignoriert) erfolgreich geprüft — beide Stufen, sauberer
  Shutdown und Eskalation auf SIGKILL. Für den letzten Test wurde die Schwelle
  trotzdem auf 74 % gesetzt (real 75 %), um das Auslösen gegen die **echte**
  cgroup zu zeigen. Der Wächter unterscheidet nicht zwischen „ich teste das"
  und „das ist echt" — er hat `opencode serve` terminiert, `restart: unless-
  stopped` hat neu gestartet, `RestartCount` 2 → 3. **Die laufende Session
  war weg.** Das war genau die Klasse aller Abstürze, gegen die der Wächter
  gebaut wird, ausgelöst durch die eigene Verifikation.

  **Regel:** Ein Test, der `kill`/SIGTERM/SIGKILL oder einen Neustart auslösen
  kann, läuft gegen `sleep`/`trap`-Dummys. Für den Triggernachweis gegen die
  echte cgroup genügt es, die *Auslösebedingung* zu zeigen (Log-Zeile mit den
  echten Byte-Werten) und den *Signalversand* am Dummy — beides zusammen, aber
  nie am echten PID 1. Ein echter Neustart braucht ein ausdrückliches Okay des
  Menschen, das nicht aus einem allgemeinen „verifiziere das" folgt.

- [ ] **RAM-Wächter ist im Repo, aber noch nicht ausgerollt.** `ram-watchdog.sh`
  liegt in `remote/`, ist im Dockerfile per `COPY` nach
  `/usr/local/bin/ram-watchdog.sh` gelegt und wird in `remote/entrypoint.sh`
  hinter dem Update-Watcher geforkt (`RAM_WATCHDOG_ENABLED`, default true).
  Am laufenden Container **verifiziert**: findet PID 1, liest echte
  cgroup-Werte, löst bei Schwelle aus, SIGTERM→sauber / SIGTERM ignoriert→
  SIGKILL, überlebt das `exec` des Entrypoints. **Nicht verifiziert:** das
  Verhalten unter echtem Speicherdruck — bei 75 % Last hätte der Wächter mit
  Schwelle 90 % *nicht* ausgelöst, und ob er den Kernel-OOM rechtzeitig
  abfängt, ist ungesehen.
  **Rollout:** watchtower nimmt `code-dev` nicht an (Entscheidung vom
  2026-09-30), also muss der Stack manuell neu deployed werden. Das beendet
  die laufende Session — erst durchrollen, wenn keine Arbeit offen ist.

- [ ] **Host-Budget ist rechnerlich weiterhin überzeichnet.** Nach der
  dind-Senkung (2,5g → 2g, 2026-10-02): code-dev 5g + dind 2g + Portal ~0,7g
  + OS ~0,7g = ~8,4 GB bei **7,47 GB** nutzbarem Host-RAM (8 GB minus OS/Docker)
  — also weiterhin ~0,9 GB zu viel. Die Senkung hat den Fehlbetrag von ~1,25 GB
  auf ~0,9 GB verkleinert, nicht behoben. **Strukturell nur mit mehr Host-RAM
  lösbar.** Als Beleg, dass dind 2g sicher ist: `memory.peak` 419012608
  (400 MB), `memory.current` 332775424 (317 MB) = 8,65 % des alten Deckels;
  nach dem Neustart peak 93 MB, `oom_kill 0`.

- [ ] **Zwei OOM-Kills am 2026-10-02, einer davon hat die Session gerissen.**
  Live aus `dmesg`:
  ```
  13:11:22  Killed process 362704 (rustc)     anon-rss 977308 kB
  13:21:33  Killed process 36964  (opencode)  anon-rss 427112 kB   ← PID 1
  ```
  Wichtig für die Bewertung: der zweite Kill war **korrektes OOM-Verhalten**,
  kein Fehlgriff. Um 13:21 war der `rustc` aus 13:11 längst tot, `opencode`
  war mit 427 MB schlicht der größte Prozess im cgroup. Die oft wiederholte
  Erzählung „der Kernel killt immer den Falschen" trifft auf *diesen* Kill
  nicht zu — er ist die Begründung dafür, dass `code-dev` den 5-g-Deckel
  braucht, und nicht mehr. **Verworfen: `oom_score_adj = -500` auf PID 1.**
  Zwei Gründe, beide gemessen: (a) der Wert wird an die Kinder vererbt, alle
  wären dann gleich geschützt und die Schutzwirkung entfällt; (b) er braucht
  `CAP_SYS_RESOURCE`, die der Container bewusst nicht hat (`CapEff: 0`). Ein
  Schreibversuch auf `oom_score_adj` scheitert im Container an uid 1000 ohne
  Capability. Der Wächter umgeht beides, weil er Signale statt Capabilities
  nutzt.

- [ ] **34 Zombie-Prozesse unter `opencode serve`, sichtbar nur auf dem HOST.**
  `chrome-headless` und `MainThread` als `<defunct>`, Parent ist `opencode
  serve` (PID 1), älteste 12169 s. Im **Container**-Namespace meldet `ps`
  **0 Zombies** — sie existieren nur im PID-Namespace des Wirts. Ein
  Zombie-Cleanup im Entrypoint ist damit wirkungslos; aufräumen kann nur, wer
  sie erzeugt hat, also opencode selbst bei einem sauberen Neustart.
  Speicher geben sie frei (Zombies sind nur Exit-Status-Einträge), sie kosten
  einen PID-Slot; `pid_max` ist 4194304, aktuell 60 PIDs im Container.
  **Ursache unbekannt** — die chrome-headless-Kinder sind nicht im Log
  identifiziert. Nicht verfolgt.

## 2026-09-29

- [ ] **`--accept-dns=false` sitzt nur an `tailscale up`, nicht am
  `tailscaled`-Aufruf** (2026-09-29, gefunden beim Review der Commits).
  `remote/AGENTS.md` §15.2 formuliert die Regel strenger als der Code es tut:
  `entrypoint.sh` startet `tailscaled --tun=userspace-networking --statedir=…
  --socket=…` **ohne** `--accept-dns=false`; das Flag steht erst an
  `ts up --authkey=… --accept-dns=false`. Im Erstlauf-Fenster — Daemon laeuft,
  `up` folgt Sekunden spaeter — ist die DNS-Vorliebe also noch nicht
  persistiert. **Warum es live nicht auffiel:** der Userspace-Netzstack fasst
  DNS gar nicht an, und `/etc/resolv.conf` blieb unveraendert (Docker-DNS
  `127.0.0.11` hat weiter funktioniert, `opencode serve` startete normal).
  **Offen, weil ungetestet, ob es je auffaellt.** **Zu tun:** das Flag
  zusaetzlich an den `tailscaled`-Aufruf haengen, damit §15.2 wortgleich gilt.
  Einzeiler, aber nicht von mir geaendert — dafuer braucht es eine Messung, die
  `resolv.conf` im Container tatsaechlich beobachtet.
- [ ] **Tailscale-/Tailnet-Weg live noch nicht verifiziert** (2026-09-29, Stand aus
  `remote/AGENTS.md` §15). Der Userspace-Modus und die Erreichbarkeit von
  `code-dev` ueber die Tailnet-IP sind beschrieben, aber noch nicht von einem
  echten Client aus belegt. Zu zeigen: `code-dev` per 100.x-Adresse erreichbar,
  ein lokal gestarteter Dev-Server (`pnpm dev`/`vite`) von Mac/Handy aus sichtbar,
  und dass `/etc/resolv.conf` dabei unveraendert bleibt (§15.2).
- [ ] **Ein Portainer-UI-Deploy schreibt `compose/49/docker-compose.yml` neu —
  die Env ist gepatcht, die Datei steht dort nicht** (2026-09-29).
  Die `TS_*`-Keys sind jetzt in der Portainer-DB und ueberstehen einen
  UI-Deploy. **Die Compose-Datei steht dort aber nicht:** Portainer 2.45.1
  fuehrt fuer diesen Stack **kein** `FileContent` im Datensatz,
  `ProjectPath=/data/compose/49`. Der Web-Editor laedt die Datei von der
  Platte, ein UI-Deploy benutzt sie von dort. **Risiko:** wer im Editor `Save`
  klickt, ohne vorher die aktuelle Datei aus dem Repo-HEAD einzufuegen,
  deployt einen leeren Stack. **Zu tun:** Stack `dev-vm` in der UI nie ohne
  vorheriges Einfuegen von `remote/docker-compose.yml` aus dem HEAD updaten.
  Grund: Portainer haelt die Stack-Env in seiner Datenbank und schreibt
  `stack.env` bei jedem UI-Deploy daraus neu. Ohne den Patch haette der
  naechste Browser-Deploy die `TS_*`-Keys wieder entfernt. **Entscheidung des
  Menschen**, bewusst gegen die Empfehlung, den Stack zunaechst ohne Tailnet zu
  deployen und das spaeter nachzuziehen.
  **Vorher gemessen, nicht geraten** (Portainer 2.45.1, DB 1 MiB, BoltDB):
  - **Bucket-Keys sind 8 Byte Big-Endian, kein ASCII.** `dev-vm` liegt unter
    `00 00 00 00 00 00 00 31`. `Get([]byte("49"))` liefert **nichts** — wer
    so sucht, schliesst faelschlich „Stack nicht gefunden“.
  - **Der Stack-Datensatz hat kein `FileContent`.** Weder 0 Byte noch einen
    leeren String — das Feld fehlt ganz. Die Compose-Datei existiert in der
    DB **nicht** und liegt nur auf der Platte.
  - Datensatz-Felder: `ProjectPath=/data/compose/49`, `EntryPoint=docker-compose.yml`,
    `Type=2`, `EndpointId=3`, `Id=49`, 6 Env-Eintraege.
  **Vorgehen:** Backup `portainer.db.bak-<ts>` → `docker stop portainer` →
  **frisches** Backup des aktuellen Stands (Portainer schreibt im
  5-Minuten-Takt, `SnapshotInterval: 5m`; eine aeltere Kopie haette seine
  letzten Writes zurueckgerollt) → Schreib-Container als root auf dem Volume
  (kein Go auf Mac und VPS, deshalb `golang:1.24-alpine` als Wegwerf-Container)
  → `docker start portainer`.
  **Kontrolle, die wirklich etwas wert ist:** vor **und** nach dem Schreiben je
  ein Fingerabdruck ueber **alle 23 Keys aller uebrigen Buckets** — nach dem
  Patch **identisch**. Der Stack-Datensatz wurde als `map[string]json.RawMessage`
  gelesen und nur der Schluessel `Env` ersetzt, damit jedes andere Feld
  byte-for-byte unangetastet bleibt.
  **Ergebnis:** `Env` 6 → 8 Eintraege; nach dem Portainer-Neustart **noch
  da** (verifiziert an einer Kopie des Post-Startup-Zustands, weil Portainer
  die DB im Betrieb exklusiv sperrt); alle 7 Stacks unveraendert; Datei bleibt
  `0600 root:root`, 1 MiB.
  **Nebenbefund fuer den naechsten, der das macht:** Portainer haelt die DB
  exklusiv gesperrt, ein zweiter Leser bekommt `timeout`. Zum Lesen muss
  Portainer kurz runter und man nimmt eine Kopie. **Und:** `bbolt.Open` mit
  `Timeout` blockiert, nicht bricht ab — ein 10-s-Timeout im eigenen Code
  rettet da nicht, nur ein `db.Close()` vor der naechsten Oeffnung.
- [ ] **Boot-Schutz für den Loop fehlt (offener Single Point of Failure)** —
  `/srv/dev-projects` ist die **einzige** Kopie der Projekte. Faellt der Mount
  beim Boot aus, startet `code-dev` mit leerem `/projects`, und `gh repo clone`
  holt nur den Code zurueck — nicht `node_modules`, `.env`-Fragmente oder
  uncommittete Arbeit. Es gibt **keinen** Check, der das erkennt, bevor der
  Agent auf leerem Bestand arbeitet.
  **Zu entscheiden:** Pruefung in einem systemd-`ExecStartPre` auf `code-dev`
  (`findmnt /srv/dev-projects` als Abbruchbedingung) oder eine Warnung im
  `bootstrap.sh`-Ablauf. **Bewusst nicht erfunden** — der Cutover sollte nicht
  noch eine zweite, ungetestete Aenderung bekommen. Vor der Umsetzung klären,
  was im Fehlerfall passieren soll: Container hart stoppen oder mit leerem
  Bestand laufen lassen (im zweiten Fall ist die Warnung Pflicht, damit der
  Agent sie sieht).
  Geschlossen wird der Punkt erst, wenn ein **Reboot** des VPS gezeigt hat,
  dass der Mount sauber kommt — der bisherige Beweis ist nur `mount -a`.

## 2026-09-26

- [ ] **Host-Dienste im Container nutzbar machen (Publish, nicht Adressierung)** — durch
  `host-gateway` war nur die *Adressseite* gelöst; die ist inzwischen wieder weg (voriger
  Eintrag), sie ist also **nicht** gelöst und soll auch nicht gelöst werden — `code-dev` hat
  bewusst keinen Host-Zugriff. Die konkret scheiternden Ports
  (Meilisearch 7701, Mailpit 8025/1025, 5432/3306, LM Studio 1234, Astro 4321) sind auf dem VPS
  **nicht erreichbar**, weil dort kein Listener existiert: Loopback-Bind bzw. unveröffentlichte
  Ports. `portal_search` hängt mit `7700/tcp` unveröffentlicht in
  `portal-reisinger-pictures_portal_internal`. Nötig sind Publish auf `0.0.0.0` bzw. eine
  Bridge-IP-Bindung plus eine Config ohne harten `localhost`.
  Für den Alltag decken das die drei Regeln in `remote/README.md` das ab (Dev-Server in
  `code-dev`, Wegwerf-Container im DinD per Containername). Dieser Punkt ist damit nur noch
  relevant, wenn es **wirklich** um Prod-Dienste auf dem VPS geht — dann als Publish-
  Entscheidung pro Dienst, nicht als `extra_hosts`.
  - DIND-Falle (nicht live beobachtet, aus Netzraum-Logik): `docker run -p 127.0.0.1:X:Y` im
    Sidecar `code-remote-dind` bindet nur im DIND-Netzraum → von `code-dev` nie erreichbar.
    Solche Test-Container gehören per `--network` in ein geteiltes Netz und werden per
    Containername aufgelöst.
- [ ] **PTY-WebSocket-Upgrade live nachweisen (ezziger Rest aus `df9fe4d`)** — der
  klassische PTY-Pfad ist in Ordnung (`POST /api/pty` → 200, echter `bash -l` in
  `/projects`, Prozess beendet sich ohne TTY von selbst), aber der WebSocket liegt
  nicht dort. Zwei getrennte Systeme, was in den Strings leicht falsch gelesen wird:
  - `pty.*` (klassisch): `GET /api/pty` = Liste, `POST /api/pty` = anlegen,
    `GET /api/pty/{id}`. **Kein** WebSocket.
  - `experimental/persistent-pty`: `GET/POST /api/experimental/persistent-pty`,
    `/{id}`, `/{id}/connect-token`, `/{id}/connect` (das ist der WS-Pfad),
    `/{id}/snapshot`, `/handoff`, `/shutdown`.
  Ein Handshake auf `/{id}/connect` ohne Token liefert `400` — die Anfrage kommt also
  durch Caddy, `forward_auth` und bis zu opencode, es ist aber **kein** `101`.
  Ein echtes `101` braucht den persistent-pty-Lebenszyklus, und der wird
  agentseitig erzeugt (`persistentPty.connect` ist ein Permissions-Name, ein
  `POST` auf die Collection liefert `404`). Deshalb per HTTP nicht erreichbar.
  **Zu tun:** im Browser eine PTY oeffnen, in den DevTools den `101` samt
  `Sec-WebSocket-Accept` am Network-Tab gegen `remote-code` **und** `code` belegen.

- [ ] **Lokaler Tunnel: Supervision im Realbetrieb verifizieren** — `local/bootstrap.sh` richtet
  beim Start alles ein (autossh, bestehender Key `~/.ssh/id_rsa` via macOS-Keychain, LaunchAgent
  `com.code-tunnel` mit `RunAtLoad`+`KeepAlive`+`Umask 077`); `run.sh` gibt die TCP-Verbindung an
  autossh (`ControlMaster=no`) und räumt verwaiste Instanzen auf. Erledigt und verifiziert:
  Key-Umstellung (eine Passphrase-Eingabe, `BatchMode`+`UseKeychain` funktioniert ohne TTY, der
  kurzzeitig erzeugte dedizierte Key ist wieder gelöscht — lokal und in `authorized_keys`),
  Reconnect nach `kill -9` des ssh **mit** `id_rsa`, Neustart nach `kill -9` des `run.sh`
  (launchd in < 3 s), `bootstrap.sh` als No-op ohne Restart. Zwei Review-Runden mit
  DeepSeek 4.1 (Blocker, SOLLTE, KANN) sind eingearbeitet, Abschlussurteil
  "commit-fähig". Dazu am 2026-09-27: der Stopp-/Start-Zyklus über
  `local/stop-tunnel.command` (LaunchAgent gestoppt → `disabled`, dann
  `start-tunnel.command` → `print-disabled` meldet `enabled`, Agent geladen,
  `state = running`, Forward `LISTEN 172.18.0.1:18731`, `opencode serve` zurück auf
  `:8080`). **Offen:** ein echter Sleep/WLAN-Wechsel, ein Reboot (Login-Autostart)
  und der Fall, dass die Login-Keychain nach dem Login gesperrt bleibt (dann
  Restart-Schleife).

## 2026-09-25

## Verworfen

Ansätze, die **bewusst zurückgezogen** wurden. Nicht erneut implementieren —
wenn sich die Voraussetzungen ändern, zuerst neu bewerten.

- **Die 1112 Zombies in `code-dev` per `docker restart code-dev` oder
  `kill -9 2099560` wegräumen** (2026-10-09, vom Agenten angeboten, vom Mensch
  abgelehnt mit „nichts tun, nur dokumentieren"). Begründung: **0 % CPU-Kosten**,
  `pid_max` 4.194.304 → 0,03 % belegt, also kein PID-Engpass; und der Preis war
  real — ein Restart kostet alle offenen Sessions auf Port 8080 (zu diesem
  Zeitpunkt 0 Verbindungen offen, aber das Leck steht in ~11 Std wieder auf
  demselben Stand), waehrend `kill -9` auf den Host-PID 2099560 den Container
  `exited` haengen laesst statt ihn neu zu starten. Nicht erneut anbieten, nur
  weil der Zombie-Zaehler gross aussieht — er ist ein Anzeiger, kein Crash.

- **Loopback-Image in einem Docker-Volume-Pfad mounten** (`3d3a046` vom
  2026-09-26, verworfen mit `c5d3c7b`). Damals
  `- /var/lib/docker/volumes/projects-50g-mnt:/projects`. Der Pfad unter
  `/var/lib/docker/volumes` kann von Docker als verwaist eingestuft und
  wegrationalisiert werden. **Die Lehre gilt fort** — deshalb seit 2026-09-29
  `/srv/dev-projects` als Bind-Mount. Was davon *nicht* ausgeräumt wurde: das
  Dateisystem-im-Dateisystem-Argument, der `fstab`-Zustand und die
  Pfad-Duplizierung zwischen `fstab` und Compose. Siehe `remote/AGENTS.md` §14.

- **50 GB statt 100 GB** (`c5d3c7b`, 2026-09-27). Zurückgedreht, weil der Loop
  in 98 % volllief und das Log-Limit aus `3d3a046` nicht griff — es wuchsen die
  Projekte selbst, nicht die Logs. Am 2026-09-29 mit 100 GB neu eingeführt.

- **`/srv/dev-100g.img` per UUID in `fstab` referenzieren.** Am 2026-09-29 live
  probiert und **gescheitert**: `mount -a` → `failed to setup loop device for
  /dev/loop0`. The UUID existiert erst nach `losetup`; zum Mount-Zeitpunkt
  findet `mount` sie nicht. Korrekt ist der Dateipfad als Quelle. Nicht erneut
  versuchen, das „aufzuräumen“.

- **Root-Dateisystem auf `vda` verkleinern, um Platz zu gewinnen** (2026-09-29,
  vom Menschen vorgeschlagen, vom Agenten live gemessen widerlegt). `vda4` ist
  XFS, und XFS hat keinen Shrink-Pfad; die Partition ist die letzte der
  GPT-Tabelle und trägt das Root-FS, also nicht unmountbar. **LVM löst das
  nicht** — es schichtet Blockdevices, es erzeugt keine Blöcke. Der einzige Weg
