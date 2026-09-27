#!/usr/bin/env bash
# run.sh: Website syncen (rclone) + SSH-Reverse-Tunnel starten.
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
LOCAL="${LOCAL_PORT:-8080}"
DIST="${LOCAL_DIST:-apps/web/dist}"
REMOTE_PATH="${RCLONE_REMOTE:-vps.example.com}:${RCLONE_PATH:-/code.example.com}"

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

MODE="${1:-all}"
# Logs koennen Session-Inhalte enthalten -> nur fuer den Besitzer lesbar. Die plist
# setzt Umask 077, das greift aber nur bei NEUEN Dateien; bestehende aus einem
# frueheren Lauf bleiben sonst world-readable.
chmod 600 /tmp/code-tunnel.log 2>/dev/null || true
echo "[$(date '+%F %T')] run.sh start (Modus: $MODE, Key-Auth: $([ "${#KEY_OPTS[@]}" -gt 0 ] && echo ja || echo nein))"
# OpenCode-eigenes Serverpasswort (Pflicht): serve erzwingt Auth, Caddy injiziert
# es upstream per Header -> im Browser unsichtbar (de facto deaktiviert).
[ -n "${OPENCODE_PASSWORD:-}" ] || { echo "FEHLER: OPENCODE_PASSWORD fehlt in .env -> ./setup.sh"; exit 1; }
export OPENCODE_SERVER_PASSWORD="$OPENCODE_PASSWORD"

# ---------------------------------------------------------------------------
# Speicher-Watchdog: opencode beendet, sobald der RSS ueber 2 GiB steigt.
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
# (`top -l 1 -pid <pid> -stats mem`). Die 2-GiB-Schwelle pro Prozess ist
# dagegen robust, weil sie geteilte Seiten nicht ueberzaehlt.
WATCHDOG_MAX_RSS_KIB=$((2 * 1024 * 1024))   # 2 GiB, hart kodiert
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
# PID, der gerade auf :$LOCAL lauscht (der superviste opencode serve).
port_pid() { lsof -nP -iTCP:"$LOCAL" -sTCP:LISTEN -t 2>/dev/null | head -1; }

# OpenCode-Web sicherstellen (Pflicht — nie manuell starten).
# Ueber .env aenderbar: OPENCODE_CMD="..."
OPENCODE_CMD="${OPENCODE_CMD:-opencode serve --hostname 127.0.0.1 --port $LOCAL}"
ensure_opencode() {
  if port_up; then
    echo "OpenCode-Web laeuft bereits auf :$LOCAL."
    return 0
  fi
  echo "Starte OpenCode-Web: $OPENCODE_CMD"
  # shellcheck disable=SC2086
  $OPENCODE_CMD >>/tmp/code-tunnel-opencode.log 2>&1 &
  # Log kann Session-Inhalte enthalten -> nur fuer den Besitzer lesbar. Der
  # LaunchAgent setzt dafuer zusaetzlich Umask 077 in der plist.
  chmod 600 /tmp/code-tunnel-opencode.log 2>/dev/null || true
  for _ in $(seq 1 20); do
    port_up && break
    sleep 1
  done
  port_up || { echo "FEHLER: OpenCode-Web lauscht nicht auf :$LOCAL (Log: /tmp/code-tunnel-opencode.log)"; return 1; }
}

# Der Watchdog laeuft in ALLEN Modi, auch --tunnel-only: die TUI-Sessions und
# die zweite Instanz `opencode serve --service` werden nicht von run.sh
# gestartet, sind aber genau die Speicherfresser.
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
    # ein serve, der sofort wieder ueber 2 GiB springt, ist ein Symptom, kein
    # Kandidat fuer Autofeuer.
    if [ $((now - window_start)) -ge "$WATCHDOG_WINDOW" ]; then
      restarts=0; window_start=$now
    fi
    if [ "$restarts" -ge "$WATCHDOG_MAX_RESTARTS" ]; then
      echo "[$(date '+%F %T')] watchdog: $restarts Neustarts in ${WATCHDOG_WINDOW}s — pausiere ${WATCHDOG_INTERVAL}s (Speicherleck, nicht Restart-Bedarf)"
      continue
    fi

    local pid rss listen_pid
    listen_pid=$(port_pid)
    for pid in $(oc_pids); do
      rss=$(oc_rss_kib "$pid")
      [ -n "$rss" ] || continue
      [ "$rss" -gt "$WATCHDOG_MAX_RSS_KIB" ] || continue

      echo "[$(date '+%F %T')] watchdog: opencode PID $pid bei $((rss / 1024)) MiB > $((WATCHDOG_MAX_RSS_KIB / 1024)) MiB — SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
      restarts=$((restarts + 1))

      if [ "$pid" = "$listen_pid" ]; then
        # Der superviste serve: den Restart koennen wir selbst uebernehmen.
        sleep 2   # Port muess erst wieder frei sein, sonst EADDRINUSE
        echo "[$(date '+%F %T')] watchdog: starte OpenCode-Web neu (:$LOCAL)"
        ensure_opencode || echo "[$(date '+%F %T')] watchdog: Neustart fehlgeschlagen (Log: /tmp/code-tunnel-opencode.log)"
      else
        # TUI-Session oder die zweite Instanz `serve --service`: die haengen an
        # einem TTY bzw. laufen unabhaengig von run.sh (PPID 1, von Hand oder
        # launchd gestartet). Ein SIGKILL beendet sie, ein Neustart ist von hier
        # aus NICHT moeglich — dafuer gibt es kein TTY, das man neu befuellen
        # koennte, und die serve-Instanz gehoert jemand anderem. Wir sagen das
        # laut im Log, statt einen Relaunch zu erfinden, der in einem fremden
        # Terminal oder ohne Auth-Env landen wuerde.
        echo "[$(date '+%F %T')] watchdog: PID $pid war NICHT der :$LOCAL-Serve (TUI bzw. serve --service) — beendet, manueller Neustart noetig"
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
echo "[$(date '+%F %T')] watchdog: aktiv (Schwelle $((WATCHDOG_MAX_RSS_KIB / 1024)) MiB, Poll ${WATCHDOG_INTERVAL}s, beobachtet run.sh PID $$)"
if [ "$MODE" != "--sync-only" ]; then
  # OpenCode-Web sicherstellen (Pflicht — nie manuell starten).
  ensure_opencode || exit 1

  # Alte/verwaiste Tunnel-Instanzen beenden. Zwei ssh-Prozesse auf demselben
  # VPS-Port (BIND:REMOTE) machen sich gegenseitig die Bind kaputt
  # (ExitOnForwardFailure) — genau das erzeugt flackernde Tunnel.
  # Muster nur auf Forward + Ziel, nicht auf die Argumentreihenfolge: der
  # plain-ssh-Fallback hat -N hinter den Optionen, ein "ssh -N"-Muster trifft ihn
  # nicht und die verwaiste Instanz bleibt dann auf dem VPS-Port binden.
  tunnel_sig="-R $BIND:$REMOTE:127.0.0.1:$LOCAL"
  pkill -f -- "ssh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
  pkill -f -- "autossh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
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
