#!/usr/bin/env bash
# run.sh: Website syncen (rsync/ssh) + SSH-Reverse-Tunnel starten.
# Flags: --sync-only | --tunnel-only | (default: beides)
#
# WICHTIG (Tunnel-Ownership): Der Tunnel laeuft mit ControlMaster=no und wird von
# autossh ueberwacht — er haengt an KEINER Master-Connection. Sonst stirbt der
# Forward mit der Master-Connection, ohne dass autossh neu verbindet (das war
# die Ursache fuer "Tunnel liegt tot, obwohl autossh laeuft"). Die Master-
# Connection (ControlPersist) bleibt nur fuer Erfolgswaechter + diagnose.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Doppelklick (.command) startet mit minimalem PATH -> Werkzeuge auffindbar machen
export PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -f ../.env ]; then
  # shellcheck disable=SC1091
  source ../.env
elif [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
else
  echo ".env fehlt -> ../setup.sh"; exit 1
fi

MASTER_PATH='/tmp/ssh-code-%r@%h:%p'
TARGET="${SSH_TARGET:-user@vps.example.com}"
PORT="${SSH_PORT:-22}"
# Bind-Adresse des Forwards AUF DEM VPS: Docker-Bridge-Gateway (webnet: 172.18.0.1),
# damit der Caddy-Container (Bridge-Netz, eigener Loopback!) den Tunnel erreicht.
# Braucht serverseitig: GatewayPorts clientspecified (siehe README).
BIND="${REMOTE_BIND:-172.18.0.1}"
REMOTE="${REMOTE_PORT:-18731}"

MODE="${1:-all}"

# Port des gemeinsamen OpenCode-Dienstes — des Servers, an dem auch die TUI
# haengt. Die Ableitung liegt in service-port.sh: Start, Stopp und Diagnose
# muessen denselben Port treffen, den die -R-Bindung benutzt; vier Kopien waeren
# stille Drift. Stimmt der Port nicht, zeigt die Bindung ins Leere — deshalb
# lieber leer zurueckgeben und hier hart abbrechen. Ausnahme: --sync-only baut
# keinen Tunnel, dort ist der Port irrelevant (der reine Website-Sync darf nicht
# an einem fehlenden Dienst scheitern).
# Kein harter Abbruch hier: bei gestopptem Dienst liefert `opencode service
# status` nur "stopped", und ensure_service startet ihn weiter unten (und zieht
# den Port danach nach). Erst dort ist ein leerer Port endgueltig ein Fehler.
# shellcheck source=service-port.sh
. ./service-port.sh
LOCAL="$(service_port)" || true

# Key-Auth (setzt bootstrap.sh, Werte in .env): unbeaufsichtigter Betrieb ohne
# Passphrase-Prompt. UseKeychain=yes ist der Punkt, der den Key ohne TTY
# entsperrt — launchd startet ssh ohne Terminal, die Passphrase kommt aus der
# macOS-Keychain (einmalig via 'ssh-add --apple-use-keychain' hinterlegt).
KEY_OPTS=()
if [ "${SSH_KEY_AUTH:-0}" = 1 ] && [ -n "${SSH_IDENTITY:-}" ] && [ -f "$SSH_IDENTITY" ]; then
  KEY_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o UseKeychain=yes -i "$SSH_IDENTITY")
fi
# Waechter/Diagnose: eine Master-Connection, 60s Idle-Persist (1x Passphrase).
WATCH_OPTS=(-o ControlMaster=auto -o ControlPath="$MASTER_PATH" -o ControlPersist=60)
# Tunnel: eigene TCP-Verbindung, die autossh besitzt und neu aufbauen kann.
TUNNEL_OPTS=(-o ControlMaster=no -o ControlPath=none -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes)
if [ "${#KEY_OPTS[@]}" -gt 0 ]; then
  WATCH_OPTS+=("${KEY_OPTS[@]}")
  TUNNEL_OPTS+=("${KEY_OPTS[@]}")
fi

