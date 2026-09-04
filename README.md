# opencode2-ssh-tunnel-web

Eigene HTML-Login-Seite (`login.html`) vor OpenCode-Web via SSH-Reverse-Tunnel. Kein natives `basic_auth`-Popup.

## Warum ein Sidecar-Container

Stock-`caddy:latest` kann nur `basic_auth` → `401 + WWW-Authenticate` → Browser zeigt immer sein graues Popup. Ein eigenes Formular braucht eine Cookie-Session, und die kann Caddy allein nicht ausstellen (kein Passwort-Check + HMAC im Core). Deshalb genau **ein** zusätzlicher Container `code-auth`:

```
Browser -> code.all-the.rest (zentrales Caddy)
  /login.html, /api/login, /api/me -> statisch / Sidecar
  / (Rest) -> forward_auth code-auth:8081 (/check) -> 127.0.0.1:18731 (SSH-Tunnel -> Mac :8080)
  401 -> 302 /login.html (nie WWW-Authenticate -> nie Popup)
```

Kein zweites Caddy (Ports 80/443 sind belegt), kein Flask/Gunicorn — das eingebettete Python nutzt nur Stdlib + optional `bcrypt`.

## Credentials Single-User

Hash erzeugen, Klartext nie committen. **Empfohlen: PBKDF2** (Stdlib, kein pip im Container nötig):

```bash
python3 -c "import hashlib,secrets,getpass; p=getpass.getpass('Passwort: '); s=secrets.token_hex(16); print('pbkdf2\$100000\$'+s+'\$'+hashlib.pbkdf2_hmac('sha256',p.encode(),bytes.fromhex(s),100000).hex())"
# -> pbkdf2$100000$... als AUTH_HASH in .env / Portainer-Env eintragen (komplette Zeile, ohne Quotes)
```

Alternative via Docker-Caddy (bcrypt, Container installiert dann `pip install bcrypt` beim Start — Log prüfen):

```bash
docker run --rm caddy:2 caddy hash-password --plaintext 'DEIN_PASSWORT'
# -> $2a$14$... (60 Zeichen!) als AUTH_HASH eintragen
```

`./setup.sh` macht das interaktiv (inkl. `AUTH_SECRET` via `openssl rand -hex 32`). Container-Log muss `Hash-Format: ..., bcrypt-Modul: ok/FEHLT` zeigen.

## Ablauf

```bash
./setup.sh            # einmalig: .env, Secret, Hash, Checks (braucht: ssh docker rclone python3 openssl; autossh via: brew install autossh)
./diagnose.sh         # Checks lokal + VPS (1x Passphrase)
./run.sh              # OpenCode-Autostart + rclone-Sync + Tunnel; Flags: --sync-only / --tunnel-only
./diagnose.sh --quick # nur lokal
# Am Mac alternativ Doppelklick auf start-tunnel.command (macht run.sh im Terminal auf)
```

SSH läuft immer über **eine** Master-Connection (`ControlMaster auto`, `ControlPersist 60` zu `root@reisinger.pictures:22`), daher trotz passwortgeschütztem Key nur 1x Passphrase.

## Portainer-Deploy

1. Portainer → Stacks → Add stack `code-auth`, Inhalt von `stack/docker-compose.yml` in den Web-Editor pasten (Single File, alles inline).
2. Env aus `.env` übernehmen (`AUTH_USER/AUTH_HASH/AUTH_SECRET/SESSION_TTL/AUTH_IP`).
3. Starten. `code-auth` hängt im externen `webnet` (Default `172.18.0.60`, Block nach `.55` countdown / `.253` ftp — vorher `docker network inspect webnet` prüfen).

## Caddy

Fragment `caddy/Caddyfile.fragment` in `/Users/florianreisinger/dev/caddyfile/Caddyfile` übernehmen, dann dort `./sync.sh` (validate + reload). Website-Sync: `rclone sync apps/web/dist reisinger.pictures:/code.all-the.rest` (macht `run.sh`). DNS: `code.all-the.rest` A-Record auf VPS.

## OpenCode-Passwort (de facto deaktiviert)

`opencode2 serve` erzwingt immer ein Serverpasswort (kein `--no-auth`, leeres Env generiert trotzdem eins — getestet). Darum: `run.sh` startet serve mit fixem `OPENCODE_PASSWORD` aus `.env` (generiert `setup.sh`), und Caddy injiziert es per `header_up Authorization` upstream — im Browser unsichtbar. Bei Rotation: neuen Wert in `.env` + Base64 (`echo -n "opencode:PASS" | base64`) ins Caddyfile, `./sync.sh`.

## Ports

Fix statt random (random bräuchte Caddy-Reload je Start): VPS `127.0.0.1:18731` → Mac `127.0.0.1:8080`, änderbar via `REMOTE_PORT/LOCAL_PORT` in `.env`. Autostart-Beispiel: `scripts/com.code-tunnel.plist` nach `~/Library/LaunchAgents/` kopieren, Pfad anpassen, `launchctl load`.

## Sicherheit

HMAC-signiertes Cookie (`HttpOnly, Secure, SameSite=Lax`, TTL default 12h), `Cache-Control: no-store`, 0.5s Delay bei Falsch-Login. Logout: `POST /api/logout`.
