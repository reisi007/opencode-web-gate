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
local/                Mac-Tunnel-Runtime (start-tunnel.command -> bootstrap.sh: autossh,
                      SSH-Key, LaunchAgent; run.sh, Compose, Fragment, Login-Seite)
local/deploy.sh       Compose nach /opt/stacks/opencode-tunnel/compose.yaml pushen
remote/               VPS-Runtime (Dockerfile, Compose, Fragment, CI-Image)
remote/deploy.sh      Compose nach /opt/stacks/dev-vm/compose.yaml pushen
```

Die Host-`.env`-Dateien sind **nicht** im Repo und werden von den Deploy-Skripten
weder erzeugt noch übertragen. Produktion ist `root@reisinger.pictures`
(AlmaLinux 9, SELinux enforcing).

## Deploy: Compose aus diesem Repo, kein Portainer

Zwei Stacks werden per `rsync`/`ssh` aus diesem Repo gepusht und auf dem Host mit
Compose betrieben:

| Stackname (exakt) | Repo-Datei | Container | Host |
|---|---|---|---|
| `opencode-tunnel` | `local/docker-compose.yml` | `code-auth` | `/opt/stacks/opencode-tunnel/{compose.yaml,.env}` |
| `dev-vm` | `remote/docker-compose.yml` | `code-dev`, `code-remote-dind`, `code-auth-remote` | `/opt/stacks/dev-vm/{compose.yaml,.env}` |

```bash
./local/deploy.sh --dry-run     # Host-.env read-only prüfen, rsync simulieren
./local/deploy.sh               # compose.yaml pushen, dann docker compose up -d --wait
./remote/deploy.sh --dry-run    # Host-.env read-only prüfen, rsync simulieren
./remote/deploy.sh
```

Die Skripte übertragen ausschließlich die Compose-Datei zunächst auf einen
zufälligen `.compose.candidate.*`-Pfad, validieren sie dort und ersetzen
`compose.yaml` anschließend atomar. Bei fehlgeschlagenem `up` stellen sie die
vorige Datei aus `.compose.previous.*` wieder her, falls vorhanden. Die
Host-`.env` wird nie übertragen oder ausgegeben; `docker compose config -q` liest
sie auf dem Host zur Interpolation. Die Laufzeit-`.env` liegt auf dem Host
(`root:root`, `0600`) und wird zusätzlich im pCloud-Backup gesichert; sie wird
nie in Git abgelegt oder aus dem Repo erzeugt. Der Verzeichnisname ist der
Compose-Projektname; bei `dev-vm`
hängt daran der Volume-Namespace. Die Skripte pinnen `-p` explizit; Zielordner
und Stackname müssen übereinstimmen. `opencode-tunnel` und `dev-vm` dürfen nicht
umbenannt werden
(u. a. `dev-vm_dind-data-rootless`, `dev-vm_gh-config`, `dev-vm_gh-ssh`,
`dev-vm_opencode-data`, `dev-vm_opencode-config`, `dev-vm_opencode-state`,
`dev-vm_tailscale-state`). `dev-vm_code-remote-projects` bleibt als historischer
Volume-Name in der Namespace-Inventarliste erhalten. `/opt/stacks` liegt im
Backup. Watchtower bleibt global konfiguriert; bestehende Labels (u. a. die
Ausnahme für `code-dev`) werden nicht umgestellt.

Vor dem Remote-`up` prueft `remote/deploy.sh` die effektiven `code-dev`-RAM-Limits
gegen den laufenden Container. Bei Abweichung bricht es ab; die offene
5g/9g-vs-7g/12g-Drift wird dadurch nicht implizit entschieden.

**Env-Schlüssel je Stack** (nur Namen, keine Werte):

| Stack | Host-Datei | Schlüssel |
|---|---|---|
| `opencode-tunnel` | `/opt/stacks/opencode-tunnel/.env` | `AUTH_USER`, `AUTH_HASH`, `AUTH_SECRET`, `SESSION_TTL`, `AUTH_IP` |
| `dev-vm` | `/opt/stacks/dev-vm/.env` | `AUTH_USER`, `AUTH_HASH`, `AUTH_SECRET`, `SESSION_TTL`, `OPENCODE_PASSWORD`, `CORS_ORIGIN`, `HF_TOKEN`, `IMAGE`, `CPU_CORES`, `MEMORY_LIMIT`, `MEMSWAP_LIMIT`, `DIND_CPU_CORES`, `TS_AUTHKEY`, `TS_TAILSCALE_HOSTNAME`, `OPENCODE_AUTOUPDATE`, `OPENCODE_UPDATE_INTERVAL`, `OPENCODE_UPDATE_HOURS`, `OPENCODE_UPDATE_RESTART`, `RAM_WATCHDOG_*` |

Die dind-RAM-Limits sind keine Env-Keys: `mem_limit: 2g` / `memswap_limit: 4g`
stehen fest in `remote/docker-compose.yml` (Issue #2, 2026-11-05).

`RAM_WATCHDOG_*` steht für `RAM_WATCHDOG_ENABLED`,
`RAM_WATCHDOG_THRESHOLD_PERCENT`, `RAM_WATCHDOG_HOST_AVAILABLE_MB`,
`RAM_WATCHDOG_CONTAINER_SHARE_MIN_PCT`, `RAM_WATCHDOG_HOST_MAX_SWAP_PERCENT`,
`RAM_WATCHDOG_HOST_HOLD_COUNT`, `RAM_WATCHDOG_STARTUP_GRACE_S`,
`RAM_WATCHDOG_CHILD_RSS_MB`, `RAM_WATCHDOG_CHILD_MIN_RSS_MB`,
`RAM_WATCHDOG_CHILD_MAX_COUNT`, `RAM_WATCHDOG_CHILD_GRACE_S`,
`RAM_WATCHDOG_GRACE_PERIOD`, `RAM_WATCHDOG_POLL_INTERVAL`,
`RAM_WATCHDOG_STARTUP_WAIT_S`, `RAM_WATCHDOG_CGROUP_DIR`.

Hintergrund und Migrationsstand:
[`strato-vps#1`](https://github.com/reisi007/strato-vps/issues/1).

