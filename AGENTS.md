# AGENTS.md — Regeln fuer dieses Repo

**Nur Regeln, keine Entscheidungen:** Diese Datei enthält ausschließlich Regeln — Anweisungen, die für jede Arbeit in diesem Repo gelten. Dauerhafte Entscheidungen, Begründungen, Messwerte und Historie gehören nicht hierher, sondern in `docs/`/`features/` bzw. die Projekt-Doku; offene Punkte nach `agents.todo.md`; Erledigtes in die Git-Historie.

## 1. Deploy: Compose aus dem Repo nach `/opt/stacks/<stack>`

Zwei Stacks werden aus diesem Repo gepusht und auf `root@reisinger.pictures`
(AlmaLinux 9, SELinux enforcing) mit Compose betrieben:

| Stackname (exakt) | Repo-Datei | Container | Host |
|---|---|---|---|
| `opencode-tunnel` | `local/docker-compose.yml` | `code-auth` | `/opt/stacks/opencode-tunnel/{compose.yaml,.env}` |
| `dev-vm` | `remote/docker-compose.yml` | `code-dev`, `code-remote-dind`, `code-auth-remote` | `/opt/stacks/dev-vm/{compose.yaml,.env}` |

- Transport ist `rsync`/`ssh` ueber `local/deploy.sh` bzw. `remote/deploy.sh`.
  Sie übertragen ausschließlich die Compose-Datei zunächst auf einen zufälligen
  `.compose.candidate.*`-Pfad, validieren sie dort und ersetzen anschließend
  `compose.yaml` atomar. Bei fehlgeschlagenem `up` stellen sie, falls vorhanden,
  die vorherige Compose-Datei aus `.compose.previous.*` wieder her. Die Host-`.env`
  wird nie übertragen oder ausgegeben; `docker compose config -q` liest sie auf
  dem Host zur Interpolation.
- Vor jedem echten Lauf `--dry-run`; er prüft die Host-Dateien read-only,
  simuliert nur den Compose-rsync und startet Compose nicht.
- **Keine Env-Uebertragung.** Die `.env` wird nie aus dem Repo erzeugt, nie
  mitgesynct und nie ueberschrieben.
- Beide Deploy-Skripte pinnen den Compose-Projektnamen explizit mit `-p` auf
  den passenden Stack-/Verzeichnisnamen. Verzeichnis und `-p`-Wert muessen
  identisch bleiben; bei `dev-vm` haengt daran der Volume-Namespace. Namen nie
  umbenennen — sonst entstehen neue Volumes (`dev-vm_dind-data-rootless`,
  `dev-vm_gh-config`, `dev-vm_gh-ssh`, `dev-vm_opencode-*`,
  `dev-vm_tailscale-state`). `dev-vm_code-remote-projects` bleibt als
  historischer Volume-Name in der Namespace-Inventarliste erhalten.
- `/opt/stacks` liegt im Backup. Watchtower bleibt global konfiguriert;
  bestehende Labels (u. a. die Ausnahme fuer `code-dev`) werden nicht
  umgestellt.
- Keine Service-Definitionen, Images, Ports, Volumes, Netzwerke oder
  Privilegien ueber eine Doku-Aenderung verschieben. Compose-Dateien nur im
  Kommentar anfassen, wenn die Doku es verlangt.
