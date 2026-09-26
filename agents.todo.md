# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

## 2026-09-26

- [x] **Stack `code-remote`: `host.docker.internal` — DEPLOYT und live verifiziert** (2026-09-26).
  `extra_hosts: "${HOST_GATEWAY:-host.docker.internal}:host-gateway"` ist im laufenden Stack:
  `docker inspect code-dev --format '{{json .HostConfig.ExtraHosts}}'` →
  `["host.docker.internal:host-gateway"]`, `getent hosts` liefert `172.17.0.1`, `/etc/hosts`
  enthält den Eintrag, `http://host.docker.internal:8000/` → `404` (Host-Port auf `0.0.0.0`)
  bei `http://127.0.0.1:8000/` → `000` als Gegenprobe. **Korrektur der Doku:** `host-gateway`
  liefert die Docker-Host-IP (`172.17.0.1` = `docker0`), **nicht** das Gateway des eigenen
  Netzes (`code-remote` = `172.24.0.1`, `code-dev` = `172.24.0.3`). Beides ist der Host und
  funktional gleichwertig; `remote/README.md` und der Prüf-Block dort sind korrigiert.
- [ ] **Host-Dienste im Container nutzbar machen (Publish, nicht Adressierung)** — durch
  `host-gateway` ist nur die *Adressseite* gelöst. Die konkret scheiternden Ports
  (Meilisearch 7701, Mailpit 8025/1025, 5432/3306, LM Studio 1234, Astro 4321) sind auf dem VPS
  **nicht erreichbar**, weil dort kein Listener existiert: Loopback-Bind bzw. unveröffentlichte
  Ports. `portal_search` hängt mit `7700/tcp` unveröffentlicht in
  `portal-reisinger-pictures_portal_internal`. Nötig sind Publish auf `0.0.0.0` bzw. eine
  Bridge-IP-Bindung plus eine Config ohne harten `localhost`.
  - DIND-Falle (nicht live beobachtet, aus Netzraum-Logik): `docker run -p 127.0.0.1:X:Y` im
    Sidecar `code-remote-dind` bindet nur im DIND-Netzraum → von `code-dev` nie erreichbar.
    Solche Test-Container gehören per `--network` in ein geteiltes Netz und werden per
    Containername aufgelöst.
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
