# Lokaler Weg (Mac via SSH-Tunnel)

OpenCode läuft auf deinem Mac (`opencode serve :8080`), der VPS stellt nur Login + Reverse-Proxy. Domain: `CODE_DOMAIN` aus `.env`.

```
Browser -> CODE_DOMAIN (zentrales Caddy)
  /login.html, /api/* -> statisch / Sidecar code-auth:8081
  / (Rest) -> forward_auth code-auth:8081 (/check) -> 172.18.0.1:18731 (Tunnel -> Mac :8080)
  401 -> 302 /login.html (nie Browser-Popup)
```

## Dateien

| Datei | Zweck |
|---|---|
| `start-tunnel.command` | Doppelklick-Start am Mac → ruft `bootstrap.sh` auf, Fenster kann zu |
| `bootstrap.sh` | einmalig/bei jedem Start: autossh, SSH-Key, LaunchAgent, Sync |
| `run.sh` | OpenCode-Autostart + rclone-Sync + Tunnel (`--sync-only` / `--tunnel-only`) |
| `diagnose.sh` | Checks lokal + VPS (`--quick` nur lokal) |
| `sync.sh` | Login-Seite (`apps/web/dist`) per rclone auf VPS |
| `scripts/com.code-tunnel.plist` | LaunchAgent-**Vorlage** (Pfade rendert `bootstrap.sh`) |
| `apps/web/dist/` | Login- + Offline-Seite |
| `docker-compose.yml` | Portainer-Stack `code-auth` (Single File, ext. `webnet`) |
| `Caddyfile.fragment` | Vorlage für globale Caddyfile (Platzhalter!) |

## Ablauf

```bash
./start-tunnel.command   # = Doppelklick: Setup + Tunnel, Fenster danach schließen
./run.sh                 # direkt im Vordergrund (Debug, Fenster offen lassen)
./diagnose.sh            # --quick nur lokal
```

### Autostart & Watchdog (der Grund, warum der Tunnel früher "weg" war)

`start-tunnel.command` → `bootstrap.sh` richtet **beim Start** einmalig ein und ist danach no-op:

1. **autossh** nachinstallieren, falls fehlt (`brew install autossh`).
2. **Bestehender SSH-Key** (`SSH_IDENTITY`, sonst `~/.ssh/id_ed25519` bzw. `~/.ssh/id_rsa`) wird
   für den unbeaufsichtigten Betrieb nutzbar gemacht: Passphrase **einmalig** in die
   macOS-Keychain (`ssh-add --apple-use-keychain`), Public Key in die `authorized_keys` des
   Login-Users auf dem VPS (`~` des SSH-Users, hier `root`). `ssh -o UseKeychain=yes`
   entsperrt den Key dann auch ohne TTY — sonst kann launchd den Tunnel nicht starten.
   `SSH_IDENTITY` + `SSH_KEY_AUTH=1` landen dadurch in `.env`. Ist der Public Key schon
   freigeschaltet, kostet das genau **eine** Passphrase-Eingabe.
3. **LaunchAgent** `~/Library/LaunchAgents/com.code-tunnel.plist` aus der Vorlage rendern
   (`__REPO__`, `__PATH__`) und per `launchctl bootstrap gui/$UID` laden: `RunAtLoad`
   (Tunnel startet beim Login) + `KeepAlive` (Neustart nach jedem Absturz, `ThrottleInterval` 10 s).
4. **Sync** der Login-/Offline-Seite, dann Start + Verifikation des Forwards.

Der Tunnel selbst läuft mit `ControlMaster=no`, damit **autossh die TCP-Verbindung besitzt**
und nach Netzverlust/Sleep wirklich neu verbindet. Die Master-Connection
(`ControlPath=/tmp/ssh-code-%r@%h:%p`, `ControlPersist=60`) ist nur noch für
Erfolgswächter und `diagnose.sh` da. `run.sh` beendet vor dem Start verwaiste
`autossh`/`ssh`-Instanzen mit gleichem `BIND:REMOTE`, damit nicht zwei Prozesse um
denselben VPS-Port konkurrieren (`ExitOnForwardFailure`).

`bootstrap.sh` ist der No-op-Fall: Agent geladen + Forward steht + Key unverändert →
nichts wird angefasst. Nach einem **Key-Wechsel** greift der Fast-Path nicht (der laufende
Agent hat sein `.env` schon gelesen), der Tunnel wird dann bewusst neu gestartet.

```bash
launchctl print  gui/$(id -u)/com.code-tunnel   # Status
tail -f /tmp/code-tunnel.log                    # Log (run.sh + ssh/autossh)
launchctl bootout gui/$(id -u)/com.code-tunnel  # stoppen
```

Ohne launchd/Key (Fremd-Mac) fällt `start-tunnel.command` auf `./run.sh` im Vordergrund
zurück — dann Fenster offen lassen.

Fixe Ports statt random: VPS `172.18.0.1:18731` → Mac `127.0.0.1:8080` (`REMOTE_PORT/LOCAL_PORT/REMOTE_BIND` in `.env`). Serverseitig einmalig: `GatewayPorts clientspecified` in `/etc/ssh/sshd_config` + `systemctl reload sshd`.

Ohne Key-Auth (kein `bootstrap.sh` gelaufen) nutzen Wächter und `diagnose.sh` **eine** Master-Connection (`ControlMaster`, 1x Passphrase).

Im Caddy-Fragment bleibt Browser→Caddy HTTP/2-fähig; der Upstream Caddy→Mac/OpenCode wird wie im Remote-Stack auf HTTP/1.1 mit 4-Sekunden-Keepalive gesetzt. Ein authentisierter Caddy-Healthcheck prüft `/api/info` durch denselben SSH-Tunnel. `stream_timeout 24h` und `stream_close_delay 5m` gelten für WebSocket-Upgrades (insbesondere PTY), nicht für SSE. `forward_auth` wird nur beim Start eines Requests bzw. WebSocket-Handshakes geprüft.

## Credentials

Siehe Root-README + `../setup.sh` (PBKDF2 empfohlen, `AUTH_SECRET` via `openssl rand -hex 32`). `AUTH_HASH` muss bcrypt oder PBKDF2 sein; Klartext wird nicht akzeptiert. OpenCode-Passwort (`OPENCODE_PASSWORD`) injiziert Caddy per `header_up Authorization` upstream — im Browser unsichtbar (Basic siehe Root-README). Echte Werte nie committen.
