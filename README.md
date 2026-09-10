# opencode2-ssh-tunnel-web

OpenCode 2 im Browser — auf zwei Wegen, beide hinter derselben Cookie-Login-Seite (`login.html`, kein natives `basic_auth`-Popup):

| Weg | Domain | OpenCode läuft … | Für … |
|---|---|---|---|
| **lokal** (Mac) | `code.example.com` | auf deinem Mac, per SSH-Reverse-Tunnel zum VPS | Arbeiten mit lokalen Mac-Projekten von unterwegs |
| **remote** (VPS) | `remote-code.example.com` | im VPS-Container `code-dev` (eigenes Image) | Projekte, die direkt auf dem VPS leben (inkl. `git`/`gh`) |

Beide Wege teilen sich das Auth-Prinzip: zentrales Caddy → `forward_auth` an einen `code-auth`-Sidecar (HMAC-Cookie) → erst dann zum OpenCode-Upstream. `401` wird nie als Browser-Popup sichtbar, sondern als Redirect auf `/login.html`.

## Weg 1: lokal (Mac via SSH-Tunnel)

```
Browser -> code.example.com (zentrales Caddy)
  /login.html, /api/* -> statisch / Sidecar code-auth:8081
  / (Rest) -> forward_auth code-auth:8081 (/check) -> 172.18.0.1:18731 (SSH-Tunnel -> Mac :8080)
  401 -> 302 /login.html
```

```bash
./setup.sh            # einmalig: .env, Secret, Hash, Checks (braucht: ssh docker rclone python3 openssl; autossh via: brew install autossh)
./diagnose.sh         # Checks lokal + VPS (1x Passphrase)
./run.sh              # OpenCode-Autostart + rclone-Sync + Tunnel; Flags: --sync-only / --tunnel-only
./diagnose.sh --quick # nur lokal
# Am Mac alternativ Doppelklick auf start-tunnel.command (macht run.sh im Terminal auf)
```

SSH läuft über **eine** Master-Connection (`ControlMaster auto`, `ControlPersist 60` zu `user@vps.example.com:22`), daher trotz passwortgeschütztem Key nur 1x Passphrase. Ports sind fix statt random (random bräuchte Caddy-Reload je Start): VPS `172.18.0.1:18731` (Docker-Bridge, kein Loopback — Caddy läuft im Bridge-Netz!) → Mac `127.0.0.1:8080`, änderbar via `REMOTE_PORT/LOCAL_PORT/REMOTE_BIND` in `.env`. Serverseitig einmalig: `GatewayPorts clientspecified` in `/etc/ssh/sshd_config` + `systemctl reload sshd`. Autostart-Beispiel: `scripts/com.code-tunnel.plist` nach `~/Library/LaunchAgents/` kopieren, Pfad anpassen, `launchctl load`.

Infra dafür: Portainer-Stack `code-auth` aus `stack/docker-compose.yml` (Single File, externen `webnet`, Default `172.18.0.60` — vorher `docker network inspect webnet` prüfen, Block nach `.55` countdown / `.253` ftp). Login-Seite via `rclone` aus `apps/web/dist` (`./sync.sh`, macht `run.sh` mit).

## Weg 2: remote (VPS-nativ, isoliert)

```
Browser -> remote-code.example.com (zentrales Caddy, zusaetzlich im Netz code-remote)
  /login.html, /api/* -> statisch / Sidecar code-auth-remote:8081 (nur code-remote-Netz)
  / (Rest) -> forward_auth code-auth-remote:8081 (/check) -> code-dev:8080
  401 -> 302 /login.html
```

* Image `opencode-web-dev-baseline` (`remote/Dockerfile`, per GitHub-CI weekly nach GHCR gebaut): Debian + Node 26.x + PHP 8.5 + Composer + `gh` + Docker-CLI + **opencode2** (`@beta`-Tag).
* Stack `code-remote` (`stack/docker-compose.remote.yml`, Single File für Portainer): `code-dev` + **isolierter** `docker:dind`-Daemon + eigener `code-auth-remote`. Alle drei hängen **nur** im Bridge-Netz `code-remote` — kein `webnet`, daher keine Prod-Container per Name erreichbar (Internet via NAT geht). `code-dev` spricht Docker über `tcp://dind:2375`.
* Projekte + `gh`-Auth + SSH-Keys liegen in Named Volumes (`code-remote-projects`, `gh-config`, `gh-ssh`) und überleben Image-Upgrades. Einmalig im Container: `docker exec -it code-dev gh auth login`, danach `gh repo clone …` nach `/projects`.
* Ablauf ohne SSH, nur Portainer + 1x VPS-Handgriff — Details in `remote/README.md`. Kurz: `./finish-setup.sh` (liest nur `.env`, gibt Portainer-Env + Caddy-Snippets nach `/tmp`), Stack in Portainer anlegen, Caddy-Snippet übernehmen.

