# Tailscale im Remote-Image (`code-dev`) — Design und Betriebsregeln

**Status: umgesetzt im Repo, noch nicht live deployed.** `Dockerfile`,
`entrypoint.sh`, `docker-compose.yml` und `.env.example` enthalten den Weg; der
VPS laeuft noch auf dem alten Image. Was live fehlt, steht in Abschnitt 13
(Reihenfolge) und in `agents.todo.md`.

Zielsetzung: **Web-UI und lokal (in `code-dev`) gestartete Dev-Server** ueber
ein privates Netz erreichbar machen — vom Android-Handy, vom Mac und vom
Windows-PC.

Dieses Dokument ist zugleich die Begruendung: warum Userspace statt TUN, warum
`forward_auth` bleibt, und welche Ports ueberhaupt erreichbar sind.

---

## 1. Kurzantwort

| Frage | Antwort |
|---|---|
| Wie installiert man Tailscale im Image? | Debian-Repo + `apt install tailscale`, `tailscaled` im **Userspace-Modus** (`--tun=userspace-networking`) als Hintergrundprozess aus `entrypoint.sh`. **Ohne** TUN, **ohne** `NET_ADMIN`, **ohne** `privileged`, **ohne** Root. |
| Android / Mac / Windows? | Tailscale-App installieren, mit demselben Konto anmelden, dann `http://<name>.<tailnet>.ts.net:<port>` im Browser. Personal-Plan ist kostenlos, User-Geraete unbegrenzt. |
| Mehrere Ports? | **Ja.** Im Userspace-Modus leitet der Netzstack *jede* eingehende TCP-Verbindung auf die Tailnet-IP auf `127.0.0.1:<port>` **im selben Container** weiter. Jeder Port, auf dem in `code-dev` etwas lauscht, ist damit ohne Port-Publishing erreichbar. |
| Welche Ports *nicht*? | Alles, was nicht im Netzraum von `code-dev` laeuft: der `dind`-Daemon und seine Testcontainer (`db:5432`, `mailpit:8025`) sowie `code-auth-remote:8081`. Sie sind vom Tailnet aus **nicht** erreichbar. |

**Abgrenzung zu `remote-code.<domain>`:** der Tailnet-Weg ist ein **zweiter,
privater** Eingang. `forward_auth`, `code-auth-remote`, die Login-Seite und der
oeffentliche DNS-Eintrag bleiben unberuehrt — siehe Abschnitt 6. Der
Vorschlag, `forward_auth` abzuschalten und die Domain selbst zum Tailscale-
Endpunkt zu machen, ist in Abschnitt 6 geprueft und **verworfen**, mit
Begruendung.

---

## 2. Ausgangslage im Stack

Bisher gilt bewusst (siehe [`remote/AGENTS.md`](AGENTS.md) §3/§4 und
[`remote/README.md`](README.md)):

* `code-dev` hat **keine** veroeffentlichten Docker-Ports und **kein**
  `extra_hosts` — der einzige oeffentliche Eingang ist Caddy auf dem
  VPS-Host. Von aussen ist der Container nicht erreichbar.
* `dind` laeuft **rootless**, ohne Capabilities, ohne Host-Blockdevices.
* `127.0.0.1` in `code-dev` **ist** `code-dev`. Ein Dev-Server (`pnpm dev`) ist
  dort sofort ueber `127.0.0.1` erreichbar — nur eben nirgends sonst.

Der Tailnet-Weg aendert daran nichts. Er fuegt einen privaten Zugang *in den
Container* hinzu, ohne eine Tuer zum VPS-Host.

Der Nutzwert ist genau die Luecke aus `remote/README.md`: ein Dev-Server in
`code-dev` ist heute selbst fuer dich nicht erreichbar, weil es keinen
veroeffentlichten Port gibt und `extra_hosts` verboten ist.

---

## 3. Variante A (empfohlen): `tailscaled` im Image, Userspace-Modus

### 3.1 Was der Userspace-Modus kann — und was nicht

