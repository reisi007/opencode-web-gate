# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

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