# Logs koennen Session-Inhalte enthalten -> nur fuer den Besitzer lesbar. Die plist
# setzt Umask 077, das greift aber nur bei NEUEN Dateien; bestehende aus einem
# frueheren Lauf bleiben sonst world-readable.
chmod 600 /tmp/code-tunnel.log 2>/dev/null || true
echo "[$(date '+%F %T')] run.sh start (Modus: $MODE, Key-Auth: $([ "${#KEY_OPTS[@]}" -gt 0 ] && echo ja || echo nein))"
# OpenCode-eigenes Serverpasswort (Pflicht): der Dienst erzwingt Auth, Caddy
# injiziert es upstream per Header -> im Browser unsichtbar (de facto
# deaktiviert). run.sh setzt es unten per `opencode service set password`, aber
# nur bei einem echten 401 (jedes `set` STOPPT den Dienst; `run.sh` startet ihn
# danach wieder).
# Der frueher hier gesetzte Export OPENCODE_SERVER_PASSWORD entfaellt: der
# Dienst wird nicht mehr als Kind von run.sh gestartet und liest die Variable
# deshalb nicht.
[ -n "${OPENCODE_PASSWORD:-}" ] || { echo "FEHLER: OPENCODE_PASSWORD fehlt in .env -> ./setup.sh"; exit 1; }

# ---------------------------------------------------------------------------
# Speicher-Watchdog: opencode beendet, sobald der RSS ueber die Schwelle steigt
# (Default 4 GiB, per WATCHDOG_MAX_RSS_MIB in der .env uebersteuerbar).
#
# Das ist ein Runaway-Waechter, KEIN RAM-Budget und keine "RAM ist voll"-
# Erkennung. Gemessen am 2026-09-27 ueber 10,6 h (648 Proben, minuetlich, ueber
# alle opencode-Prozesse): **kein unbegrenztes Wachstum.** Summe der Footprints
# 884 -> 694 MiB, Swap 1819 -> 1763 MiB, 88 % RAM frei, sieben Stunden exakt
# waagerecht bei ~2973 MiB RSS-Summe. Der einzige Kandidat (zweite Instanz
# `opencode serve --service`) stieg auf 1284 MiB und fiel wieder auf 1248.
# Der RSS folgt der Last der aktiven Session, nicht der Zeit.
# ---------------------------------------------------------------------------
# Warum `ps -eo pid=,comm=` + awk und NICHT `pgrep -f opencode`:
#  - `pgrep -f opencode` matcht die vollstaendige Kommandozeile und trifft damit
#    auch run.sh SELBST, den opencode-usage node/tsx-Server und codegraph. Ein
#    Kill auf dieses Muster wuerde den Tunnel-Supervisor und fremde Dienste
#    mitreissen.
#  - `pgrep -f` ist auf macOS zusaetzlich unzuverlaessig, weil der Kernel argv
#    und Environment am Textlimit abschneidet — ein Muster, das nur im
#    abgeschnittenen argv steht, wird gar nicht erst gefunden. Als
#    Erkennungsbasis unbrauchbar, deshalb der Anker auf `comm`.
# Der Anker `(^|/)opencode(-cli)?$` matcht die echten Binaries und laesst alles
# andere unangetastet. comm wird per Regex auf die GANZE Zeile geprueft, nicht per
# awk-Feld: comm ist der ausfuehrbare Pfad, und jeder Pfad mit Leerzeichen
# (z. B. unter "/Applications/My Tools/...") wuerde an $2 abgeschnitten.
#
# Was der Anker bewusst NICHT trifft: codegraph. Das haelt auf diesem Mac
# 1350-1540 MiB in 12-17 Prozessen (ueber dieselben 10,6 h gemessen) — mehr als
# alle opencode-Prozesse zusammen — und wird nicht gepatcht, weil ein Kill die
# MCP-Verbindungen laufender Runs zerstoert. Wer den Speicher-Ueberblick erweitern
# will, darf codegraph zaehlen, aber niemals wegkillen.
#
# Vorsicht bei der Interpretation: die SUMME des RSS mehrerer opencode-Prozesse
# ist keine Speichermenge. Geteilte Seiten zaehlt macOS pro Prozess, eine
# gemeinsam gemappte Bibliothek also mehrfach. Ehrlich ist der Footprint
# (`top -l 1 -pid <pid> -stats mem`). Die Schwelle pro Prozess ist
# dagegen robust, weil sie geteilte Seiten nicht ueberzaehlt.
#
# Der Default steht HIER und ist die einzige Quelle der Wahrheit; die .env setzt
# WATCHDOG_MAX_RSS_MIB nur, wenn jemand bewusst abweicht. Ein gesetzter Env-Wert
# schlaegt den Default still — wer die Zahl hier aendert, waehrend die .env eine
# andere nennt, merkt das nur an der Zeile "watchdog: aktiv (Schwelle … MiB)".
# Nicht-numerische Werte, fuehrende Nullen und alles unter 256 MiB fallen auf
# den Default zurueck (siehe die drei Zeilen direkt unter dem Block, noetig
# wegen `set -euo pipefail`).
#
# 2 GiB -> 4 GiB (2026-10-16, Entscheidung des Menschen). Die 2 GiB waren keine
# theoretische Schwelle: am 2026-10-16 haben sie zwischen 12:56 und 14:04
# **15x** gefeuert (PIDs 97754, 26851, 29100, 30291, 30655, 30792, 30926, 31053,
# 32409, 32892, 33813, 34737, 35203, 36469, 36827), jedes Mal nur knapp ueber
# der Decel (2051-2543 MiB).
#
# Getroffen hat es damals NIE den von run.sh selbst gestarteten Serve auf :8080
# (PID 20243, stabil um 500 MiB, Kind von run.sh), sondern `serve --service` —
# das Server-Kind der laufenden TUI. Diesen zweiten, eigenen Serve gibt es nicht
# mehr: der Listener auf :$LOCAL ist der gemeinsame Hintergrund-Dienst
# (`opencode service`), also genau der Prozess, den die TUI als
# `serve --service` startet. Die Messwerte oben bleiben unveraendert; die
# damalige Erscheinung "Session wird staendig neu gestartet" kam daher, dass der
# Waechter den TUI-Server killte und die TUI ihn Sekunden spaeter mit neuer PID
# respawnte.
#
# Der hoehere Wert ist ein bewusster Kompromiss und NICHT durch eine Messung
# gedeckt: gemessen ist nur, dass die Instanzen unter 2 GiB nicht zur Ruhe
# kommen (ein frisch respawnter Prozess stand nach 5 min bei 1871 MiB). Ob sie
# unter 4 GiB halten, ist OFFEN — sonst wird die Churn seltener, aber nicht weg.
# Die 3 Neustarts/300 s aus WATCHDOG_MAX_RESTARTS bleiben die Bremse.
WATCHDOG_MAX_RSS_MIB="${WATCHDOG_MAX_RSS_MIB:-4096}"
case "$WATCHDOG_MAX_RSS_MIB" in ''|*[!0-9]*) WATCHDOG_MAX_RSS_MIB=4096;; esac
# 10# : "08" waere sonst oktal und $(( )) bricht unter set -e den ganzen Start ab.
WATCHDOG_MAX_RSS_MIB=$((10#$WATCHDOG_MAX_RSS_MIB))
# Untergrenze wie beim Update-Intervall in remote/entrypoint.sh: alles unter
# 256 MiB ist ein Tippfehler und wuerde jeden Poll sofort killen.
[ "$WATCHDOG_MAX_RSS_MIB" -lt 256 ] && WATCHDOG_MAX_RSS_MIB=4096
WATCHDOG_MAX_RSS_KIB=$((WATCHDOG_MAX_RSS_MIB * 1024))
WATCHDOG_INTERVAL=60                        # Poll-Abstand in Sekunden
WATCHDOG_MAX_RESTARTS=3                     # Neustarts im Fenster ...
WATCHDOG_WINDOW=300                         # ... bevor es kuenstlich pausiert

oc_pids() {
  ps -eo pid=,comm= | awk '{
    line = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
    if (line ~ /(^|\/)opencode(-cli)?$/) print $1
  }'
}
oc_rss_kib() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' \n'; }
port_up() { (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1; }
# PID, der gerade auf :$LOCAL lauscht (der gemeinsame OpenCode-Dienst).
# Ohne bekannten Port (nur --sync-only laesst das zu) gibt es nichts zu pruefen:
# lsof bricht sonst mit "unacceptable port specification" ab und reisst unter
# `set -e` den Watchdog beim ersten Poll mit. `| head -1 || true` faengt
# zusaetzlich den SIGPIPE-Fall (pipefail) bei mehreren Listenern ab.
port_pid() {
  [ -n "$LOCAL" ] || return 0
  { lsof -nP -iTCP:"$LOCAL" -sTCP:LISTEN -t 2>/dev/null || true; } | head -1 || true
}

# ---------------------------------------------------------------------------
# Gemeinsamer OpenCode-Hintergrund-Dienst (Pflicht — nie einen eigenen serve
# starten).
#
# Warum der Dienst und kein eigener `opencode serve` mehr: der Tunnel zeigte
# frueher auf einen zweiten Server, den run.sh selbst startete. Beide Server
# lasen dieselbe SQLite-DB, aber /api/session/active ist PROZESSGEBUNDEN — die
# Web-UI sah eine laufende TUI-Sitzung deshalb nur bis zur letzten gespeicherten
# Nachricht (kein Live-Stream, keine Permission-Dialoge). Jetzt gibt es genau
# einen Server-Prozess: die TUI haengt per `opencode serve --service` daran, der
# Tunnel zeigt auf denselben Port. Ein Live-Status, eine DB-Schreibquelle.
#
# Der Port kommt aus `opencode service status` (service_port oben), NICHT aus
# einer zweiten Konfigurationsdatei. Ist der Dienst unten, holt ihn
# `opencode service start` zurueck; ein eigenes serve-Kommando gibt es nicht
# mehr, OPENCODE_CMD ist entfallen.
# ---------------------------------------------------------------------------
# 20 Versuche a 1 s: der Dienst braucht beim Kaltstart ein paar Sekunden, laenger
# als 20 s heisst, dass etwas kaputt ist (Konfiguration, DB-Lock).
wait_port() {
  local _
  for _ in $(seq 1 20); do
    port_up && return 0
    sleep 1
  done
  return 1
}

# HTTP-Status von /api/info mit Basic-Auth. Nur ein 401 bedeutet "Passwort
# falsch" und rechtfertigt ein `set`; ein Timeout, Reset oder 5xx ist ein anderer
# Fehler und darf den Dienst NICHT neu starten. "000" = keine Antwort.
# Timeouts wie im remote-Teil (remote/Dockerfile, remote/entrypoint.sh): ein
# Listener, der die Verbindung annimmt und nicht antwortet, wuerde run.sh sonst
# unbegrenzt vor der -R-Bindung blockieren — launchd KeepAlive greift nicht,
# weil der Prozess lebt.
service_auth_code() {
  curl -s --connect-timeout 2 --max-time 5 -o /dev/null -w '%{http_code}' \
    -u "opencode:$OPENCODE_PASSWORD" "http://127.0.0.1:$LOCAL/api/info" 2>/dev/null || true
}

# ACAO-Header der echten Antwort pruefen: der Header kommt aus dem Dienst
# (`opencode service set cors`), nicht aus Caddy, deshalb wird gegen /api/info
# mit Origin-Header gemessen. Reine Diagnose fuer die PWA: der Web-Weg laeuft
# same-origin ueber https://CODE_DOMAIN (Gate + Tunnel), dort ist CORS kein
# Thema. Ein fehlender Header darf den Tunnel-Start NICHT blockieren.
# grep -c statt grep -q: unter `set -o pipefail` beendet -q den curl per SIGPIPE,
# die Pipeline gilt als fehlgeschlagen und ein vorhandener Header wuerde nie
# erkannt (dieselbe Falle wie beim rsync-Guard in setup.sh/sync.sh). -c liest die
# Antwort zu Ende und die Trefferzahl ist auswertbar.
service_cors_ok() {
  local hits
  hits="$(curl -s --connect-timeout 2 --max-time 5 -D- -o /dev/null \
            -u "opencode:$OPENCODE_PASSWORD" \
            -H "Origin: $CORS_ORIGIN" "http://127.0.0.1:$LOCAL/api/info" 2>/dev/null \
          | grep -ci -- "^access-control-allow-origin: *$CORS_ORIGIN" || true)"
  [ "${hits:-0}" -gt 0 ]
}

