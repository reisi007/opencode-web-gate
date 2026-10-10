# AGENTS.md — Regeln fuer dieses Repo

Kurz, weil die Regeln hier teuer waren.

## 1. `remote/.env.production` ist eine Portainer-Paste-Vorlage

Diese Datei wird **1:1 in die Portainer-UI** kopiert
(Stack `code-remote` → Environment → Stack Environment). Sie ist gitignored
und trotzdem die *einzige* Quelle fuer den laufenden Remote-Stack.

Konsequenzen:

- **Kein Kommentar-Zeilen-umbau, kein Aufraeumen, kein " sieht komisch aus ".**
  Der Inhalt wird unveraendert gepflegt und genau so eingefuegt.
- Jede Zeile, die nach dem Einfuegen in Portainer `KEY=WERT` ergeben muss,
  bleibt eine solche Zeile.
- Nach jedem Aendern an der Datei: der Stack muss in Portainer neu deployed
  werden, sonst laeuft weiter der alte Stand. Die Datei selbst deployt nichts.
- `setup.sh` erzeugt **nur** `.env`, nie `.env.production`. Der Weg von der
  `.env` hierher ist Handarbeit und der wahrscheinlichste Drift-Punkt.

## 2. Ein literales `$` gehoert als `$$` in die Datei — und nur dort

Portainer interpolated den Stack-Wert, bevor er den Container erreicht. Ein
literales `$` muss dort als `$$` geschrieben werden, sonst kommt ein einzelnes
`$` im Container an.

| Datei | `AUTH_HASH` | Warum |
|---|---|---|
| `.env` (lokal, Mac) | `$2a$14$…` | laeuft ueber `local/run.sh`, **ohne** Portainer-Schritt |
| `remote/.env.production` | `$$2a$$14$$…` | wird von Portainer interpoliert |

**Der Doppeldollar ist der Portainer-Pflichtweg.** `AUTH_HASH` ist der
einzige Wert in `.env.production`, der davon betroffen ist (bcrypt hat 3 `$`:
Praefix + Kosten + Salt-Trenner) — alle anderen Werte enthalten kein `$`.

### Die Falle, warum das schon einmal falsch "repariert" wurde

`docker compose --env-file` escaped `$$` **nicht** — lokal getestet:

```bash
printf 'AUTH_HASH=$$2a$$14$$abc\n' > .env.test
printf 'services:\n  t:\n    image: alpine\n    environment:\n      - AUTH_HASH=${AUTH_HASH}\n' > docker-compose.yml
docker compose --env-file .env.test config --format json \
  | python3 -c 'import json,sys; print(repr(json.load(sys.stdin)["services"]["t"]["environment"]["AUTH_HASH"]))'
# => '$$2a$$14$$abc'   <-- kommt DOPPELT escaped an, also kaputt
```

Wer also lokal mit `docker compose` testet, sieht den Wert doppelt escaped
und "repariert" ihn auf `$2a$…` zurueck. Genau das war die Fehlermeldung auf
`remote-code`. Live dagegen ist der Ist-Stand korrekt:

```bash
docker inspect code-auth-remote --format '{{range .Config.Env}}{{println .}}{{end}}' | grep AUTH_HASH
# => AUTH_HASH=$2a$14$…      <-- Portainer hat korrekt unescaped
```

**Also: `$$` in `remote/.env.production` nie "reparieren".** Im Zweifel gegen
`docker inspect` auf dem VPS pruefen, nicht gegen einen lokalen Compose-Lauf.

### Nicht verwechseln: drei verschiedene `$$`-Mechanismen

1. **Portainer-Interpolation** — `environment:`-Wert, Datei `remote/.env.production`.
2. **Compose-Heredoc** — `command: sh -c "cat << 'PYEOF' …"` in
   `remote/docker-compose.yml` bzw. `local/docker-compose.yml`. Hier muss jedes
   `$` im eingebetteten Python/Shell als `$$` stehen, weil Compose es sonst
   selbst substituiert. Das betrifft `AUTH_HASH.startswith("$2")` & Co.
   — **bleibt unangetastet**, auch wenn die Datei oben unescaped ist.
3. **Caddyfile** — dort gibt es kein Escaping, `__OPENCODE_BASIC__` ist ein
   manuell per `base64` erzeugter Platzhalter (siehe Root-README).

## 3. Ein Login fuer beide Wege, nicht zwei