## Caddy (zentrales Caddyfile, anderes Repo)

Die echte `Caddyfile` liegt **nicht** in diesem Repo (nur Vorlagen mit Platzhaltern). Prinzip für beide Domains — Snippets `security_headers` + `compress` kommen aus dem zentralen Caddyfile:

* statische `/login.html` (per rclone synchronisiert), `/api/login|/me|/logout` → jeweiliger `code-auth*`-Sidecar, `/sw.js` als leerer Worker (neutralisiert einen OpenCode-Precaching-Bug), Rest hinter `forward_auth` (+ `handle_response` 401 → Redirect) zum Upstream.
* Upstream lokal: `172.18.0.1:18731` (SSH-Tunnel) inkl. `header_up Authorization` mit dem OpenCode-Serverpasswort (Browser sieht es nie); Upstream remote: `code-dev:8080` ebenso.
* Remote braucht zusätzlich: Netz `code-remote` anlegen, Caddy-Container dort einhängen, DNS `remote-code.example.com` A-Record, `./sync.sh` (validate + reload) im caddyfile-Repo.
* Echte Secrets stehen nie in den Fragmenten: Platzhalter `__OPENCODE_BASIC__`, `./finish-setup.sh` füllt ihn lokal aus `.env` (Ausgabe nur `/tmp`).

Vorlagen: `caddy/Caddyfile.fragment` (lokal), `caddy/Caddyfile.remote.fragment` (remote).

## Credentials Single-User

Hash erzeugen, Klartext nie committen. **Empfohlen: PBKDF2** (Stdlib, kein pip im Container nötig):

```bash
python3 -c "import hashlib,secrets,getpass; p=getpass.getpass('Passwort: '); s=secrets.token_hex(16); print('pbkdf2\$100000\$'+s+'\$'+hashlib.pbkdf2_hmac('sha256',p.encode(),bytes.fromhex(s),100000).hex())"
# -> pbkdf2$100000$... als AUTH_HASH in .env / Portainer-Env eintragen (komplette Zeile, ohne Quotes)
```

Alternative via Docker-Caddy (bcrypt, Container installiert dann `pip install bcrypt` beim Start — Log prüfen):

```bash
docker run --rm caddy:2 caddy hash-password --plaintext 'DEIN_PASSWORT'
# -> $2a$... (60 Zeichen!) als AUTH_HASH eintragen
```

`./setup.sh` macht das interaktiv (inkl. `AUTH_SECRET` via `openssl rand -hex 32`). Container-Log muss `Hash-Format: ..., bcrypt-Modul: ok/FEHLT` zeigen.

## OpenCode-Passwort (de facto deaktiviert)

`opencode2 serve` erzwingt immer ein Serverpasswort (kein `--no-auth`). Darum: `run.sh` (lokal) bzw. der `code-dev`-Entrypoint (remote) starten serve mit fixem `OPENCODE_PASSWORD` aus `.env` (generiert `setup.sh`), und Caddy injiziert es per `header_up Authorization` upstream — im Browser unsichtbar. Echten Base64-Wert nie committen: `./finish-setup.sh` erzeugt ihn lokal aus `.env`.

## Secrets / Public

`.env` steht in `.gitignore` und wird nie committet; `./finish-setup.sh` bricht ab, falls doch ein echter Wert im Repo landet. Hinweis: die Git-History aus privater Zeit enthält alte Secret-Werte — nach dem Public-Schalten `OPENCODE_PASSWORD` + `AUTH_HASH` rotieren und Stacks/Caddy neu deployen.

## Sicherheit

HMAC-signiertes Cookie (`HttpOnly, Secure, SameSite=Lax`, TTL default 12h), `Cache-Control: no-store`, 0.5s Delay bei Falsch-Login. Logout: `POST /api/logout`. Remote zusätzlich: kein `webnet`-Zugriff (kein Prod-Sichtkontakt), Docker nur über isolierten Daemon, `code-dev` läuft als Non-Root-User `dev`.