ensure_service() {
  local port_now

  if port_up; then
    echo "OpenCode-Dienst laeuft bereits auf :$LOCAL."
  else
    echo "Starte OpenCode-Dienst (opencode service start)..."
    # Ausgabe in dasselbe Log wie run.sh: das frueher eigene Log
    # /tmp/code-tunnel-opencode.log gibt es nicht mehr. Das Log kann
    # Session-Inhalte enthalten (chmod 600 oben, Umask 077 in der plist).
    opencode service start >>/tmp/code-tunnel.log 2>&1 || true
    # Port nachziehen: `opencode service status` ist die einzige Quelle und
    # liefert erst jetzt die echte Bindung. Der Fallback oben ist nur der
    # Notnagel, solange der Dienst keine URL ausgibt — mit ihm allein wuerde
    # wait_port gegen den falschen Port laufen.
    port_now="$(service_port)" || true
    [ -z "$port_now" ] || LOCAL="$port_now"
    if ! wait_port; then
      echo "FEHLER: OpenCode-Dienst lauscht nach 20 s nicht auf :$LOCAL (opencode service status, /tmp/code-tunnel.log)"
      return 1
    fi
  fi

  # Ohne curl waere die Passwort-Pruefung "fehlgeschlagen" und run.sh wuerde bei
  # JEDEM Boot per `set` den Dienst neu starten — die laufende TUI verliert dann
  # grundlos ihre Verbindung. Deshalb hier pruefen statt blind setzen.
  if ! command -v curl >/dev/null 2>&1; then
    echo "WARN: curl fehlt — Dienst-Passwort nicht geprueft, Dienst bleibt unveraendert"
    return 0
  fi

  # Passwort-Pruefung ist Pflicht: ohne sie antwortet das Gate komplett 401
  # (Caddy injiziert base64("opencode:$OPENCODE_PASSWORD"), der Dienst kennt es
  # aber nicht). Nur ein echtes 401 heilt sich selbst; Timeout/5xx sind ein
  # anderer Fehler und werden gemeldet, statt den Dienst zu stoppen.
  local code
  code="$(service_auth_code)"
  if [ "$code" = "401" ]; then
    echo "Dienst-Passwort passt nicht (401 auf /api/info): opencode service set password"
    opencode service set password "$OPENCODE_PASSWORD" >>/tmp/code-tunnel.log 2>&1 || true
    # Pflicht-Logzeile: `opencode service set` STOPPT den Dienst (es startet ihn
    # nicht) — laufende TUI-Server verlieren ihre Verbindung (Sitzungen sind
    # persistiert), deshalb folgt `opencode service start` direkt danach.
    echo "HINWEIS: 'opencode service set' stoppt den Dienst — laufende TUI-Server verlieren ihre Verbindung, danach folgt 'opencode service start'"
    opencode service start >>/tmp/code-tunnel.log 2>&1 || true
    port_now="$(service_port)" || true
    [ -z "$port_now" ] || LOCAL="$port_now"
    if ! wait_port; then
      echo "FEHLER: OpenCode-Dienst lauscht nach dem Neustart nicht auf :$LOCAL"
      return 1
    fi
    # Wiederholen: das Setzen allein ist kein Beleg, dass der Dienst das neue
    # Passwort uebernommen hat.
    code="$(service_auth_code)"
    if [ "$code" != "200" ]; then
      echo "FEHLER: Dienst-Auth weiterhin fehlerhaft (HTTP $code auf /api/info) — 'opencode service set password' wirkt nicht"
      return 1
    fi
    echo "Dienst-Auth verifiziert."
  elif [ "$code" != "200" ]; then
    echo "FEHLER: /api/info antwortet HTTP ${code:-000} statt 200 (Dienst haengt oder antwortet nicht) — kein Passwort-Set"
    return 1
  fi

  # CORS betrifft NUR die separate PWA (ocweb.all-the.rest), nicht den Web-Weg
  # ueber https://CODE_DOMAIN: der laeuft same-origin hinter Gate + Tunnel, ein
  # ACAO-Header ist dort ohne Bedeutung. Deshalb hier nur ein Hinweis, kein Set,
  # kein Neustart, kein Abbruch.
  if [ -n "${CORS_ORIGIN:-}" ] && ! service_cors_ok; then
    echo "HINWEIS: PWA-Origin ${CORS_ORIGIN} ohne ACAO — nur fuer ocweb relevant, optional (stoppt den Dienst): opencode service set cors \"$CORS_ORIGIN\" && opencode service start"
  fi
  return 0
}

