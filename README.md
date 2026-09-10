# opencode2-ssh-tunnel-web

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
finish-setup.sh       Portainer-Env (remote/.env.production) + Caddy-Snippets (/tmp) erzeugen, Repo auf Leaks pruefen
local/                Mac-Tunnel-Runtime (run.sh, Compose, Fragment, Login-Seite)
remote/               VPS-Runtime (Dockerfile, Compose, Fragment, CI-Image)
```

## Start

```bash
./setup.sh         # einmalig
./finish-setup.sh  # vor jedem Portainer-Deploy / jeder Caddy-Aenderung
```

Echte Domains/Hosts stehen nur in `.env` (Beispiele mit `example.com` im Repo). Nach Public-Schalten Secrets rotiert halten (History aus privater Zeit).