`code` (Mac-Tunnel) und `remote-code` (VPS) sind derselbe Zugang fuer
dieselbe Person. Sie teilen sich `AUTH_USER`, `AUTH_HASH` und `AUTH_SECRET` —
jeweils aus **drei** Quellen, die synchron sein muessen:

1. `.env` (lokal, gitignored)
2. `remote/.env.production` (gitignored, Portainer-Vorlage)
3. dem laufenden Portainer-Stack-Env (nur dort sichtbar)

Aendert sich einer dieser drei Werte, ist die Login-Aenderung unvollstaendig,
bis die anderen beiden nachgezogen und der Stack neu deployed ist. Merksatz:
`AUTH_HASH` ist der Hash **eines** Passworts fuer **beide** Domains.

## 4. Zwei Passwoerter, die nicht dasselbe sind

| Variable | Wo | Zweck |
|---|---|---|
| `AUTH_HASH` | code-auth-Sidecar | Login-Seite (Cookie-Gate), bcrypt, User `AUTH_USER` |
| `OPENCODE_PASSWORD` | code-dev / `opencode serve` | Server-Passwort, das Caddy per `header_up Authorization` upstream injiziert |

`OPENCODE_PASSWORD` darf pro Weg verschieden sein (der Mac laeuft mit dem
lokalen Wert, `code-dev` mit dem aus `remote/.env.production`) — Caddy
injiziert pro Block den passenden Wert. **Der Login der Login-Seite hat damit
nichts zu tun.** Ein 401 auf `/api/info` ist ein Basic-Problem, ein 401 auf
`/api/login` ist ein `AUTH_HASH`-Problem.

### Die API-Edge-Gate prueft die Login-Kennung, NICHT das Server-Passwort (2026-10-08)

Die `/api/*`-Gate in `caddyfile/Caddyfile` (`@api_ok`, **beide** Bloecke)
matcht exakt `Authorization: Basic base64("<AUTH_USER>:<Login-Passwort>")` —
dieselbe Kennung wie die Login-Seite, nur base64-eingebettet. Der Upstream
sieht davon nichts: `header_up Authorization` setzt weiterhin
`base64("opencode:<OPENCODE_PASSWORD>")`. Edge-Kennung und Server-Passwort
sind damit absichtlich **verschieden** und rotieren getrennt — die
Caddy-Proxy-Auth ist nicht die des Zielservers. Das nicht „vereinheitlichen".

Folge bei Rotation des Login-Passworts: **drei** Stellen nachziehen —
`AUTH_HASH` (bcrypt, Sidecar), den `@api_ok`-base64-Wert in
`caddyfile/Caddyfile` (**beide** Bloecke) und die App-/PWA-Konfiguration.
Ein 401 auf `/api/*` bei korrektem Login-Passwort heisst: der base64-Wert im
`@api_ok` passt nicht (User-Teil muss `AUTH_USER` sein).

**Zweite 401-Ursache, am 2026-10-10 gemessen:** der Tunnel-Block von
`code.all-the.rest` in `caddyfile/Caddyfile` injizierte mit dem `code-dev`-Wert
aus `remote/.env.production` statt mit dem Mac-Wert aus `.env`. Dann antwortet
`opencode serve` 401, der Healthcheck markiert den Upstream `down` und
`handle_errors` liefert `tunnel-down.html` — obwohl der Tunnel **steht** (Lauscher
auf `172.18.0.1:18731`, durch den Tunnel mit dem richtigen Wert HTTP 200).
Unterscheidung: `handle_errors`-Seite + Healthcheck-Log (`unexpected status code
401`) statt `connection refused`. Regel in [`local/AGENTS.md`](local/AGENTS.md) §10.

## 5. Verifikations-Befehle (VPS, read-only)

Vor Jeder Aussage "Login ist synchron" messen, nicht raten:

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

Erwartetes Ergebnis bei synchronem Stand: gleiche Variablen, gleicher User,
gleiches Secret, `AUTH_HASH: identisch`, Form `$2a$1…`.
(Zustand vom 2026-09-26: erfuellt. `HOST_GATEWAY` wurde aus `.env.production`
und `.env.example` entfernt — siehe [`remote/AGENTS.md`](remote/AGENTS.md) §3.)

`agents.todo.md` fuehrt die offenen Live-Punkte — nach gelegter Arbeit wird
dort abgehakt, nicht hier.