# Der Watchdog laeuft in ALLEN Modi, auch --tunnel-only: der gemeinsame Dienst
# (der Listener auf :$LOCAL — die TUI haengt per `serve --service` daran) und die
# TUI-Clients werden nicht von run.sh gestartet, sind aber die Speicherfresser.
# $1 = PID von run.sh. Bewusst per Parameter und per `kill -0` geprueft statt
# per PPID-Vergleich: `$$` ist in einer Bash-Subshell die PID des ELTERNprozesses
# (macOS-Bash 3.2 kennt kein BASHPID), ein `ps -o ppid= -p $$` liefert deshalb
# den Grosselternteil (launchd) und wuerde den Vergleich IMMER falsch ergeben —
# der Watchdog wuerde nach dem ersten Poll sterben.
watchdog_loop() {
  local parent="${1:-$$}"
  local restarts=0 window_start
  window_start=$(date +%s)
  while :; do
    sleep "$WATCHDOG_INTERVAL"
    # launchd SIGTERMt nur run.sh, nicht diese Subshell: sie wuerde verwaist
    # weiterlaufen und der per KeepAlive gestartete run.sh bruechte einen
    # zweiten Watchdog. Dann beenden wir uns selbst, bevor zwei Watchdogs
    # dieselben PIDs jagen.
    if ! kill -0 "$parent" 2>/dev/null; then
      echo "[$(date '+%F %T')] watchdog: run.sh (PID $parent) weg — beende mich"
      return 0
    fi
    local now; now=$(date +%s)
    # Restart-Fenster zuruecksetzen, statt eine Restart-Schleife zu fahren:
    # ein serve, der sofort wieder ueber die Schwelle springt, ist ein Symptom, kein
    # Kandidat fuer Autofeuer.
    if [ $((now - window_start)) -ge "$WATCHDOG_WINDOW" ]; then
      restarts=0; window_start=$now
    fi
    if [ "$restarts" -ge "$WATCHDOG_MAX_RESTARTS" ]; then
      echo "[$(date '+%F %T')] watchdog: $restarts Neustarts in ${WATCHDOG_WINDOW}s — pausiere ${WATCHDOG_INTERVAL}s (Speicherleck, nicht Restart-Bedarf)"
      continue
    fi

    local pid rss listen_pid
    # Port bei jedem Poll aus der einzigen Quelle nachziehen: die Watchdog-
    # Subshell hat LOCAL beim Fork geerbt. Wechselt der Dienst seinen Port (oder
    # war er beim Boot noch unkonfiguriert), wuerde sie sonst gegen den falschen
    # Port pruefen und den Dienst als TUI-Client behandeln.
    local svc_port; svc_port="$(service_port)" || true
    [ -z "$svc_port" ] || LOCAL="$svc_port"
    listen_pid=$(port_pid)
    for pid in $(oc_pids); do
      rss=$(oc_rss_kib "$pid")
      [ -n "$rss" ] || continue
      [ "$rss" -gt "$WATCHDOG_MAX_RSS_KIB" ] || continue

      echo "[$(date '+%F %T')] watchdog: opencode PID $pid bei $((rss / 1024)) MiB > ${WATCHDOG_MAX_RSS_MIB} MiB — SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
      restarts=$((restarts + 1))

      if [ "$pid" = "$listen_pid" ]; then
        # Der gemeinsame Dienst (:LOCAL): `opencode service start` holt ihn
        # zurueck. Der Port muss erst wieder frei sein, sonst EADDRINUSE.
        sleep 2
        echo "[$(date '+%F %T')] watchdog: starte OpenCode-Dienst neu (:$LOCAL)"
        opencode service start >>/tmp/code-tunnel.log 2>&1 \
          || echo "[$(date '+%F %T')] watchdog: Neustart fehlgeschlagen (opencode service start, siehe /tmp/code-tunnel.log)"
        echo "[$(date '+%F %T')] watchdog: Sitzungen sind persistiert, TUI muss neu verbinden"
      else
        # Alle anderen opencode-PIDs sind der TUI-Client. Er haengt an einem TTY
        # (bzw. wird von der TUI selbst respawnt) — ein Neustart ist von hier aus
        # nicht moeglich, und der Dienst laeuft weiter. Also: beenden, nicht
        # neu starten, und das laut sagen statt einen Relaunch zu erfinden.
        echo "[$(date '+%F %T')] watchdog: PID $pid war NICHT der Dienst auf :$LOCAL (TUI-Client) — beendet, kein Neustart"
      fi
    done
  done
}

