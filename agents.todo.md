# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

## 2026-10-07

- [x] **`CORS_ORIGIN` war dokumentiert, aber nicht gemappt — der ganze CORS-Pfad
  war ein No-Op.** Commit `62ea52a` hat in `remote/entrypoint.sh` die Logik fuer
  `${CORS_ORIGIN}` -> `--cors` eingebaut und in `remote/docker-compose.yml` nur
  einen Kommentar dazu geschrieben, aber **kein** `- CORS_ORIGIN=...` im
  `environment:`-Block von `code-dev`. **Entscheidung:** `CORS_ORIGIN` =
  `https://ocweb.all-the.rest` (Browser-Origin der PWA). **Fix:** Mapping als
  Zeile im `environment:`-Block ergaenzt, direkt nach `TS_TAILSCALE_HOSTNAME`,
  **ohne** Default-Logik in Compose — leerer Wert bleibt harmlos, der Entrypoint
  behandelt leer als „kein `--cors`" (`if [ -n "${CORS_ORIGIN:-}" ]`).
  **Live verifiziert, warum es vorher wirkungslos war:** `stack.env` liefert nur
  Interpolationswerte fuer `${...}`, es erzeugt **kein** Container-Env — ohne
  Mapping sieht der Container die Variable nie. Geprueft: kein CORS-Eintrag in
  der laufenden Compose-Datei, `CORS_ORIGIN` nicht im Container-Env.
  Regel dazu: `remote/AGENTS.md` §18.

- [x] **Erledigt 2026-10-07:** `CORS_ORIGIN` in `stack.env` und in
  `remote/.env.production` eingetragen (Backup `stack.env.bak-cors-*`).
- [ ] Portainer-DB-Patch nach `remote/AGENTS.md` §9 **Fall 1** (neuer Env-Key,
  der per SSH-Deploy kam), Schema §17.4 — sonst schreibt der naechste UI-Deploy
  den Key wieder weg. (`.env.production` ist bereits mitgezogen.)
- [x] **Deployed und verifiziert 2026-10-07:** `--no-deps code-dev`-Recreate,
  Log `CORS: erlaube Origin https://ocweb.all-the.rest`, `--cors` aktiv,
  Image-Revision `62ea52a`, `/api/info` 200, Sidecars unberuehrt.
- [ ] **Drift VPS vs. Repo bei den RAM-Limits (gefunden 2026-10-07).** Live:
  code-dev 7g/12g, dind 1g/2g (Stand 2026-10-04). Repo (`remote/docker-compose.yml`,
  `remote/.env.production`): 5g/9g, 2g/4g. Die VPS-Datei wurde am Diff belegt,
  nicht geraten. Zu entscheiden: Live-Werte ins Repo uebernehmen oder VPS auf
  Repo zuruecksetzen — bis dahin keine der beiden Dateien „angleichen".

