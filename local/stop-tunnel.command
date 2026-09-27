#!/usr/bin/env bash
# stop-tunnel.command – Gegenstueck zu start-tunnel.command: haelt den Tunnel
# an, ohne fremde Prozesse anzufassen. Doppelklick am Mac oder
# ./stop-tunnel.command im Terminal. Idempotent: laeuft nichts, ist es ein
# kurzer Report und kein Fehler (Exit 0).
#
# Bisheriger Weg, jetzt als Skript: `launchctl bootout gui/$(id -u)/com.code-tunnel`.
# Das entfernt den Job — der Stopp ist damit aber nicht fertig, und was launchd
# beim Stopp genau trifft, ist am 2026-09-27 an diesem Mac **gemessen**, nicht
# angenommen:
#
#   - launchd SIGTERMt beim Stopp die PROZESSGRUPPE des Jobs. Nach `bootout`
#     waren weg: run.sh, die Watchdog-Subshell, autossh, dessen ssh und der
#     superviste `opencode serve` (Kind von run.sh, run.sh:127). Uebrig blieben
#     nur Prozesse ausserhalb der Gruppe: `opencode serve --service` (PPID 1)
#     und die TUI-Sessions. Ein blosses `kill` auf die run.sh-PID erreicht
#     dagegen NUR run.sh, nicht die Subshell (local/AGENTS.md §5) — beides
#     gleichzeitig ist keine Widerspruchsaussage, es sind zwei Signale.
#   - Was `bootout` nicht kann: den Autostart sperren. Die gerenderte plist
#     bleibt in ~/Library/LaunchAgents liegen, launchd laedt sie beim naechsten
#     Login wieder und RunAtLoad feuert den Tunnel erneut an.
#
# Daraus die Schritte in fester Reihenfolge:
#
#   1) launchctl disable VOR bootout. Rueckfahrt: bootstrap.sh macht
#      `launchctl enable` vor `launchctl bootstrap` (siehe dort, Kommentar
#      "enable VOR bootstrap") — ohne enable an dieser Stelle startet der
#      naechste start-tunnel.command gar nichts.
#   2) bootout: Job und KeepAlive sind weg, kein Neustart nach einem Absturz.
#   3) Aufraeumen fuer die Faelle, die bootout nicht abdeckt: der
#      Finder-Fallback (run.sh im Vordergrund, kein launchd) und Waisen
#      aeilterer Laeufe. Reihenfolge darin ist nicht beliebig: **erst autossh,
#      dann ssh** — ein allein gekilltes ssh im Forward laesst autossh sofort
#      neu verbinden, das ist genau sein Job.
#   4) Master-Connection schliessen -> /tmp/ssh-code-* weg.
#
# Bewusst NICHT angefasst: `opencode serve --service` und laufende TUI-Sessions.
# Sie gehoeren niemandem ausser dir, ein Stopp des Tunnels darf sie nicht
# beenden. Der superviste Serve auf :LOCAL faellt dagegen mit — das ist der
# gewuenschte Zustand (kein Tunnel, kein Server) und der naechste
# start-tunnel.command holt ihn ueber ensure_opencode zurueck.
set -euo pipefail
cd "$(dirname "$0")"
# Auch der Stop braucht den vollen PATH: der Doppelklick aus dem Finder startet
# reduziert, und pkill/ssh/lsof sollen nicht an einem fehlenden Werkzeug scheitern.
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

LABEL=com.code-tunnel
JOB="gui/$(id -u)/$LABEL"
MASTER_PATH='/tmp/ssh-code-%r@%h:%p'
TARGET="${SSH_TARGET:?FEHLER: SSH_TARGET fehlt in .env}"
PORT="${SSH_PORT:-22}"
BIND="${REMOTE_BIND:-172.18.0.1}"
REMOTE="${REMOTE_PORT:-18731}"
LOCAL="${LOCAL_PORT:-8080}"
WEB="${CODE_DOMAIN:-code.example.com}"

ok()   { echo "OK   $1"; }
warn() { echo "WARN $1"; }

