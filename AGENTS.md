# AGENTS.md — Regeln fuer dieses Repo

**Nur Regeln, keine Entscheidungen:** Diese Datei enthält ausschließlich Regeln — Anweisungen, die für jede Arbeit in diesem Repo gelten. Dauerhafte Entscheidungen, Begründungen, Messwerte und Historie gehören nicht hierher, sondern in `docs/`/`features/` bzw. die Projekt-Doku; offene Punkte nach `agents.todo.md`; Erledigtes in die Git-Historie.

## 1. `remote/.env.production` ist eine Portainer-Paste-Vorlage

Die Datei wird **1:1 in die Portainer-UI** kopiert (Stack `code-remote` → Environment → Stack Environment) und ist die einzige Quelle fuer den laufenden Remote-Stack.

- **Kein Kommentar-Zeilen-Umbau, kein Aufraeumen, kein "sieht komisch aus".** Der Inhalt wird unveraendert gepflegt und genau so eingefuegt.
- Jede Zeile, die nach dem Einfuegen in Portainer `KEY=WERT` ergeben muss, bleibt eine solche Zeile.
- Nach jedem Aendern an der Datei: der Stack muss in Portainer neu deployed werden — die Datei selbst deployt nichts.
- `setup.sh` erzeugt **nur** `.env`, nie `.env.production`. Der Weg von der `.env` hierher ist Handarbeit und der wahrscheinlichste Drift-Punkt.

## 2. Ein literales `$` gehoert als `$$` in die Datei — und nur dort

Portainer interpoliert den Stack-Wert, bevor er den Container erreicht; ein literales `$` muss dort als `$$` stehen, sonst kommt ein einzelnes `$` an.

| Datei | `AUTH_HASH` |
|---|---|
| `.env` (lokal, Mac) | `$2a$14$…` (laeuft ueber `local/run.sh`, ohne Portainer-Schritt) |
| `remote/.env.production` | `$$2a$$14$$…` (Portainer interpoliert) |

- `$$` in `remote/.env.production` **nie "reparieren"**. Im Zweifel gegen `docker inspect` auf dem VPS pruefen, nicht gegen einen lokalen `docker compose`-Lauf.
- Drei verschiedene `$$`-Mechanismen nicht verwechseln:
  1. **Portainer-Interpolation** — `environment:`-Wert, Datei `remote/.env.production`.
  2. **Compose-Heredoc** — `command: sh -c "cat << 'PYEOF' …"` in `remote/docker-compose.yml` bzw. `local/docker-compose.yml`. Hier muss jedes `$` im eingebetteten Python/Shell als `$$` stehen, sonst substituiert Compose selbst (`AUTH_HASH.startswith("$2")` & Co.) — **bleibt unangetastet**, auch wenn die Datei oben unescaped ist.
  3. **Caddyfile** — kein Escaping; `__OPENCODE_BASIC__` ist ein manuell per `base64` erzeugter Platzhalter (siehe Root-README).

## 3. Ein Login fuer beide Wege, nicht zwei

`code` (Mac-Tunnel) und `remote-code` (VPS) sind derselbe Zugang und teilen sich `AUTH_USER`, `AUTH_HASH` und `AUTH_SECRET`. **Drei** Quellen muessen synchron sein:

1. `.env` (lokal, gitignored)
2. `remote/.env.production` (gitignored, Portainer-Vorlage)
3. der laufende Portainer-Stack-Env

Aendert sich einer der Werte, ist die Login-Aenderung unvollstaendig, bis die anderen beiden nachgezogen und der Stack neu deployed ist.

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

`agents.todo.md` fuehrt die offenen Live-Punkte.