- Migrationsstand:
  [`strato-vps#1`](https://github.com/reisi007/strato-vps/issues/1).

## 2. Stack-`.env` ist Laufzeitquelle auf dem Host

- `setup.sh` erzeugt **nur** die Mac-`.env`. Die Host-Dateien
  `/opt/stacks/opencode-tunnel/.env` und `/opt/stacks/dev-vm/.env` sind
  `root:root 0600`, gitignored und enthalten die bisherigen
  Portainer-Stack-Env-Werte. Sie werden zusätzlich durch das pCloud-Backup
  gesichert, aber nie in Git abgelegt oder durch die Deploy-Skripte übertragen.
- Vorhandene Host-`.env` nie aus dem Repo erzeugen oder ueberschreiben. Fehlt
  ein Schluessel, wird er auf dem Host ergaenzt — nicht durch einen neuen
  Deploy-Lauf.
- Schluessel je Stack (nur Namen, keine Werte):
  - `opencode-tunnel`: `AUTH_USER`, `AUTH_HASH`, `AUTH_SECRET`, `SESSION_TTL`,
    `AUTH_IP`.
  - `dev-vm`: `AUTH_USER`, `AUTH_HASH`, `AUTH_SECRET`, `SESSION_TTL`,
    `OPENCODE_PASSWORD`, `CORS_ORIGIN`, `HF_TOKEN`, `IMAGE`, `CPU_CORES`,
    `MEMORY_LIMIT`, `MEMSWAP_LIMIT`, `DIND_CPU_CORES`, `DIND_MEMORY_LIMIT`,
    `DIND_MEMSWAP_LIMIT`, `TS_AUTHKEY`, `TS_TAILSCALE_HOSTNAME`,
    `OPENCODE_AUTOUPDATE`, `OPENCODE_UPDATE_INTERVAL`, `OPENCODE_UPDATE_HOURS`,
    `OPENCODE_UPDATE_RESTART`, `RAM_WATCHDOG_*`.
- **Portainer-`$$`-Escaping ist Historie**, keine Paste-Anweisung. Für neue oder
  rotierte Werte `AUTH_HASH` in der Host-`.env` einfach quoten:
  `AUTH_HASH='$2a$14$…'`. Native Compose-`.env`-Dateien interpolieren
  unquotierte `$`-Sequenzen; einfache Anführungszeichen erhalten den Hash
  unverändert. Die lokale Mac-`.env` braucht dieselben Quotes, weil Bash sie
  sourced. Vor jedem weiteren Compose-Deploy bestehende Host-Werte prüfen:
  Compose muss den Hash korrekt erhalten und der effektive Wert muss zum
  laufenden Auth-Container passen. Falls nicht, den Host-Wert manuell einfach
  quotieren; Deploy-Skripte ändern bestehende Host-Dateien nie.
  Den Containerwert bei Bedarf secret-sicher mit `docker inspect` prüfen.
- Das `$$` in den Compose-Heredocs (`command: sh -c "cat << 'PYEOF' …"`) ist
  **Compose-Escaping**, nicht Portainer. Es bleibt unangetastet.

## 3. Ein Login fuer beide Wege, nicht zwei

`code` (Mac-Tunnel) und `remote-code` (VPS) sind derselbe Zugang und teilen sich
`AUTH_USER`, `AUTH_HASH` und `AUTH_SECRET`. **Drei** Dateien muessen synchron
sein:

1. `.env` (lokal, Mac, gitignored)
2. `/opt/stacks/opencode-tunnel/.env` (Host, gitignored)
3. `/opt/stacks/dev-vm/.env` (Host, gitignored)

Aendert sich einer der Werte, ist die Login-Aenderung unvollstaendig, bis die
anderen beiden nachgezogen und der jeweilige Stack neu deployed ist.

## 4. Zwei Passwoerter, die nicht dasselbe sind

| Variable | Wo | Zweck |
|---|---|---|
| `AUTH_HASH` | code-auth-Sidecar | Login-Seite (Cookie-Gate), bcrypt, User `AUTH_USER` |
| `OPENCODE_PASSWORD` | code-dev / `opencode serve` | Server-Passwort, das Caddy per `header_up Authorization` upstream injiziert |

- `OPENCODE_PASSWORD` darf pro Weg verschieden sein — Caddy injiziert pro Block den passenden Wert. **Der Login der Login-Seite hat damit nichts zu tun.** Nicht vereinheitlichen.
- Ein 401 auf `/api/info` ist ein Basic-Problem, ein 401 auf `/api/login` ein `AUTH_HASH`-Problem.
- Die `/api/*`-Gate in `caddyfile/Caddyfile` (`@api_ok`, **beide** Bloecke) matcht exakt `Authorization: Basic base64("<AUTH_USER>:<Login-Passwort>")` — dieselbe Kennung wie die Login-Seite. Der Upstream sieht davon nichts: `header_up Authorization` setzt weiterhin `base64("opencode:<OPENCODE_PASSWORD>")`. Edge-Kennung und Server-Passwort sind absichtlich **verschieden** und rotieren getrennt.
- Folge bei Rotation des Login-Passworts: **drei** Stellen nachziehen — `AUTH_HASH` (bcrypt, Sidecar), den `@api_ok`-base64-Wert in `caddyfile/Caddyfile` (**beide** Bloecke) und die App-/PWA-Konfiguration. Regel fuer den Tunnel-Block: [`local/AGENTS.md`](local/AGENTS.md) §10.

## 5. Verifikations-Befehle (VPS, read-only)

Vor jeder Aussage "Login ist synchron" messen, nicht raten:

```bash
# (1) Welche AUTH_* sind ueberhaupt gesetzt? (nur Namen, keine Werte)
for c in code-auth code-auth-remote; do
  printf '%-20s ' "$c"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep '^AUTH_' | cut -d= -f1 | tr '\n' ' '; echo
done

# (2) User + Secret im direkten Vergleich (gekuerzt, Secrets nie im Klartext)
for c in code-auth code-auth-remote; do
  printf '%-20s ' "$c"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -E '^AUTH_(USER|SECRET)=' | sed -E 's/=(.{0,7}).*/=\1…/' | tr '\n' ' '; echo
done

# (3) Hash-Gleichheit, ohne ihn auszugeben
h() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | grep '^AUTH_HASH=' | cut -d= -f2-; }
a="$(h code-auth)"; b="$(h code-auth-remote)"
[ -n "$a" ] && [ -n "$b" ] \
  && { [ "$a" = "$b" ] && echo 'AUTH_HASH: identisch' || echo 'AUTH_HASH: WEICHT AB'; } \
  || echo 'AUTH_HASH: fehlt in mindestens einem Sidecar'

# (4) Hash-Form: muss mit $2 beginnen, nicht mit $$2
printf 'code-auth-remote bekam: %s\n' "$(printf '%s' "$b" | cut -c1-7)"
```

Erwartetes Ergebnis bei synchronem Stand: gleiche Variablen, gleicher User, gleiches Secret, `AUTH_HASH: identisch`, Form `$2a$1…`.

## 6. Offene RAM-Drift nicht per Doku entscheiden

`remote/docker-compose.yml` hat die Defaults `MEMORY_LIMIT=5g` /
`MEMSWAP_LIMIT=9g` (Owner-Entscheidung 2026-10-21). Der Live-Container
`code-dev` hat **7g/12g**. Der Widerspruch ist offen — keine Seite still
anpassen, die Defaults nicht aendern und keine der beiden Zahlen als
"aktuellen Sollstand" dokumentieren. Stand und Messbedarf:
[`agents.todo.md`](agents.todo.md).

`agents.todo.md` fuehrt die offenen Live-Punkte.

## Gates

Regeln dieser Ebene. Was nur ein Verzeichnis betrifft, gehört in die
`AGENTS.md` **dieses** Verzeichnisses — sie wird geladen, wenn eine Datei
daraus gelesen wird.

Ein Plan in `docs/plans/` beginnt mit `**Status:** Plan | In Arbeit | Done |
Empfehlung, nicht implementiert`.

Die kanonischen Agent-Regeln laufen über `ratchet` (Preset `agent-rules`):
`ratchet check` vor jedem Commit und in der CI.