agent_loaded() { launchctl print "$JOB" >/dev/null 2>&1; }
agent_disabled() { launchctl print-disabled "gui/$(id -u)" 2>/dev/null | grep -q "\"$LABEL\".*disabled"; }
port_up() { (echo >/dev/tcp/127.0.0.1/"$LOCAL") >/dev/null 2>&1; }
# Nur die Forward-Signatur: -R BIND:REMOTE -> Mac :LOCAL, Ziel am Zeilenende.
# Kein pauschales "pkill ssh" — das wuerde fremde ssh-Sitzungen (Git,
# VS-Code-Remote, andere Tunnel) mitreissen. Das Muster steht absichtlich so
# in run.sh, damit beide Seiten dieselbe Signatur verwenden (AGENTS.md §2).
tunnel_sig="-R $BIND:$REMOTE:127.0.0.1:$LOCAL"
tunnel_pids() { pgrep -f -- "(auto)?ssh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true; }
# Gezielt der run.sh-Aufruf, nicht jedes Fenster, in dem der Pfad nur vorkommt
# (deshalb kein `pkill -f run.sh`). Zwei argv-Formen: launchd startet
# `bash <pfad> --tunnel-only`, der Finder-Fallback laeuft als `bash ./run.sh`.
# Beide: Feld 1 = Shell, Feld 2 = Skriptpfad, danach hoechstens --tunnel-only.
# Die Watchdog-Subshell hat dasselbe argv wie run.sh (fork ohne exec) und wird
# mit beendet — das ist gewollt und spart das bis zu 60 s lange Warten auf
# ihren Selbstcheck (local/AGENTS.md §5).
runsh_pids() {
  ps -eo pid=,args= | awk '{
    pid = $1; line = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
    n = split(line, a, /[[:space:]]+/)
    if (a[1] !~ /(^|\/)(ba|z|k)?sh$/) next
    if (a[2] !~ /(^|\/)run\.sh$/) next
    if (n > 2 && a[3] != "--tunnel-only") next
    print pid
  }'
}
# $1 = Signal, $2 = Leerzeichenliste von PIDs. Das Splitten ist beabsichtigt
# (die Aufrufer sammeln PIDs ueber ps/pgrep), deshalb bewusst unquoted.
kill_pids() {
  local sig="$1" p
  shift
  # shellcheck disable=SC2068,SC2086
  for p in $@; do kill "-$sig" "$p" 2>/dev/null || true; done
}

echo "== 1/3 LaunchAgent $LABEL =="
WAS_LOADED=0
if agent_loaded; then
  WAS_LOADED=1
  launchctl disable "$JOB" 2>/dev/null || warn "launchctl disable fehlgeschlagen — Job ist dann nur bis zum naechsten Login gestoppt"
  launchctl bootout "$JOB" 2>/dev/null || warn "launchctl bootout fehlgeschlagen"
  sleep 1
  if agent_loaded; then
    warn "Agent laeuft trotz bootout — Schritt 2 beendet den Supervisor hart"
  else
    ok "Agent entladen (KeepAlive aus)"
  fi
  if agent_disabled; then
    ok "Autostart gesperrt (launchctl disable)"
  else
    warn "Autostart nicht gesperrt — der Job startet beim naechsten Login wieder"
  fi
else
  ok "Agent nicht geladen (nichts zu entladen)"
fi

echo "== 2/3 run.sh + Forward-Traeger =="
# Nach einem bootout ist die Prozessgruppe schon weg (Schritt 1) — dann gibt es
# hier nichts zu tun, und genau das sagen wir auch, statt "lief nie". Der
# Supervisor wird zuerst beendet, weil ein von ihm gestarteter Erfolgswaechter
# den Forward sonst als "aktiv" melden koennte.
SUP="$(runsh_pids)"
if [ -n "$SUP" ]; then
  kill_pids TERM "$SUP"; sleep 1
  LEFT="$(runsh_pids)"
  [ -z "$LEFT" ] || kill_pids KILL "$LEFT"
  ok "run.sh beendet: $(echo "$SUP" | tr '\n' ' ')"
