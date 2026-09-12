# opencode-web-gate

OpenCode 2 im Browser — zwei Wege, ein Login (Cookie-Seite statt Browser-Popup):

| Weg | Ordner | OpenCode läuft … | Details |
|---|---|---|---|
| **lokal** (Mac) | [`local/`](local/) | auf deinem Mac, per SSH-Reverse-Tunnel zum VPS | [`local/README.md`](local/README.md) |
| **remote** (VPS) | [`remote/`](remote/) | im VPS-Container `code-dev` (eigenes CI-Image) | [`remote/README.md`](remote/README.md) |

Beide Wege teilen Auth-Prinzip (Caddy `forward_auth` → `code-auth`-Sidecar → Upstream) und Secrets.

## Struktur

```
.env / .env.example   zentrale Secrets + Domains (gitignored: .env)
setup.sh              einmalig: .env erzeugen (Secrets, Hash)
local/                Mac-Tunnel-Runtime (run.sh, Compose, Fragment, Login-Seite)
remote/               VPS-Runtime (Dockerfile, Compose, Fragment, CI-Image)
remote/.env.production  globales Portainer-Env (gitignored, MANUELL aus .env uebernehmen)
```

## Passwoerter & Caddy-Basic (alles Handarbeit)

```bash
openssl rand -base64 24                       # → OPENCODE_PASSWORD (in .env + Portainer-Env)
source .env && printf 'opencode:%s' "$OPENCODE_PASSWORD" | base64
# → header_up Authorization "Basic ..." (in globale Caddyfile, nie committen)
docker run --rm caddy:2 caddy hash-password --plaintext 'PASSWORT'   # → AUTH_HASH (60 Zeichen)
```

Echte Domains/Hosts stehen nur in `.env` (Beispiele mit `example.com` im Repo). Nach Public-Schalten Secrets rotiert halten (History aus privater Zeit).
