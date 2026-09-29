# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

## 2026-09-29

- [ ] **Tailscale in `code-dev` — live verifizieren** (Code im Repo, VPS noch
  auf dem alten Image). Use case: **lokal in `code-dev` gestartete Dev-Server
  von aussen sehen** (`pnpm dev` o. ae.). `Dockerfile`, `entrypoint.sh`,
  `docker-compose.yml` und `.env.example` sind angepasst; Design und die
  verworfene Alternative stehen in [`remote/TAILSCALE-PLAN.md`](remote/TAILSCALE-PLAN.md),
  Regeln in `remote/AGENTS.md` §15.
  **Warum Userspace und nicht TUN:** `tailscaled --tun=userspace-networking`
  braucht kein `/dev/net/tun` und keine Capabilities. Live verifiziert am
  laufenden `code-dev` (Stand vor der Aenderung):
  ```
  /.dockerenv vorhanden, PID 1 = opencode
  /usr/local/bin/entrypoint.sh, DOCKER_HOST=tcp://dind:2375
  ```
  Ein TUN-Modus haette `cap_add: NET_ADMIN` plus `devices: /dev/net/tun`
  gebraucht — genau die Tür, die §3/§4 geschlossen halten.
  **Gegengeprüft, dass die Isolation hält** (YAML geparst, `code-dev`):
  `cap_add` nein, `devices` nein, `ports` nein, `extra_hosts` nein,
  `network_mode` nein, `privileged` nein.
  **Bekannt und gewollt:** der Tailnet-Weg umgeht Caddy. `forward_auth`,
  `code-auth-remote` und der oeffentliche DNS-Eintrag bleiben unberuehrt;
  `remote-code.<domain>` antwortet nach dem Deploy **weiterhin ohne VPN**. Wer
  das umkehrt erwartet, macht einen Fehltest.
  **Nicht erreichbar vom Tailnet** (anderer Netzraum, §7): `dind` und seine
  Testcontainer, `code-auth-remote:8081`.
  **Entrypoint-Logik getestet, ausserhalb des Containers** — mit Attrappen fuer
  `tailscaled`/`tailscale` (echter Unix-Socket) und der echten, extrahierten
  Funktion. Vier Szenarien, alle mit Rueckgabe 0:
  | Fall | `TS_AUTHKEY` | `BackendState` | Erwartung | Ist |
  |---|---|---|---|---|
  | Erstlauf | gesetzt | `NeedsLogin` | `up` mit Key + Host | wie erwartet |
  | Recreate | gesetzt | `Running` | **kein** `up` | wie erwartet |
  | kein Key | leer | `NoState` | uebersprungen | wie erwartet |
  | `tailscaled` tot | gesetzt | – | Warnung, Start geht weiter | wie erwartet |
  **Falle beim Nachbauen des Tests:** `tailscaled` legt einen Unix-**Socket**
  an, keine Datei. `[ -f ]` oder ein `touch` in der Attrappe schlaegt fehl und
  sieht wie ein Bug im Entrypoint aus. Richtig ist `[ -S ]`.
  **Nebenbefund, mitgefixt:** `/tmp/opencode` (Scratch der Agent-Tools) wurde
  **root:root 755** angelegt, war als uid 1000 also nicht beschreibbar. Das
  Image setzt jetzt `mkdir -p /tmp/opencode && chmod 1777 /tmp/opencode` (1777
  wie `/tmp` selbst, mit Sticky Bit). Per Test-Build verifiziert: uid 1000
  schreibt. **Im laufenden Container einmalig nachgezogen** mit
  `sudo chmod 1777 /tmp/opencode` — bis zum naechsten Image-Build haelt das nur.
  **Zu tun:**
  - Auth-Key (nicht ephemer) + ACL in der Tailscale-Admin-Console.
  - `TS_AUTHKEY`/`TS_TAILSCALE_HOSTNAME` in `remote/.env.production` (gitignored,
    Handarbeit, §1).
  - Image bauen, `IMAGE` setzen, Stack in Portainer neu deployen.
  - Live pruefen: `tailscale status`/`ip -4` im Container, `ss -ltnp` (welche
    Ports ueberhaupt lauschen), von einem Client `curl` auf `100.x.x.x:<port>`.
  - **Gegenproben, die schiefgehen MUESSEN:** `curl` auf `100.x.x.x:2375/_ping`
    (dind) und `100.x.x.x:8081/` (code-auth-remote) darf **nicht** antworten.
  - `remote-code.<domain>` ohne Cookie auf `/api/info` → weiterhin 401, nicht 200.
  - Dev-Server im Tailnet ueber laengere Zeit offen halten (SSE bricht sonst
    gern lautlos) und Tailnet-IP ueber einen Stack-Recreate hinweg vergleichen.
  - Abnahme erst nach unabhaengigem Review der Live-Verifikation.

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
