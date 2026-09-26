# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

## 2026-09-26

- [ ] **Stack `code-remote`: `host.docker.internal` live nachziehen** — `remote/docker-compose.yml`
  hat jetzt `extra_hosts: "${HOST_GATEWAY:-host.docker.internal}:host-gateway"`. Live verifiziert
  auf dem VPS: Docker 29.2.1, Netz `code-remote` = `172.24.0.0/16`, Gateway `172.24.0.1`,
  `code-dev` = `172.24.0.3`; **vor** dem Fix war `getent hosts host.docker.internal` leer
  (`ExtraHosts: []`). Offen:
  - Portainer: Stack `code-remote` → **Update stack** (Image unverändert, kein Pull nötig).
  - `HOST_GATEWAY=host.docker.internal` in `remote/.env.production` (gitignored) ergänzen.
  - `docker exec code-dev getent hosts host.docker.internal` → muss `172.24.0.1` liefern.
  - **Wichtig:** Die konkret scheiternden Ports (Meilisearch 7701, Mailpit 8025/1025, 5432/3306,
    LM Studio 1234, Astro 4321) sind durch den Fix **nicht** erreichbar — auf dem VPS existiert
    dafür kein Listener (Loopback-Bind bzw. unpublished Port). Die brauchen Publish auf `0.0.0.0`
    bzw. eine Bridge-IP. `portal_search` hängt mit `7700/tcp` unveröffentlicht in
    `portal-reisinger-pictures_portal_internal`.
  - DIND-Falle (nicht live beobachtet, aus Netzraum-Logik): `docker run -p 127.0.0.1:X:Y` im
    Sidecar `code-remote-dind` bindet nur im DIND-Netzraum → von `code-dev` nie erreichbar.
- [ ] **Lokaler Tunnel: Supervision im Realbetrieb verifizieren** — `local/bootstrap.sh` richtet
  beim Start alles ein (autossh, bestehender Key `~/.ssh/id_rsa` via macOS-Keychain, LaunchAgent
  `com.code-tunnel` mit `RunAtLoad`+`KeepAlive`+`Umask 077`); `run.sh` gibt die TCP-Verbindung an
  autossh (`ControlMaster=no`) und räumt verwaiste Instanzen auf. Erledigt und verifiziert:
  Key-Umstellung (eine Passphrase-Eingabe, `BatchMode`+`UseKeychain` funktioniert ohne TTY, der
  kurzzeitig erzeugte dedizierte Key ist wieder gelöscht — lokal und in `authorized_keys`),
  Reconnect nach `kill -9` des ssh **mit** `id_rsa`, Neustart nach `kill -9` des `run.sh`
  (launchd in < 3 s), `bootstrap.sh` als No-op ohne Restart. Zwei Review-Runden mit
  DeepSeek 4.1 (Blocker, SOLLTE, KANN) sind eingearbeitet, Abschlussurteil
  "commit-fähig". **Offen:** ein echter Sleep/WLAN-Wechsel, ein Reboot (Login-Autostart)
  und der Fall, dass die Login-Keychain nach dem Login gesperrt bleibt (dann
  Restart-Schleife).

## 2026-09-25

- [ ] **Live-Deploy von `df9fe4d`** — CI `build-baseline` ist grün
  (Run `36094815211`), aber VPS/Portainer und Caddy sind noch nicht aktualisiert:
  - Image `ghcr.io/reisi007/opencode-web-dev-baseline:latest` im Stack
    `code-remote` ziehen und `code-dev` neu deployen.
  - Stack `code-remote` mit dem gehärteten Auth-Service neu deployen.
  - Stack `code-auth` mit der neuen `Content-Length`-Validierung neu deployen.
  - `local/Caddyfile.fragment` und `remote/Caddyfile.fragment` in die globale
    Caddyfile übernehmen, validieren und reloaden.
  - Login, `/api/event` als SSE, PTY-WebSocket und einen normalen API-Request
    nach längerer Leerlaufzeit live prüfen.
  - Abnahme erst nach unabhängigem Review der Live-Verifikation durchführen.
