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
| `run.sh` | OpenCode-Autostart + rclone-Sync + Tunnel (`--sync-only` / `--tunnel-only`) |
| `diagnose.sh` | Checks lokal + VPS (`--quick` nur lokal) |
| `sync.sh` | Login-Seite (`apps/web/dist`) per rclone auf VPS |
| `start-tunnel.command` | Doppelklick-Start am Mac |
| `scripts/com.code-tunnel.plist` | LaunchAgents-Autostart (Pfad anpassen!) |
| `apps/web/dist/` | Login- + Offline-Seite |
| `docker-compose.yml` | Portainer-Stack `code-auth` (Single File, ext. `webnet`) |
| `Caddyfile.fragment` | Vorlage für globale Caddyfile (Platzhalter!) |

## Ablauf

```bash
./run.sh              # aus diesem Ordner (.env wird aus Repo-Root gelesen)
./diagnose.sh
```

SSH nutzt **eine** Master-Connection (`ControlMaster`, 1x Passphrase). Fixe Ports statt random: VPS `172.18.0.1:18731` → Mac `127.0.0.1:8080` (`REMOTE_PORT/LOCAL_PORT/REMOTE_BIND` in `.env`). Serverseitig einmalig: `GatewayPorts clientspecified` in `/etc/ssh/sshd_config` + `systemctl reload sshd`.

## Credentials

Siehe Root-README + `../setup.sh` (PBKDF2 empfohlen, `AUTH_SECRET` via `openssl rand -hex 32`). OpenCode-Passwort (`OPENCODE_PASSWORD`) injiziert Caddy per `header_up Authorization` upstream — im Browser unsichtbar (Basic siehe Root-README). Echte Werte nie committen.