**Offen (2026-11-02):** `remote/docker-compose.yml` hat die Defaults
`MEMORY_LIMIT=5g` / `MEMSWAP_LIMIT=9g` (Owner-Entscheidung 2026-10-21), der
Live-Container `code-dev` läuft aber mit **7g/12g**. Dieser Widerspruch ist
**nicht entschieden**; die Defaults bleiben unverändert. Details:
[`remote/README.md`](remote/README.md) und [`agents.todo.md`](agents.todo.md).

## Passwoerter & Caddy-Basic (alles Handarbeit)

```bash
openssl rand -base64 24                       # → OPENCODE_PASSWORD (in .env; remote: Host-.env)
source .env && printf 'opencode:%s' "$OPENCODE_PASSWORD" | base64
# → header_up Authorization "Basic ..." (in globale Caddyfile, nie committen)
docker run --rm caddy:2 caddy hash-password --plaintext 'PASSWORT'   # → AUTH_HASH (60 Zeichen)
```

Echte Domains/Hosts stehen nur in `.env` (Beispiele mit `example.com` im Repo). Nach Public-Schalten Secrets rotiert halten (History aus privater Zeit).

Der Login ist **einer** fuer beide Wege: `AUTH_USER`/`AUTH_HASH`/`AUTH_SECRET`
muessen in `./.env`, in `/opt/stacks/opencode-tunnel/.env` und in
`/opt/stacks/dev-vm/.env` identisch sein. Die fruehere Portainer-Regel
(`AUTH_HASH` als `$$2a$…` in eine Paste-Vorlage) ist **Historie**. In der
nativen Compose-Host-`.env` werden neue Hashes einfach-quotiert eingetragen
(`AUTH_HASH='$2a$14$…'`), damit Compose die `$`-Zeichen nicht interpoliert.
Vor einem weiteren Compose-Deploy vorhandene unquotierte Werte prüfen: der
effektive Hash muss zum laufenden Auth-Container passen. Falls nicht, den
Host-Wert manuell quotieren; Deploy-Skripte schreiben die `.env` nie um.
Regeln und Verifikation:
[`AGENTS.md`](AGENTS.md).