Belege: [Userspace networking](https://tailscale.com/docs/concepts/userspace-networking),
[LXC unprivileged](https://tailscale.com/docs/features/containers/lxc/lxc-unprivileged),
[tailscale#10267](https://github.com/tailscale/tailscale/issues/10267) und
[tailscale#17548](https://github.com/tailscale/tailscale/issues/17548) (Aussagen
von Tailscale-Mitarbeitenden), `ipn/ipnlocal/serve.go`.

| Eigenschaft | Userspace-Modus | Beleg / Bemerkung |
|---|---|---|
| Root noetig | **nein** | "avoids the need for any administrative access at all" |
| `/dev/net/tun` noetig | **nein** | "it avoids the need for any administrative access at all" |
| Capabilities noetig | **nein** | nur reines Userspace-TCP/IP (gVisor netstack) |
| **Eingehend** auf Tailnet-IP:Port | **ja**, wird auf `localhost:Port` im selben Container weitergeleitet | "incoming TCP connections to your Tailscale IP on port N already forward to `localhost:N`" |
| Ausgehend Richtung Tailnet | **nur** ueber SOCKS5/HTTP-Proxy (`127.0.0.1:1055`), nicht transparent | kein Routing-Eintrag, keine TUN |
| ICMP aus dem Container | nein | `tailscale ping` funktioniert, `ping` nicht |
| Subnet-Routing / Exit-Node | nein (transparent) | nicht benoetigt |
| `tailscale serve` | **ja**, der Netzstack faengt die Ports ab | Quellcode: "don't listen on netmap addresses if we're in userspace mode"; Reverse-Proxy-Ziel muss `http://127.0.0.1` sein |
| Funnel (oeffentlich) | nein | braucht oeffentlich erreichbaren Port — hier nicht gewollt |

**Konsequenz fuer die Isolation:** der Netzstack leitet auf das Loopback *von
`code-dev`* weiter. Der Tailnet-Pfad exponiert damit ausschliesslich die Ports
von `code-dev` selbst — nicht `dind`, nicht `code-auth-remote`, nicht den
VPS-Host. Das ist die starke Eigenschaft dieser Variante.

### 3.2 `remote/Dockerfile`

Ein `RUN`-Block im Stil der bestehenden Repo-Aufnahmen (Node, Sury, gh,
Docker-CLI), plus Verzeichnis fuer den State:

```dockerfile
# Tailscale (Userspace-Modus: kein TUN, keine Capabilities, kein Root).
# Bewusst das Debian-Paket und NICHT das offizielle Image tailscale/tailscale:
# dessen containerboot will PID 1 sein und wuerde den SIGTERM-Mechanismus
# aus AGENTS.md §10 (Autoupdate -> kill -TERM 1) zerstoeren.
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.gpg \
      | gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && chmod a+r /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" \
      > /etc/apt/sources.list.d/tailscale.list \
 && apt-get update && apt-get install -y --no-install-recommends tailscale \
 && tailscale version \
 && rm -rf /var/lib/apt/lists/*
```

Ergaenzend in die `dev`-User-Erzeugung: `mkdir -p
/home/dev/.local/share/tailscale`. **Kein** `EXPOSE`, **kein** `cap_add`, **kein**
`devices:` — genau das ist der Punkt der Variante.

Beide URLs sind geprueft (HTTP 200, Key 3179 Byte, `.list` mit `deb ... bookworm main`).

### 3.3 `remote/entrypoint.sh`

Ein Block **vor** dem `exec` (analog zum Update-Watcher, der ebenfalls vorher
geforkt wird), plus Erweiterung der Chown-Liste um den State-Pfad:

```bash
# Klarstellung zum Standardpfad: /var/lib/tailscale und
# /var/run/tailscale/tailscaled.sock sind root-gehoert. Der Container laeuft
# als uid 1000, deshalb liegen State und Socket unter $HOME.
TS_SOCK="$HOME/.local/share/tailscale/tailscaled.sock"
TS_STATE="$HOME/.local/share/tailscale/state"

start_tailscale() {
  # Nur wenn ein Key gesetzt ist; sonst laeuft der Weg ohne Tailnet weiter.
  [ -n "${TS_AUTHKEY:-}" ] || return 0
  mkdir -p "$TS_STATE"
  # --accept-dns=false ist Pflicht: tailscaled will sonst /etc/resolv.conf
  # umschreiben und damit Docker-DNS (127.0.0.11) im ganzen Container zerlegen.
  tailscaled --tun=userspace-networking --statedir="$TS_STATE" --socket="$TS_SOCK" &
  local i
  for i in $(seq 1 30); do
    tailscale --socket="$TS_SOCK" status >/dev/null 2>&1 && break
    sleep 1
  done
  # Auth-Key nur beim Erstlauf: danach reicht der persistierte State.
  if ! tailscale --socket="$TS_SOCK" status --json 2>/dev/null | grep -q BackendState; then
    tailscale --socket="$TS_SOCK" up --authkey="$TS_AUTHKEY" --accept-dns=false --hostname="${TS_TAILSCALE_HOSTNAME:-code-dev}"
  fi
}
```

Regeln dazu:

* `TS_AUTHKEY` kommt aus **`.env.production`**, nie ins Image
  (`AGENTS.md` §1: Secrets als Stack-Env).
* `tailscaled` ist ein Kindprozess von `entrypoint.sh` und stirbt mit dem
  Container. Die Node-Identitaet liegt im Volume, also ueberlebt sie
  Container-Recreates (AGENTS.md §8: named Volumes, genau dafuer).
* Kein Eingriff in den `kill -TERM 1`-Mechanismus (AGENTS.md §10).
* Der State-Pfad wandert in die bestehende Chown-Schleife, sonst ist das
  frisch gemountete Volume beim ersten Start root-gehoert.

### 3.4 `remote/docker-compose.yml`

Nur zwei additive Aenderungen an `code-dev` — **keine** Sicherheits-Aenderung:

```yaml
    environment:
      # … bestehende Zeilen …
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_TAILSCALE_HOSTNAME=${TS_TAILSCALE_HOSTNAME:-code-dev}
    volumes:
      # … bestehende Zeilen …
      - tailscale-state:/home/dev/.local/share/tailscale
```

```yaml
volumes:
  # …
  tailscale-state:
```

**Ausdruecklich nicht**: `cap_add`, `devices: /dev/net/tun`, `privileged`,
`security_opt`, `network_mode: host`, `extra_hosts`, `ports:`. Jeder dieser
Eintraege wuerde eine der bestehenden Regeln in `remote/AGENTS.md` aufweichen.

### 3.5 `.env.production` (gitignored, Handarbeit) + `.env.example`

```
TS_AUTHKEY=tskey-auth-…            # aus der Admin-Console, nie ins Repo
TS_TAILSCALE_HOSTNAME=code-dev     # kurzer MagicDNS-Name
```

Kein `$` im Wert, also keine `$$`-Falle aus `AGENTS.md` §2.

---

## 4. Ports: was ueber das Tailnet erreichbar wird

Alle Verbindungen landen im Loopback von `code-dev`. Die Liste ist damit
deterministisch und ohne Konfiguration:

| Dienst in `code-dev` | Port | ueber Tailnet? | Bedingung |
|---|---|---|---|
| `opencode serve` (Web-UI, API, SSE, PTY-WS) | 8080 | **ja** | lauscht auf `0.0.0.0` (so startet es der Entrypoint) |
| Dev-Server `pnpm dev` / `next dev` / `vite` | 3000, 5173, 8000 | **ja** | muss auf `127.0.0.1` **oder** `0.0.0.0` binden (`--host 0.0.0.0`) |
| Testcontainer im `dind` (`db:5432`, `mailpit:8025`) | – | **nein** | eigener Netzraum, `AGENTS.md` §7 |
| `dind`-Docker-API | 2375 | **nein** | eigener Netzraum, kein Loopback in `code-dev` |
| `code-auth-remote` | 8081 | **nein** | eigener Container, `127.0.0.1:8081` in `code-dev` ist nicht der Sidecar |

Fuer den letzten gewuenschten Fall (DB/Mailpit von aussen) waere ein kleiner
Forwarder **in `code-dev`** noetig, z. B. `socat TCP-LISTEN:5432,fork
TCP:db:5432`. Das ist bewusst nicht Teil dieses Plans, weil es `dind`-Ports
oeber eine zweite Auth-Schicht oeffnen wuerde — wenn, dann als eigener
Schritt mit eigener ACL-Regel.

`tailscale serve` ist dafuer **nicht** noetig. Es waere nur die Alternative,
wenn ein Name statt einer IP gewuenscht ist oder HTTPS erzwungen werden soll
(Abschnitt 8).

---

## 5. Zugriff von Android, macOS und Windows

Gemeinsam fuer alle drei: Tailscale-App aus dem Store, mit **demselben**
Tailscale-Konto anmelden, VPN aktiv. Danach ist `code-dev` ein normales
Tailnet-Geraet.

| Client | Vorgehen | Hinweise |
|---|---|---|
| **Android** | Play-Store-App starten, dann `http://code-dev.<tailnet>.ts.net:8080` in Chrome | VPN muss aktiv sein; Akkuoptimierung darf die App nicht stilllegen, sonst bricht die SSE-Verbindung nach Minuten ab. Ohne Basic-Auth kein Prompt. |
| **macOS** | App + Browser, oder `curl`/`ssh` im Terminal | `tailscale ping <name>` und `tailscale ip` als Diagnose |
| **Windows** | App + Browser; fuer SSH/PowerShell `tailscale.exe` im Pfad | Firewall-Dialog einmalig bestaetigen |

Aufloesung: MagicDNS laeuft **clientseitig**, deshalb funktioniert
`code-dev.<tailnet>.ts.net` auch dann, wenn der Container selbst
`--accept-dns=false` fahren muss. Notfalls ueber die 100.x-Adresse.

Kosten: Personal-Plan $0, unbegrenzte User-Geraete, bis zu 6 User, 50 getaggte
Ressourcen. Reicht fuer Handy + Mac + PC + Container.

---

## 5a. Was am Entrypoint getestet wurde — und was nicht

Der Block in `entrypoint.sh` wurde **ausserhalb des Containers** getestet: mit
`tailscaled`/`tailscale` als Attrappen (echter Unix-Socket via
`socket.bind`, JSON-Ausgabe des Status) und der **echten**, per Regex
extrahierten Funktion. Vier Szenarien:

| Szenario | `TS_AUTHKEY` | `BackendState` | Ergebnis |
|---|---|---|---|
| Erstlauf | gesetzt | `NeedsLogin` | `tailscale up` mit Key, Host und `--accept-dns=false` |
| Stack-Recreate | gesetzt | `Running` | **kein** erneutes `up` (sonst neue Node-Identitaet) |
| Kein Key | leer | `NoState` | uebersprungen, kein `tailscaled` gestartet |
| `tailscaled` startet nicht | gesetzt | – | Warnung, Rueckgabe 0, `opencode serve` startet normal |

**Nicht getestet und damit noch offen:** das echte `tailscaled` (Netzwerk,
Control-Server, Zertifikate), ein echter Tailnet-Handshake, und die Erreichbar-
keit ueber die 100.x-Adresse. Das geht nur mit einem Key und einem laufenden
Client — siehe `agents.todo.md`.

Ein Detail, das beim Bauen des Tests Zeit gekostet hat und beim naechsten Mal
nicht wieder: `tailscaled` legt einen **Unix-Socket** an, keine Datei. Ein
Prüfbefehl wie `[ -f ]` oder eine Attrappe, die nur `touch` macht, schlägt fehl
und sieht wie ein Fehler im Entrypoint aus. Richtig ist `[ -S ]` — genau das
steht jetzt im Code.

---

## 6. Warum `forward_auth` an bleibt und die Domain unveraendert bleibt

Der Vorschlag lautete: `forward_auth` abschalten und `remote-code.<domain>`
selbst zum Tailscale-Endpunkt machen. Beide Teile sind einzeln geprueft und
**beide sind falsch**. Hier die Begruendung, damit das nicht spaeter erneut
vorgeschlagen wird.

### Der Mechanismus, den es dafuer nicht gibt

Tailscale ist ein **Overlay auf Layer 3**. Es gibt keine Funktion
„Domain auf einen Tailnet-Endpunkt legen". Konkret:

* **Der DNS-Name aendert sich nicht.** `remote-code.<domain>` ist ein
  oeffentlicher A-Record auf die **oeffentliche** IP des VPS. Tailscale
  aendert daran nichts — die Domain zeigt weiterhin nach aussen, egal was im
  Tailnet passiert.
* **Der Aufruf landet weiterhin bei Caddy**, nicht im Container. Caddy laeuft
  auf dem VPS-Host, nicht im Tailnet. Ohne Tailscale auf dem **Host** (das ist
  bewusst Variante C und hier nicht gewaehlt) erreicht ein Tailnet-Paket die
  Domain gar nicht, sondern nur `100.x.x.x:8080` direkt.
* **Fuer einen echten Domain-Umweg** gaebe es nur zwei Wege, beide mit
  Nebenwirkung: oeffentliches DNS auf die Tailnet-IP umhaengen (dann ist die
  Domain **offline**, sobald kein Geraet im Tailnet ist) oder `extraDNSRecords`
  in der Tailnet-Policy (das ist laut Tailscale-Doku ein **Support-Fall**, kein
  Selbstbau, und `override_local_dns` waere die Nebenwirkung). Beides ist fuer
  einen zweiten privaten Zugang deutlich zu teuer.

**Fazit:** es gibt nichts abzuschalten. Der Tailnet-Weg **umgeht** Caddy
komplett — er erreicht `code-dev` direkt auf Port 8080. `forward_auth` ist im
Tailnet-Pfad nie beteiligt.

### Warum die Kette auf `forward_auth` trotzdem stehen bleibt

`forward_auth` ist der Schutz des **oeffentlichen** Wegs. Auch wenn man ihn
entfernen wuerde, waere die oeffentliche Seite ungeschuetzt — der Server
selektiert nach `Host`, nicht nach Quelle:

* `remote-code.<domain>` **ohne** `forward_auth` heisst: jeder im Internet
  erreicht `code-dev` und damit die volle Agent-API. Das Caddy-Fragment
  injiziert `header_up Authorization "__OPENCODE_BASIC__"` — der Browser
  bekommt das Passwort also nie zu sehen, es ist ein reiner Server-zu-Server-
  Sprung. Der *gesamte* Schutz dieses Weges ist der Cookie-Gate davor. Ohne
  ihn ist der Weg offen, unabhaengig davon, ob OpenCode selbst ein Passwort hat.
* `code.<domain>` (der Mac-Tunnel) ist derselbe Aufbau und haengt an derselben
  Kette. Ein Eingriff dort betrifft **beide** Wege.

Das ist genau die Sorte Aenderung, die laut `remote/AGENTS.md` §11 (Auth-Checks
nicht vereinfachen) und §3 (kein Host-Zugriff) schon einmal eine
Fehlermeldung erzeugt hat. Der oeffentliche Weg bleibt deshalb unveraendert;
hinzu kommt ein privater Weg. Beide teilen sich denselben OpenCode-Prozess und
dieselben Projekte, nur mit unterschiedlichen Eingangstueren.

### Was das praktisch heisst

| | `remote-code.<domain>` | `100.x.x.x:8080` / `<name>.ts.net:8080` |
|---|---|---|
| Erreichbar von | ueberall im Internet | nur von Geraeten im Tailnet |
| Schutz | Cookie-Gate (`forward_auth`) | Tailnet-ACL |
| Caddy beteiligt | ja | **nein** |
| `code-auth-remote` beteiligt | ja | nein |
| TLS | ja, Let's Encrypt | nein (bzw. `tailscale serve`, Abschnitt 8) |

Es ist also kein Entweder-oder: die Domain bleibt der bequeme Weg vom
Laptop, die Tailnet-IP ist der private Weg fuer Handy und Dev-Server-Ports.

---

## 7. Auth: was mit dem Serverpasswort passiert

Gewuenscht ist: Passwort nur auf dem oeffentlichen Weg, ueber Tailnet
passwortfrei. Technisch ist das moeglich, weil **`OPENCODE_SERVER_PASSWORD` bei
`opencode serve` optional ist** — ohne die Variable laeuft der Server
unauthentifiziert und gibt nur eine Warnung aus
([Server-Doku](https://opencode.ai/docs/server/),
[CLI-Doku](https://opencode.ai/docs/cli/)).

### Variante 1 (empfohlen, entspricht dem Wunsch): kein Serverpasswort

* **Oeffentlicher Weg bleibt geschuetzt.** Das Cookie-Gate sitzt in Cadys
  `forward_auth` → `code-auth-remote` und ist von `OPENCODE_SERVER_PASSWORD`
  unabhaengig. Cadys `header_up Authorization` wird vom Server dann ignoriert —
  die Kette `Login-Seite → Cookie → forward_auth` wirkt trotzdem.
* **Tailnet-Weg** schuetzt nur noch die Tailnet-ACL. Das ist der bewusst
  akzeptierte Preis, und deshalb ist die ACL in Abschnitt 10 **Pflicht**, nicht
  Kür.

Drei Stellen im Bestand muessen dafuer angepasst werden (sonst startet der
Container nicht):

| Stelle | Heute | Warum |
|---|---|---|
| `entrypoint.sh` Zeile 164 | bricht ohne `OPENCODE_PASSWORD` mit `exit 1` ab | Pflicht-Check muss auf "Passwort *oder* bewusst ohne" umgestellt werden |
| `Dockerfile` HEALTHCHECK | `curl -u "opencode:${OPENCODE_PASSWORD:-...}"` | Header wird ignoriert, funktioniert — aber die/leere Variante ist live zu pruefen |
| `entrypoint.sh` `server_idle` | fragt `/api/session/active` mit `-u` | dito; entscheidet ueber den Autoupdate-Neustart |

Zusaetzlich zu pruefen: `opencode serve --hostname 0.0.0.0` **ohne** Passwort
ist in neueren Builds mit einer Bestaetigung belegt (TTY: Rueckfrage, non-TTY:
`--yes`). Der Entrypoint laeuft non-TTY, also ist das ein echter
Abbruchpunkt. **Vorher mit dem konkreten Binary testen**, nicht annehmen.

### Variante 2 (Fallback, wenn 1 nicht will): Passwort bleibt

Dann gilt derselbe Basic-Auth mit `opencode` + dem Passwort, das auch die
Login-Seite nutzt. Ein Passwort, beide Wege, kein zusaetzlicher Container. Auf
Android ist mit dem Browser-Prompt zu rechnen, der sich merkt.

**Nicht** machen: Cookie-Gate in den Container verlagern (zweite
`code-auth`-Instanz plus Caddy in `code-dev`). Das waere eine neue Komponente
im Image fuer einen Zugang, den die ACL bereits abdeckt.

---

## 8. HTTPS und Browser-Funktionen

Ueber `http://100.x.x.x:8080` ist die Web-UI erreichbar, aber ein Browser
betrachtet das nur als *secure context*, wenn die Seite localhost ist. Konkret
kann das auffallen bei Service Worker, `crypto.subtle` und Clipboard-Zugriff.
Das Caddy-Fragment neutralisiert den SW-Precache bereits bewusst — die
Web-Oberflaeche selbst laeuft aber same-origin und sollte ohne HTTPS laufen.

Falls sich die Web-UI auf Android *tatsaechlich* weigert, gibt es genau einen
sauberen Weg:

```bash
# Ziel MUSS 127.0.0.1 sein (Tailscale-Doku: "only http://127.0.0.1 is supported").
tailscale --socket=… serve --bg --https=443 http://127.0.0.1:8080
```

Damit gibt es ein echtes Zertifikat fuer `code-dev.<tailnet>.ts.net` (HTTPS muss
im Tailnet aktiviert sein) — und **ohne** die oeffentliche Domain.

**Bekannter Stolperstein:** im Userspace-Modus haengt der TLS-1.3-Handshake in
tailscale v1.98.4 ([tailscale#20196](https://github.com/tailscale/tailscale/issues/20196));
gefixt in v1.101.70. Da das Image taeglich neu gebaut wird und sonst nichts
pinnt, ist die tatsaechlich installierte Version im Build-Schritt
**mitzuprinfen** (`tailscale version`). Notloesung am Client: `--tls-max 1.2`.

**CORS-Hinweis:** ein Dev-Server, der die OpenCode-API direkt anspricht, braucht
`--cors http://<name>.<tailnet>.ts.net:<port>` — voreingestellt sind nur
localhost-Origins. Fuer die Web-UI selbst ist das irrelevant (same-origin).

---

## 9. Ablauf im Betrieb

1. Tailnet in der Admin-Console anlegen, ACL setzen.
2. Auth-Key erzeugen (ephemeral: **nein**, der Node soll dauerhaft sein).
3. `TS_AUTHKEY` + `TS_TAILSCALE_HOSTNAME` in `.env.production` eintragen.
4. Image bauen lassen (CI `workflow_dispatch` oder der Daily-Lauf 04:00 UTC),
   `IMAGE` auf den neuen Tag zeigen, Stack in Portainer neu deployen.
5. Beim ersten Start meldet sich der Node automatisch an. `TS_AUTHKEY` kann
   danach aus `.env.production` raus, der State im Volume reicht.
6. Clients anmelden, testen.

Einwaertige Besonderheit: der Autoupdate-Watcher beendet den Container per
SIGTERM, wenn ein neues opencode-Binary da ist und keine Session laeuft
(`AGENTS.md` §10). `tailscaled` faellt dabei mit, kommt beim Neustart mit
persistiertem State und **gleicher** Tailnet-IP zurueck. Fuer die Dauer des
Neustarts (wenige Sekunden) ist der Tailnet-Zugang nicht erreichbar — das ist
erwartet und kein Fehler.

---

## 10. Sicherheits- und Betriebsregeln (Vorschlag fuer `remote/AGENTS.md`)

1. **Kein TUN, keine Capabilities.** Taucht `cap_add: NET_ADMIN` oder
   `devices: /dev/net/tun` bei `code-dev` auf, ist die Begruendung "fuer
   Tailscale noetig" falsch — der Userspace-Modus braucht beides nicht.
2. **`--accept-dns=false` bleibt Pflicht.** Sonst schreibt `tailscaled`
   `/etc/resolv.conf` um und Docker-DNS faellt im ganzen Container aus.
3. **Kein `network_mode: host`, kein `extra_hosts`, keine `ports:` fuer den
   Tailnet-Weg.** Der Weg ist die Tailnet-IP, nicht ein veroeffentlichter Port.
4. **`forward_auth` bleibt, `remote-code.<domain>` bleibt oeffentlich.** Der
   Tailnet-Weg ist ein *zusaetzlicher* Eingang, kein Ersatz. Wer die
   Cookie-Kette entfernt, macht den oeffentlichen Weg ungeschuetzt — die
   injizierte `header_up Authorization` ist kein Ersatz fuer ein Gate, weil der
   Browser das Passwort nie zu sehen bekommt. Begruendung: Abschnitt 6.
5. **ACL ist Teil der Installation, nicht ein Nachschritt.** Ohne
   Serverpasswort ist die ACL der einzige Schutz des vollen Agent-API-Zugriffs.
   Zielregel: nur eigene Geraete, kein `*:*`, Port `8080` + Dev-Server-Ports
   explizit, kein Tagged-Resource-Wildwuchs.
6. **Auth-Key nie ins Repo, nie ins Image.** Wie `OPENCODE_PASSWORD` und
   `AUTH_SECRET` nur ueber `.env.production`.
7. **State ist ein Named Volume.** `tailscale-state` ueberlebt Image-Upgrades
   (AGENTS.md §8). Fehlt das Volume, ist die Tailnet-IP nach jedem Recreate
   eine neue und der Node ballt sich in der Admin-Console auf.
8. **Ein Fehler im Tailnet darf den Container nie blockieren.** Der Block in
   `entrypoint.sh` ist so gebaut, dass ein Tailscale-Problem (kein Netz, falscher
   Key, Port belegt) den Start von `opencode serve` nicht verhindert.

---

## 11. Verifikation (read-only, erst nach dem Deploy)

Auf dem VPS:

```bash
# Node da, Version bekannt, Backend haengt am Control
docker exec code-dev tailscale --socket=/home/dev/.local/share/tailscale/tailscaled.sock status
docker exec code-dev tailscale --socket=/home/dev/.local/share/tailscale/tailscaled.sock ip -4
docker exec code-dev tailscale --socket=/home/dev/.local/share/tailscale/tailscaled.sock version

# Welche Ports in code-dev ueberhaupt lauschen
docker exec code-dev ss -ltnp

# RAM-Verschiebung durch den netstack
docker stats --no-stream code-dev
```

Vom Tailnet (Mac/PC/Handy, Tailscale aktiv):

```bash
tailscale ping code-dev                                   # direkt oder via DERP
curl -sS -o /dev/null -w '%{http_code}\n' http://100.x.x.x:8080/api/info   # 200 ohne Passwort
curl -N -m 10 http://100.x.x.x:8080/api/event | head -3                    # SSE: erste Zeile server.connected
curl -sS -o /dev/null -w '%{http_code}\n' http://100.x.x.x:3000/            # Dev-Server, falls laeuft
```

**Gegenproben, die schiefgehen muessen** (Isolation):

```bash
curl -sS -m 3 http://100.x.x.x:2375/_ping   # muss fehlschlagen (dind, anderer Netzraum)
curl -sS -m 3 http://100.x.x.x:8081/        # muss fehlschlagen (code-auth-remote)
```

Dazu in der Browser-DevTools mit "Preserve log": `/api/event` bleibt
`200 text/event-stream`, der PTY-WebSocket liefert `101 Switching Protocols` —
beides ueber den Tailnet, ohne Caddy dazwischen.

**Abbruchkriterien** (Plan wird nicht weiterverfolgt, wenn eines zutrifft):

* `tailscaled` startet nicht ohne TUN/Capabilities.
* SSE oder PTY brechen ueber den Tailnet nach, aber nicht ueber Caddy.
* Die Tailnet-IP aendert sich nach `docker restart code-dev`.
* Ein DinD-Port oder `code-auth-remote` ist vom Tailnet aus erreichbar.
* Die Web-UI laeuft auf Android nur mit HTTPS → dann Abschnitt 8 *vor* dem
  naechsten Plan, nicht nebenbei.
* `remote-code.<domain>` antwortet **nach** dem Tailnet-Deploy ohne Cookie mit
  `200` auf `/api/info` → sofort zurueckrollen. Das hiesse, dass die oeffentliche
  Kette weg ist; der Tailnet-Wag darf sie nicht beruehren.

---

## 12. Risiken und offene Punkte

| Punkt | Einschaetzung |
|---|---|
| TLS-1.3-Bug im Userspace-Modus (#20196) | betrifft nur `tailscale serve --https`; die Standardvariante (plain HTTP ueber WireGuard) ist nicht betroffen. Version im Image ausgeben. |
| `opencode serve` ohne Passwort auf `0.0.0.0` | Startverhalten in neueren Builds pruefen (non-TTY → Abbruch moeglich). |
| Paket-Installation im Build ohne systemd | `tailscale` legt eine Unit an; `dpkg` sollte das im Image noetigenfalls no-op behandeln. Ein Fehler waere ein **Build**-Fehler, kein Laufzeit-Fehler — sichtbar vor jedem Deploy. |
| Ohne Serverpasswort | Vollzugriff auf die Agent-API fuer jedes Geraet im Tailnet. Mitigation ist ausschliesslich die ACL. |
| Zwei Clients gleichzeitig (Caddy + Tailnet) | zwei Browser auf einer Instanz ist fuer OpenCode normal; Session-Anzeige kann zuletzt mitlaufen. Beobachten, nicht blockieren. |
| Version driftet mit dem Daily-CI | das Image pinnt sonst nichts (bewusst, siehe Dockerfile-Kommentar). Fuer Tailscale entweder so bleiben oder eine Mindestversion als `ARG` setzen — Entscheidung bei der Umsetzung. |
| `tailscale serve`-Persistenz | Serve-Config liegt im State und ueberlebt damit einen Container-Restart; nach einem **Recreate mit leerem Volume** waere sie weg. Nur relevant, wenn Abschnitt 8 genutzt wird. |
| Erwartungshaltung "Tailscale macht die Domain privat" | verbreitete Fehlvorstellung, siehe Abschnitt 6. Tailscale aendert **keinen** oeffentlichen DNS-Eintrag. Wer nach dem Deploy `remote-code.<domain>` ohne VPN nicht erreichbar erwartet, hat einen falschen Test gemacht — die Domain ist per Definition immer öffentlich. Umgekehrt ist die Tailnet-IP **nicht** erreichbar, wenn das VPN aus ist. Das ist die richtige Richtung. |

---

## 13. Reihenfolge der Umsetzung

Erledigt im Repo:

- [x] 1. `remote/Dockerfile`: Debian-Repo + `apt install tailscale`, State-Verzeichnis.
      **Kein** `EXPOSE`, keine Capabilities, keine Devices. Die `RUN`-Kette mit
      eingebettetem Kommentar wurde per Test-Build verifiziert (Kommentar wird
      entfernt, Kette bleibt intakt, uid 1000 schreibt in `/tmp/opencode`).
- [x] 2. `remote/entrypoint.sh`: `start_tailscale()` vor dem `exec`, Chown-Liste
      erweitert. Logik gegen Attrappen getestet (Abschnitt 5a).
- [x] 3. `remote/docker-compose.yml`: zwei Env-Zeilen + `tailscale-state`-Volume.
      YAML geparst: kein `cap_add`, kein `devices`, kein `ports`, kein
      `extra_hosts`, kein `network_mode`.
- [x] 4. `.env.example` ergaenzt.
- [x] 8. Doku: `remote/AGENTS.md` §15, dieser Plan, `.env.example`-Kommentar.
      **Noch offen:** ein Bedienungsabschnitt in `remote/README.md` und die
      Strukturzeile im Root-`README.md`.

Offen, braucht Handarbeit bzw. den VPS:

- [ ] 5. In der Tailscale-Admin-Console: Tailnet anlegen bzw. oeffnen, ACL mit
      **nur** den eigenen Geraeten und expliziten Ports setzen, Auth-Key
      erzeugen (nicht ephemer).
- [ ] 6. `TS_AUTHKEY` + `TS_TAILSCALE_HOSTNAME` in `remote/.env.production`
      (gitignored, Handarbeit — `AGENTS.md` §1).
- [ ] 7. Image bauen (CI `workflow_dispatch` oder Daily 04:00 UTC), `IMAGE` auf
      den neuen Tag, Stack in Portainer neu deployen.
- [ ] 8. Clients anmelden (Android, macOS, Windows).
- [ ] 9. Verifikation aus Abschnitt 11 inklusive der Gegenproben.
- [ ] 10. Abnahme erst nach unabhaengigem Review der Live-Verifikation — so wie
      bei `df9fe4d` in `agents.todo.md`.

---

## 14. Quellen

* [Userspace networking](https://tailscale.com/docs/concepts/userspace-networking) — SOCKS5/HTTP, `--tun=userspace-networking`, kein TUN
* [LXC unprivileged](https://tailscale.com/docs/features/containers/lxc/lxc-unprivileged) — "avoids the need for any administrative access at all"
* [tailscale#10267](https://github.com/tailscale/tailscale/issues/10267) — "userspace-networking can handle incoming connections by sending them to a socket listening on `localhost`"
* [tailscale#17548](https://github.com/tailscale/tailscale/issues/17548) — "incoming TCP connections to your Tailscale IP on port N already forward to `localhost:N`"
* [`ipn/ipnlocal/serve.go`](https://github.com/tailscale/tailscale/blob/main/ipn/ipnlocal/serve.go) — "don't listen on netmap addresses if we're in userspace mode"
* [`tailscale serve`](https://tailscale.com/kb/1242/tailscale-serve) — `--tcp`, `--bg`, Reverse-Proxy-Ziel nur `http://127.0.0.1`
* [tailscale#20196](https://github.com/tailscale/tailscale/issues/20196) — TLS-1.3-Handshake im Userspace-Modus
* [Docker-Parameter](https://tailscale.com/docs/features/containers/docker/docker-params) — `TS_USERSPACE`, `TS_STATE_DIR`, `TS_AUTHKEY`, `TS_AUTH_ONCE`
* [opencode Server](https://opencode.ai/docs/server/) / [CLI](https://opencode.ai/docs/cli/) — `OPENCODE_SERVER_PASSWORD` optional, CORS-Defaults
* [Tailscale Pricing](https://tailscale.com/pricing) — Personal-Plan: unbegrenzte User-Geraete, 6 User, 50 tagged Ressourcen
* Paketquellen geprueft: `pkgs.tailscale.com/stable/debian/bookworm.gpg` (200),
  `pkgs.tailscale.com/stable/debian/bookworm.list` (200)