elif [ "$WAS_LOADED" = 1 ]; then
  ok "kein run.sh mehr — bootout hat die Prozessgruppe mitgenommen (Schritt 1)"
else
  ok "kein run.sh-Prozess (Agent war nicht geladen)"
fi
# autossh vor ssh: sonst verbindet autossh das getoetete ssh sofort neu.
BEFORE="$(tunnel_pids)"
if [ -n "$BEFORE" ]; then
  pkill -TERM -f -- "autossh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
  pkill -TERM -f -- "ssh .*$tunnel_sig .*$TARGET\$" 2>/dev/null || true
  sleep 1
  LEFT="$(tunnel_pids)"
  if [ -n "$LEFT" ]; then
    kill_pids KILL "$LEFT"
    sleep 1
    ok "Forward-Traeger hart beendet: $(echo "$BEFORE" | tr '\n' ' ')"
  else
    ok "Forward-Traeger beendet: $(echo "$BEFORE" | tr '\n' ' ')"
  fi
else
  ok "kein autossh/ssh mit Forward $BIND:$REMOTE gefunden"
fi
if [ -n "$(tunnel_pids)" ]; then
  warn "es laeuft noch ein Forward-Prozess — manuell pruefen: pgrep -fl '$tunnel_sig'"
else
  ok "kein Forward-Prozess mehr (VPS-Port $BIND:$REMOTE sollte frei sein)"
fi

echo "== 3/3 Master-Connection =="
# -p MUSS mit: %p im ControlPath wird sonst aus dem Default 22 expandiert und
# die Bereinigung zeigt bei SSH_PORT != 22 auf den falschen Socket.
if ssh -S "$MASTER_PATH" -p "$PORT" -O exit "$TARGET" >/dev/null 2>&1; then
  ok "Master-Connection geschlossen (/tmp/ssh-code-* weg)"
else
  ok "keine Master-Connection offen (kein Control-Socket)"
fi

# Gegencheck auf dem VPS, nur mit Key-Auth: sonst haengt der Doppelklick an
# einer Passphrase-Prompt. Ohne Key bleibt der Gegencheck diagnose.sh vorbehalten.
if [ "${SSH_KEY_AUTH:-0}" = 1 ] && [ -n "${SSH_IDENTITY:-}" ] && [ -f "${SSH_IDENTITY}" ]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o ControlPath=none -o IdentitiesOnly=yes \
       -o UseKeychain=yes -i "$SSH_IDENTITY" -p "$PORT" "$TARGET" \
       "ss -tln 2>/dev/null | grep -q ':$REMOTE'" 2>/dev/null; then
    warn "VPS lauscht noch auf :$REMOTE — bindet jemand den Port ausser uns?"
  else
    ok "VPS lauscht nicht mehr auf :$REMOTE (Gegencheck auf dem VPS)"
  fi
else
  warn "kein Key-Auth -> VPS-Gegencheck uebersprungen (./diagnose.sh zeigt den Port)"
fi

echo
echo "Tunnel gestoppt."
if port_up; then
  ok ":$LOCAL lauscht noch — der opencode serve kam nicht aus run.sh:127"
else
  ok ":$LOCAL ist zu: der superviste 'opencode serve' war ein Kind von run.sh und ist mit"
  echo "     der Prozessgruppe gestorben. Der naechste start-tunnel.command holt ihn"
  echo "     ueber ensure_opencode zurueck."
fi
echo "  https://$WEB/ ohne Cookie: weiter 302 -> /login.html. Das Gate steht, der Weg zum"
echo "  Mac fehlt: erst angemeldete Requests sehen es — Caddy bekommt 502 vom Proxy und"
echo "  liefert tunnel-down.html, der aktive Healthcheck (30s, 3 Fehlschlaege) setzt den"
echo "  Upstream auf down (Caddyfile.fragment Z. 61-66 und 91-100)."
echo "  Unberuehrt: 'opencode serve --service' (PPID 1) und laufende TUI-Sessions."
echo "  Wieder starten: ./start-tunnel.command   (hebt das disable wieder auf)"
echo "  Log: tail -20 /tmp/code-tunnel.log"