- [ ] **Blanket-OPTIONS im Caddy-Fragment vor dem Catch-all** (beide Wege).
  **Eingetragen, `caddy validate` ✅ (Docker, `caddy:2` via `caddyfile/sync.sh:11`,
  „Valid configuration") — offen bleiben Deploy via `sync.sh` und der
  Platzhalter-grep auf dem VPS.** Der Block ist in beiden Fragmenten und beiden
  Site-Bloecken der globalen Caddyfile geschrieben, live ist er noch nicht.
  **Warum, gemessen (Pre-Deploy-Baseline, Live-Stand 2026-10-07):**
  `curl -sSI -X OPTIONS -H 'Origin: https://ocweb.all-the.rest' -H
  'Access-Control-Request-Method: POST' https://remote-code.all-the.rest/api/info
  | grep -iE 'HTTP/|access-control'` → **`HTTP/2 302`, `location: /login.html`,
  kein `Access-Control-Allow-Origin`.** Derselbe Pfad ohne `-X OPTIONS` →
  ebenfalls `302`, die 302 ist also der `forward_auth`-Redirect und nicht etwas
  an OPTIONS. Ein Preflight traegt nie Cookies, also sieht `forward_auth` nichts,
  macht 302, und der Browser bricht ab. ACAO an echten Responses **soll**
  separat aus `opencode serve --cors` kommen (`local/run.sh`,
  `remote/entrypoint.sh`) — das ist **unbelegt**, belegt sind nur die
  Preflight-Baseline oben und das Flag-Parsing im Entrypoint; es kommt nicht
  aus dem Caddy-Block. **Regel:** `remote/AGENTS.md` §19 (Grenzen: die
  pfadspezifischen Handles `/login.html`, `/api/login|me|logout` + `/sw.js`
  stehen davor, weil der Pfad-Sub-Sort (`sortRoutes`) nur greift, wenn BEIDE
  Routen genau einen Single-Path-Matcher haben — `@options` matcht per
  `method`, der stabile Sort behaelt also die Quellreihenfolge. Ihr OPTIONS
  trifft den Block nie und kommt ohne CORS-Header: `501` nur auf
  `/api/login|me|logout` (Sidecar ohne `do_OPTIONS`), auf `/sw.js` der
  site-eigene `respond 200`, auf `/login.html` der `file_server`. Das Blanket
  maskiert ausserdem kuenftige eigene OPTIONS-Endpunkte).
- [ ] **`Access-Control-Allow-Origin`/`-Allow-Credentials` auf der echten
  authentifizierten Response ist unbewiesen.** Der 302-Preflight ist gemessen,
  die Header einer eingeloggten Response nicht — braucht eine Session
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

- [ ] **Host-Budget ist rechnerisch weiterhin überzeichnet.** Nach der
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

- [x] **RAM-Wächter implementiert und verifiziert** (2026-10-02). Siehe oben,
  Eintrag „RAM-Wächter ist im Repo, aber noch nicht ausgerollt" für den
  offenen Rollout und die offene Druck-Frage.

## 2026-09-29

- [x] **`code-dev` restartete unregelmaessig — Ursache war der RAM-Deckel, nicht
  die VM** (2026-09-29). Ausgangsfrage: „warum restartet die code-vm immer
  wieder". **Erste Feststellung: es gibt keine VM.** `code-vm` ist der
  Compose-Stack `dev-vm` (in Portainer `code-remote`), Container `code-dev`.
  `virsh`/`libvirt`/`systemd-nspawn` existieren auf dem Host nicht.
  **Drei unabhaengige Restart-Ursachen, alle by design:**
  1. **cgroup-OOM-Kills (die unregelmaessigen, hier behoben).** 8 in 24 h, alle
     in `code-dev`, kein anderer Container auffaellig (15 OOM-Events im
     laufenden Kernel-Boot: 13 `code-dev`, 2 `code-remote-dind`). Ausloeser
     jedes Mal `cargo build`: parallele `rustc` mit 220–920 MB pro Instanz bei
     3 Cores. Der Kernel killt den **groessten** Prozess im cgroup — das ist
     nicht der schuldige `rustc`, sondern `opencode serve`, und der laeuft als
     **PID 1**. PID 1 stirbt = Container stirbt = `restart: unless-stopped` =
     Sitzung weg. Opfer-Bilanz an einem Tag: 3x rustc, aber 5x PID 1. Genau
     deshalb „nicht regelmaessig": es hing nur daran, OB gerade Rust
     kompiliert wurde. Idle 700 MB, `memory.peak` 1558 MB — 2 GB waren knapp.
  2. **Watchtower recreated `code-dev`**, weil der `:latest`-Tag von
     `opencode-web-dev-baseline` ~taeglich (teils 3x am selben Tag) einen neuen
     Digest bekommt. Live beobachtet am 29.09.: 11:19, 12:19, 13:19, jeweils
     `Stopping /code-dev (SIGTERM)` → `Creating /code-dev`. Watchtower laeuft
     mit `POLL_INTERVAL=3600` und **ohne Label-Filter**.
  3. **Der In-Container-Auto-Updater** (`OPENCODE_AUTOUPDATE=true`, alle 20 min,
     Fenster 07–23 Uhr) killt PID 1 per `kill -TERM 1`, wenn ein Update
     anliegt und der Server idle ist. Seltenster der drei Pfade.
  **Umgesetzt, in drei Etappen — die ersten beiden haben sich als Fehler
  erwiesen und sind hier festgehalten, weil beide plausibel aussahen:**
  1. **`memory.max` direkt ins laufende cgroup geschrieben** (3 GiB), weil
     zwei Sessions aktiv waren. **Das war falsch.** Bei jedem `docker restart`
     wendet Docker die `HostConfig`-Limits erneut an und ueberschreibt den
     Direktwert. Im Test haben **drei Restarts in 90 Minuten** das Limit
     zurueckgesetzt, der OOM-Killer feuerte weiter, waehrend `memory.max`
     korrekt aussah. **Ein direkt geschriebenes `memory.max` gilt bis zum
     naechsten *Restart*, nicht bis zum naechsten Recreate.** Nur die
     Compose-Datei wirkt dauerhaft.
  2. **Recreate mit 3g/6g** — hat funktioniert, aber nur knapp: 0 OOM-Kills,
     `memory.peak` = 3221229568 bei `memory.max` = 3221225472, `memory.current`
     bei 86 %. Peak auf der Decel = beruehrt, gerettet nur durch Reclaimen.
     **Null Kills ist kein Beweis fuer einen passenden Deckel.**
  3. **Final: 4g/8g** (RAM + Swap gesamt), dind 2,5g/5g. Recreated, weil keine
     Session aktiv war. Backups auf dem VPS: `*.bak-memlimit-*`,
     `*.bak-dindlimit-*`, `*.bak-cd4g-*`.
  **Merksatz zum Pruefen kuenftiger Deckel: `anon` messen, nicht
  `memory.current` und nicht `memory.peak`.** Erste Fassung dieser Notiz
  empfahl `memory.peak` gegen `memory.max` — das ist **unvollstaendig und
  fuehrt in die Irre**, siehe naechsten Punkt.
  **Die 4 GB machen den Host zur knappsten Stelle:** code-dev 4g + dind 2,5g
  + Portal ~0,5g + OS ~0,7g = ~7,7 GB bei 7,5 GB. Erreichen beide Dev-Container
  ihre Deckeln gleichzeitig (Normalfall: cargo in code-dev, docker im Daemon),
  feuert der **Host**-OOM-Killer und der nimmt global den groessten Prozess —
  `mariadbd`. Ein Dev-Build als Produktionsausfall. Bewusst so entschieden
  (Entscheidung des Menschen), **ohne** dind zu senken. Rueckschranke: dind auf
  2g, dann ~0,3-0,5 GB Luft.
  **Korrektur der eigenen Messregel (2026-09-29, 16:36).** Beim
  Stabilitaets-Check wurde `memory.current` = 95 % vom 4-GB-Deckel gemeldet und
  daraus "nicht stabil" geschlossen. **Falsch.** `memory.current` enthaelt den
  reclaimbaren File-Cache. Die Aufteilung:
    reclaimbarer File-Cache  2821 MB (69 %)  <- Playwright/Vite aus node_modules
    anon (echter Heap)        929 MB (23 %)
    slab_unreclaimable          5 MB
    pagetables+shmem+slab_rec   45 MB
  OOM-relevant sind nur `anon` + `slab_unreclaimable` = **934 MB von 4096 MB**.
  Der Kernel hat 2,8 GB Cache recycled statt zu killen, `oom_kill 0` war korrekt.
  Fuer echte Allokation waren 3,1 GB frei. `memory.peak > memory.max` ist in so
  einem Zustand **kein** Alarm, weil `peak` den Cache mitzaehlt.
  **Regel: `memory.current` hoch heisst nichts, `peak > max` heisst nichts.
  Nur `anon` gegen das Deckel sagt etwas ueber OOM-Risiko.** In `AGENTS.md` §9
  und README korrigiert, mit Messbefehl.
  **Prod-Container (`portal_db`, `portal_search`, `caddy`, `portal_backend`)
  bewusst ohne Limit gelassen** (Entscheidung des Menschen): keines hatte je
  ein OOM, und ein zu knapper Deckel auf MariaDB waere ein Produktionsausfall.
  `MEMORY_LIMIT`/`MEMSWAP_LIMIT` sind in `stack.env` **nicht** gesetzt, es
  greifen also die Defaults aus der Compose-Datei — deshalb genuegt die
  Datei-Aenderung, ein Portainer-DB-Patch ist nicht noetig (die DB haelt nur die
  Env, siehe §17). `remote/README.md` und `remote/AGENTS.md` §9 nachgezogen.
    **Nebenbefund, und eine Falschangabe darin (2026-09-30 korrigiert):** Ich
    notierte, das Swap-Sicherheitsnetz habe „nie gegriffen" wegen
    `vm.swappiness=0`. **Das war eine Verwechslung von zwei Sysctls:**
    `vm.swappiness` ist **10** (persistiert in `/etc/sysctl.conf`, mtime
    April), der gemessene `0` war `vm.overcommit_memory`. Die Beobachtung
    (`memory.swap.current` = 0 waehrend OOM) war echt, die Erklaerung nicht —
    es war schlicht kein Swap noetig in dem Moment. Gegengeprueft am
    2026-09-30: **597 MB von 4096 MB Swap genutzt**, der Deckel greift also.
    **Diese falsche Diagnose stand zwei Tage in AGENTS.md, README und Compose
    und ist jetzt in allen drei berichtigt.** Auswirkung auf die Groessenordnung:
    4g/8g war ein 8-GB-Gesamtbudget, kein 4-GB-Deckel mit Zierdekel.
    **Portainer-DB gepatcht, damit die Werte in der UI sichtbar sind** (2026-09-30,
    Fall 2 in `remote/AGENTS.md` §17.4): `MEMORY_LIMIT=5g` und
    `MEMSWAP_LIMIT=9g` lagen nur als Compose-Defaults vor und waren in der UI
    nicht zu sehen. Nach dem dokumentierten Verfahren: zwei Backups
    (`portainer.db.bak-prepatch-`, `.bak-current-20260930-160451`), Portainer
    gestoppt, nur das Feld `Env` ersetzt, Fingerprint ueber **alle** Buckets
    vorher/nachher — `5309c01c31f41d1bd3276a60` == `5309c01c31f41d1bd3276a60`,
    also ausschliesslich `Env` beruehrt. Live verifiziert: 10 Keys, `AUTH_HASH`
    unveraendert 63 Zeichen (die `$$`-Form aus §2).
    **Und der vierte Schritt, der sonst gefehlt haette:** `.env.production`
    mitgezogen, weil sie die Paste-Vorlage ist — Keys nur in der DB waeren beim
    naechsten UI-Paste wieder weg gewesen. `.env.example` ebenfalls von 4g auf
    5g/9g nachgezogen (dort stand noch `MEMORY_LIMIT=4g`).
    **Zwei Dinge am Weg, die beide in §17 jetzt stehen:**
    `golang:1.24-alpine` braucht `go mod init` vor `go get`, sonst bricht der
    §17-Befehl ab und man haelt den Patch fuer misslungen. Und mein erster
    Fingerprint war falsch konstruiert — er hashte den kompletten
    stacks-Record und meldete dadurch auch den legitimen Env-Change als
    Abweichung. Richtig: `Env` aus dem Record entfernen, **dann** hashten. Ein
    Fingerprint, der jeden gewollten Change als Abweichung meldet, wird
    ignoriert — das ist gefaehrlicher als keiner.
    **Nicht gepatcht (bewusst):** `CPU_CORES` und die `OPENCODE_UPDATE_*` bleiben
    Compose-Defaults. Die braucht niemand in der UI, und jeder Key in der DB ist
    eine zweite Wahrheit, die still schlagen kann.
    **Watchtower fuer dieses Image ausgenommen** (Entscheidung des Menschen,
    umgesetzt 2026-09-30): `com.centurylinklabs.watchtower.enable=false` am
    code-dev-Service. Grund: **23 Recreates** in 6 Tagen, 1-3 pro Tag, weil der
    `:latest`-Digest des Baseline-Images taeglich neu gebaut wird — und jedes
    Recreate beendet die laufende Sitzung. Die anderen Container bleiben
    weiterhin von watchtower erfasst.
- [x] **Tailscale in `code-dev` — live verifiziert und deployed** (2026-09-29).
  Use case: **lokal in `code-dev` gestartete Dev-Server von aussen sehen**
  (`pnpm dev` o. ae.). Code stand schon im Repo (Commits `21fbb1d`,
  `5103bfd`, `4d2fe3a`), der VPS lief noch auf dem alten Image. Jetzt live.
  **Live-Befund (alle Messungen vom 2026-09-29, 12:28–12:31 CEST):**
  - Deploy **`--no-deps code-dev`** statt vollem `up -d`. Grund gemessen: der
    Diff der Compose-Datei enthielt **genau vier** inhaltliche Zeilen
    (`TS_AUTHKEY`, `TS_TAILSCALE_HOSTNAME`, Volume-Mount, Volume-Deklaration),
    `code-auth-remote` und `dind` waren unveraendert. Ein volles `up -d` haette
    `code-auth-remote` recreated — und **dann** waere die `$$`-Falle aus §2
    scharf geworden, weil `docker compose --env-file` `$$` *nicht* unescaped.
    `code-auth-remote` nicht angefasst (Started 27.09., restarts=0), beide
    Sidecars weiterhin `$2a$14$…`.
  - `org.opencontainers.image.revision` des laufenden Containers =
    `4d2fe3a56c…` (HEAD), `tailscaled` v1.102.4 laeuft. **Kein Image-Neubau
    noetig** — das CI-Image enthielt alles.
  - Volume `dev-vm_tailscale-state` wurde beim Deploy angelegt, gemountet auf
    `/home/dev/.local/share/tailscale`, Eigentuemer `dev:dev` (Chown-Liste
    greift), State liegt in `…/state`.
  - Entrypoint-Log: `git: Identitaet global gesetzt`, `git: push-Credentials
    via gh-Token`, `gh auth: ok (reisi007)`, `tailscale: erstmalige Anmeldung
    mit TS_AUTHKEY`, `angemeldet als code-dev`, `IP 100.110.99.127`.
  - **Tailnet-Weg funktioniert:** vom Mac `curl http://100.110.99.127:8080/` →
    **200**; `/api/info` → **401** (Caddy nicht beteiligt, wie erwartet).
    Mac-Client war im Tailnet angemeldet (`BackendState: Running`); Gerätename
    bewusst nicht festgehalten, der trägt zur Messung nichts bei.
  - **Gegenproben, die schiefgehen MUSSTEN, und es taten:**
    `100.110.99.127:2375/_ping` → `000`, `100.110.99.127:8081/` → `000`.
    dind und code-auth-remote haengen weiter an `172.24.0.2/3`.
  - `code-dev`: `health=healthy`, `restarts=0`, `oom=false`.
  - **Portainer-DB gepatcht** (eigener Punkt unten) — die `TS_*`-Keys
    ueberstehen jetzt einen spaeteren UI-Deploy.
  **Praezisierung, die beim Messen auffiel:** der oeffentliche Weg antwortet
  ohne Cookie auf `/api/info` mit **302 auf `/login.html`**, nicht mit 401.
  **401** liefert `/api/me` — das ist die Aussage, die in §5 und in
  `remote/AGENTS.md` §13 gemeint ist. Beides heisst „nicht authentifiziert“,
  die Form ist aber verschieden. Kein Defekt, nur praeziser formuliert.
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
- [x] **Portainer-DB `dev-vm` um `TS_*` gepatcht** (2026-09-29, 12:30).
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

- [x] **`/projects` auf einen 100-GB-Loopback (ext4) umgestellt** (2026-09-29).
  **Entscheidung des Menschen, ausdrücklich gegen die Empfehlung des Agenten.**
  Der Agent hatte zuvor gemessen, dass eine 100-GB-**Partition** nicht moeglich
  ist (`parted print free` → 0,00 GiB frei, `vda4` = XFS = nicht schrumpfbar,
  letzte GPT-Partition mit Root-FS), und dass der Platzbedarf die Massnahme
  nicht begruendet (238 GB frei, 31 GB Projekte). Der Loop wurde trotzdem
  gewaehlt — **als Deckel, nicht als Plattenersatz**.
  **Live verifiziert:**
  - `truncate -s 100G` → 100 GiB apparent, anfangs 518 MB belegt (sparse)
  - `mkfs.ext4 -m 0 -L devprojects` → 26.214.400 × 4096 B, `resize_inode` gesetzt
  - Nutzbar 97,87 GiB (ext4 rechnet 2,13 GiB Journal + Inode-Tabellen ab)
  - `fstab` mit `loop,defaults,noatime`; `umount && mount -a` zweimal
    durchgefuehrt, beide Male sauber
  - `rsync -a` 188.352 Eintraege in 2m39s; `rsync --dry-run --itemize-changes`
    meldet **null** Unterschiede; Dateizahlen als root in Quelle und Ziel
    identisch (162.254 / 21.979 / 4.118)
  - Deploy ueber Portainer-Compose-Verzeichnis (Stack `dev-vm`, `compose/49`),
    vorher Byte-Vergleich: Portainer-Kopie war identisch mit Repo HEAD, also
    **kein** Drift. Backup `docker-compose.yml.bak-loopmount-20260929-100040`
  - Nach Deploy: alle drei Container `healthy`, `restarts=0`, `oom=false`,
    `/api/info` intern 200, `/api/me` auf **beiden** Domains 401 (ohne Cookie =
    korrekt), DinD `/_ping` 200, `DockerRootDir` im Volume (Regel §6 erfuellt)
  - `code-dev` **und** `dind` sehen denselben Mount (`bind /srv/dev-projects`),
    beide melden 162.251 Dateien fuer uid 1000
  - Altvolumen `dev-vm_code-remote-projects` erst **nach** Verifikation
    entfernt: 95 GB → 65 GB belegt, 205 GB → 235 GB frei
  **Ehrliche Bilanz:** netto **+4 GB** Belegung, kein Platzgewinn. Der Nutzen
  ist der Deckel — 97,87 GiB, die `rm -rf` nicht sprengen kann, und die den
  Prod-Stack (Caddy, MariaDB, 10 Container) nicht mehr mitreißen.
  **Ein Detail, das beim Umstieg real war:** `fstab`-Quelle muss die **Datei**
  sein, nicht die UUID — die UUID haengt am Loop-Device, das erst durch
  `losetup` entsteht. Mit UUID getestet und live gescheitert:
  `failed to setup loop device for /dev/loop0`. Ferner: der Mountpoint braucht
  `1000:1000`, sonst kann uid 1000 (`dev`) auf einem root-`755`-Mountpoint
  nicht schreiben — der Fehler faellt erst beim ersten Schreibversuch auf.
  Regelwerk dazu: `remote/AGENTS.md` §14, Messwerte: `remote/README.md`
  Abschnitt „100-GB-Loopback fuer `/projects`".
  **Nicht im pCloud-Backup, gewollt:** `volume-backup.sh` arbeitet mit einer
  Allowlist (4 Volumes + 4 Quellverzeichnisse) und listet `dev-vm_*` explizit
  als ausgeschlossen. `/srv` ist in keiner Quelle enthalten. **Nicht auf eine
  breite `/var/lib/docker`-Quelle umbauen**, sonst landen die 100 GB im pCloud.
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

- [x] **Stack `code-remote`: `host.docker.internal` — eingeführt, dann wieder entfernt** (2026-09-26).
  Zwei Commits an derselben Sache, in dieser Reihenfolge: `24c8854` („Host-Zugriff im remote
  Container") hat `extra_hosts: "${HOST_GATEWAY:-host.docker.internal}:host-gateway"`
  eingeführt, `e5185dd` („Isolation schliessen") hat es wieder entfernt. **Der Ist-Zustand ist
  `ExtraHosts=[]`** — dieser Eintrag beschreibt also einen überholten Zwischenstand, nicht den
  laufenden Stack.
  Damals verifiziert, als es drin war: `docker inspect code-dev --format
  '{{json .HostConfig.ExtraHosts}}'` → `["host.docker.internal:host-gateway"]`, `getent hosts`
  liefert `172.17.0.1`, `/etc/hosts` enthält den Eintrag, `http://host.docker.internal:8000/`
  → `404` (Host-Port auf `0.0.0.0`) bei `http://127.0.0.1:8000/` → `000` als Gegenprobe.
  **Korrektur der Doku (gilt weiter):** `host-gateway` liefert die Docker-Host-IP
  (`172.17.0.1` = `docker0`), **nicht** das Gateway des eigenen Netzes (`code-remote` =
  `172.24.0.1`, `code-dev` = `172.24.0.3`). Beides ist der Host und funktional gleichwertig.
  **Warum wieder entfernt:** die Adressseite war nie das Problem — `extra_hosts` repariert
  `127.0.0.1` nicht, es öffnet nur eine Tür zum ganzen VPS (Portainer-UI 8000
  unverschlüsselt erreichbar, API 9443). Heute verifiziert: `host.docker.internal` löst im
  Container nicht auf, `http://host.docker.internal:8000/` → `000`. `HOST_GATEWAY` ist
  deshalb aus `.env.production` und `.env.example` entfernt. Details:
  `remote/README.md` „Warum es kein `extra_hosts` gibt", `remote/AGENTS.md` §3.
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
- [ ] **PTY-WebSocket-Upgrade live nachweisen (einziger Rest aus `df9fe4d`)** — der
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
- [x] **`local/sync.sh` von rclone auf rsync/ssh migriert** (2026-09-27).
  Auslöser war nicht ein Fehler im Sync, sondern eine falsche Diagnose von mir:
  der `start-tunnel.command` meldete `knownhosts: key mismatch`, und ich habe
  daraus einen offenen SFTPGo-Host-Key-Punkt gemacht. **Die Ursache ist banal:
  dieses Repo war beim Wechsel der anderen Repos (2026-09-26) nicht mitgezogen
  worden.** `rclone` lief weiter auf `RCLONE_REMOTE=reisinger.pictures` /
  `RCLONE_PATH=/code.all-the.rest` aus `.env`, und der SFTPGo-Weg (Port 2222,
  User `webadmin`) ist genau der, dessen Keys inzwischen rotiert sind — die
  Key-Meldung war das Symptom eines Wegs, den es nicht mehr geben soll.
  **Neu:** `rsync/ssh` auf `root@` Port 22, identisch zu `all-the.rest/sync.sh`
  und `portal.reisinger.pictures/sync.sh` (Hintergrund: `strato-vps/README.md`),
  inklusive GNU-rsync-Guard, `--chown=1002:webgroup --chmod=D2777,F666` und
  eigenem Master-Socket `/tmp/ssh-sync-*`. `RCLONE_*` ist aus `.env` und
  `.env.example` raus, `setup.sh` prüft statt `rclone listremotes` das
  Sync-Zielverzeichnis per SSH. `run.sh` hatte zwei tote rclone-Variablen
  (`REMOTE_PATH`, `DIST`) — entfernt.
  **Verifiziert:** `--dry-run` zeigt `xfr#0, to-chk=0/3` (Ziel identisch), ein
  erzwungener Diff liefert `xfr#1` (1.200 B) gegen das echte Ziel, die Datei
  ist danach md5-identisch zum Repo (Backup/Restore). Das neue
  **`--delete`-Sicherheitsnetz** (Abbruch, wenn im Ziel etwas nicht `*.html`
  liegt) wurde gegen ein Wegwerf-Verzeichnis auf dem VPS getestet: Exit 1,
  `fremd.txt` unangetastet. `setup.sh` meldet „Sync-Ziel ok".
  **Bewusst nicht angefasst:** die `rclone`-Erwähnungen in
  [`remote/AGENTS.md`](remote/AGENTS.md), [`remote/README.md`](remote/README.md)
  und `remote/docker-compose.yml` — die beschreiben, was im **Backup-Volume auf
  dem VPS** liegt, nicht den Publish-Weg. Das ist eine andere Frage und gehört
  nicht in diesen Commit.
  **Rest:** die veralteten `[reisinger.pictures]:2222`-Einträge in
  `~/.ssh/known_hosts` sind unbenutzt, aber nicht bereinigt. Nur entfernen, wenn
  klar ist, dass SFTPGo dort nicht mehr genutzt wird — die Fingerprints sind
  die eines fremden Dienstes.
- [ ] **`pkill`-Stall in `run.sh` blockiert den Tunnel-Start** (Beobachtung
  2026-09-27, **nicht reproduziert**). `run.sh:221` (`pkill -f -- "ssh .*-R BIND:REMOTE
  …$TARGET\$"`) lief beim ersten Start nach dem Stopp **2,5–3 min** mit `STAT R`
  (PID 4544) fest: Log nach "Starte OpenCode-Web" ohne weiteren Zeile, bis der
  `pkill` durch war; danach erst `Tunnel:`/`Modus: autossh` (15:28:2x, also
  **3,5 min nach `run.sh start` 15:24:51**), und `bootstrap.sh` meldete zu Recht
  "Forward nach 60 s nicht auf dem VPS sichtbar". Danach steht der Forward
  (`LISTEN 172.18.0.1:18731`).
  **Kein inherenter `pkill`-Effekt:** dieselbe Musterform gegen einen unbenutzten
  Port lief zweimal in **0 s** (Exit 1, kein Treffer). Der Scan über 927 Prozesse
  ist also nicht das Problem — was es blockiert hat, ist offen.
  **Warum das trotzdem zählt:** `run.sh` hat an dieser Stelle kein Timeout, und
  `KeepAlive` hilft nicht, weil `run.sh` nicht *beendet*, sondern *haengt* —
  `launchctl` meldet den Job als `running`, während nichts geforwardet wird. In
  diesem Zustand ist die Domain minutenlang tot und der einzige sichtbare
  Hinweis ist die 60-s-Warnung aus `bootstrap.sh`.
  **Zu entscheiden:** Timeout um die Bereinigung (mit klarer Logzeile, falls sie
  fehlschlaegt) oder ersetzen durch `ps -eo pid=,args=` + awk + explizite PIDs,
  wie in [`local/AGENTS.md`](local/AGENTS.md) §4 schon für die opencode-Prozesse
  vorgegeben. Beides ist eine Eingriffsstelle, an der laut §2 schon einmal etwas
  kaputt ging — deshalb hier festgehalten und nicht von mir geändert.

## 2026-09-25

- [x] **Live-Deploy von `df9fe4d`** — erledigt und am 2026-09-27 live nachgemessen
  (Review durch den Menschen, nicht durch einen Agenten):
  - Image `ghcr.io/reisi007/opencode-web-dev-baseline:latest` laeuft in `code-dev`
    (Container neu erstellt 26.09. 20:14Z, `healthy`).
  - `code-auth-remote`: laufendes `/app/auth.py` ist **byte-identisch** mit dem in
    `remote/docker-compose.yml` eingebetteten Skript (sha b024197fab2cf8ed).
  - `code-auth`: laufendes `/app/auth.py` ist **byte-identisch** mit
    `local/docker-compose.yml` (eigenes Skript, `server_version = code-auth/1.1`).
    Die `Content-Length`-Validierung ist damit ebenfalls live.
  - Beide Caddyfile-Fragmente sind in der globalen Caddyfile uebernommen und der
    **laufende** Caddy traegt pro Block das passende injizierte Basic (Admin-API
    `/config/` geprueft, nicht nur die Datei auf Platte) sowie
    `health_headers { Authorization … }`.
  - Login synchron: `AUTH_USER`/`AUTH_HASH`/`AUTH_SECRET` in lokaler `.env`,
    `code-auth` und `code-auth-remote` identisch; `/api/me` liefert auf
    `code.all-the.rest` und `remote-code.all-the.rest` `{"user":"admin"}`.
  - SSE `/api/event` auf **beiden** Domains: `200`, `content-type: text/event-stream`,
    `server.connected` empfangen (`cache-control: no-cache, no-transform`).
  - API-Request nach Leerlauf: `code-dev` laeuft seit > 11 h, `/api/info` und
    `/api/pty` liefern 200.
  - **Nicht** nachgewiesen: der PTY-WebSocket-Upgrade. Siehe separater Punkt
    unten — der ist der einzige Rest aus dieser Liste.
  - Review-Hinweis: der `Content-Length`-Vergleich oben ist der stichhaltige
    Nachweis fuer beide Sidecars; reines `docker ps` haette "healthy" gezeigt,
    ohne dass ein Deploy der geaenderten Datei stattgefunden haette.

## Verworfen

Ansätze, die **bewusst zurückgezogen** wurden. Nicht erneut implementieren —
wenn sich die Voraussetzungen ändern, zuerst neu bewerten.

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
  /dev/loop0`. Die UUID existiert erst nach `losetup`; zum Mount-Zeitpunkt
  findet `mount` sie nicht. Korrekt ist der Dateipfad als Quelle. Nicht erneut
  versuchen, das „aufzuräumen“.
- **Root-Dateisystem auf `vda` verkleinern, um Platz zu gewinnen** (2026-09-29,
  vom Menschen vorgeschlagen, vom Agenten live gemessen widerlegt). `vda4` ist
  XFS, und XFS hat keinen Shrink-Pfad; die Partition ist die letzte der
  GPT-Tabelle und trägt das Root-FS, also nicht unmountbar. **LVM löst das
  nicht** — es schichtet Blockdevices, es erzeugt keine Blöcke. Der einzige Weg
  zu echtem, physisch getrenntem Platz ist eine zweite Cloud-Volume. Nicht
  erneut versuchen, LVM in die bestehende Platte zu „pressen“.
- **Das neue Dateisystem unter `/var/lib/docker` mounten, um Prod mitzunehmen**
  (2026-09-29, verworfen vor der Umsetzung). Verstoß gegen den
  Isolationsgeden des Stacks: `dev-vm_code-remote-projects`,
  `proxy-stack_*`, `portal-reisinger-pictures_*` und `portainer_data` liegen
  alle unter `/var/lib/docker/volumes` — ein Mountpoint dort hätte Caddy,
  MariaDB, Meilisearch und Portainer mitgezogen. Richtig ist der Bind-Mount auf
  `/srv` für **nur** `/projects`.