if [ "$MODE" != "--tunnel-only" ]; then
  ./sync.sh
fi
# Watchdog VOR dem blockierenden autossh/ssh weiter unten starten — danach
# erreicht die Zeile nie wieder den Code. $$ ist hier die PID dieses run.sh und
# wird als Argument uebergeben (siehe Kommentar an watchdog_loop).
watchdog_loop $$ &
echo "[$(date '+%F %T')] watchdog: aktiv (Schwelle ${WATCHDOG_MAX_RSS_MIB} MiB, Poll ${WATCHDOG_INTERVAL}s, beobachtet run.sh PID $$)"
if [ "$MODE" != "--sync-only" ]; then
  # Mac wach halten, solange der Tunnel laeuft (Display darf aus).
  # Wird von stop-tunnel.command ueber `pkill caffeinate` beendet.
  CAFFEINE_PID_FILE="/tmp/code-tunnel-caffeinate.pid"
  if [ -f "$CAFFEINE_PID_FILE" ] && kill -0 "$(cat "$CAFFEINE_PID_FILE")" 2>/dev/null; then
    echo "[$(date '+%F %T')] caffeinate: laeuft bereits (PID $(cat "$CAFFEINE_PID_FILE"))"
  else
    caffeinate -is &
    echo $! > "$CAFFEINE_PID_FILE"
    chmod 600 "$CAFFEINE_PID_FILE"
    echo "[$(date '+%F %T')] caffeinate: aktiv (PID $!, verhindert System-Schlaf)"
  fi

  # OpenCode-Dienst sicherstellen (Pflicht — nie einen eigenen serve starten).
  ensure_service || exit 1
  # Jetzt ist der Port endgueltig ableitbar (Dienst laeuft, ensure_service hat
  # LOCAL nachgezogen). Ohne ihn wuerde die -R-Bindung ins Leere zeigen.
  if [ -z "$LOCAL" ]; then
    echo "FEHLER: Port des OpenCode-Dienstes unbekannt — 'opencode service status' lieferte nichts und LOCAL_PORT fehlt in .env" >&2
    exit 1
  fi

  # Alte/verwaiste Tunnel-Instanzen beenden. Zwei ssh-Prozesse auf demselben
  # VPS-Port (BIND:REMOTE) machen sich gegenseitig die Bind kaputt
  # (ExitOnForwardFailure) — genau das erzeugt flackernde Tunnel.
  # Muster nur auf Forward + Ziel, nicht auf die Argumentreihenfolge: der
  # plain-ssh-Fallback hat -N hinter den Optionen, ein "ssh -N"-Muster trifft ihn
  # nicht und die verwaiste Instanz bleibt dann auf dem VPS-Port binden.
  # Der Mac-Port steht NICHT fest: er kann sich zwischen Start und Stopp aendern
  # (Dienst gestoppt -> `opencode service status` sagt "stopped" -> Fallback).
  # Deshalb endet die Signatur am ":" vor dem Port, und das Muster verlangt dort
  # Ziffern. WICHTIG: kein Leerzeichen zwischen Signatur und Port — in der echten
  # argv folgt der Port direkt auf den Doppelpunkt ("...127.0.0.1:49374 user@…");
  # ein Muster mit "…: " trifft nichts (am 2026-11-11 gegen echte argv gemessen).
  tunnel_sig="-R $BIND:$REMOTE:127.0.0.1:"
  tunnel_re="${tunnel_sig}[0-9]+"
  pkill -f -- "ssh .*$tunnel_re .*$TARGET\$" 2>/dev/null || true
  pkill -f -- "autossh .*$tunnel_re .*$TARGET\$" 2>/dev/null || true
  # Master-Connection sauber schliessen -> Control-Socket (/tmp/ssh-code-*) weg.
  # -p MUSS mit: %p im ControlPath wird sonst aus dem Default 22 expandiert und
  # die Bereinigung zeigt bei SSH_PORT != 22 auf den falschen Socket.
  ssh -S "$MASTER_PATH" -p "$PORT" -O exit "$TARGET" >/dev/null 2>&1 || true

  if [ "${#KEY_OPTS[@]}" -eq 0 ]; then
    # Ohne Key: Master-Connection vorab oeffnen, damit nur 1x nach der
    # Passphrase gefragt wird (Waechter + Diagnose multiplexen darauf).
    echo "Oeffne Master-Connection (1x Passphrase)..."
    ssh "${WATCH_OPTS[@]}" -fN -p "$PORT" "$TARGET"
  fi
  echo "Tunnel: $BIND:$REMOTE (VPS) <- 127.0.0.1:$LOCAL (Mac) via $TARGET:$PORT"
  # Erfolgswachter: meldet sobald der Forward am VPS lauscht (bei Key-Auth ohne
  # Passphrase via eigene Verbindung, sonst via Master).
  ( for _ in $(seq 1 30); do
      if ssh "${WATCH_OPTS[@]}" -p "$PORT" "$TARGET" "ss -tln 2>/dev/null | grep -q '$BIND:$REMOTE'"; then
        echo "Tunnel aktiv ($(date +%H:%M:%S)): VPS $BIND:$REMOTE -> Mac 127.0.0.1:$LOCAL — bereit: https://${CODE_DOMAIN:-code.example.com}/"
        exit 0
      fi
      sleep 2
    done
    echo "WARN: Forward nach 60s nicht auf VPS sichtbar — Log pruefen." ) &
  if command -v autossh >/dev/null 2>&1; then
    echo "Modus: autossh (Reconnect bei Netzverlust/Sleep)."
    AUTOSSH_PORT=0 autossh -M 0 -N "${TUNNEL_OPTS[@]}" -p "$PORT" \
      -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  else
    echo "WARN: autossh fehlt (brew install autossh) -> plain ssh, KEIN Reconnect."
    ssh "${TUNNEL_OPTS[@]}" -N -p "$PORT" -R "$BIND:$REMOTE:127.0.0.1:$LOCAL" "$TARGET"
  fi
fi
