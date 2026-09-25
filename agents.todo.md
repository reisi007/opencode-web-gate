# Agents.todo.md

Offene, nicht triviale Punkte und Blockaden. Einträge werden erst nach einem
unabhängigen Review und erfolgreicher Verifikation entfernt.

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
