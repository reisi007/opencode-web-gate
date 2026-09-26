#!/usr/bin/env bash
# bootstrap.sh: einmaliges, idempotentes Setup des lokalen Wegs.
# start-tunnel.command ruft das bei JEDEM Start auf — ist alles fertig, ist es
# ein kurzer Health-Check ohne Neustart des Tunnels.
#
#   1) autossh nachinstallieren, falls fehlt   -> Tunnel verbindet nach Netzverlust neu
#   2) bestehenden SSH-Key nutzbar machen      -> bestehender Key mit Passphrase, die
#      einmalig in die macOS-Keychain wandert (launchd hat beim Autostart kein TTY).
#      Ist der Public Key auf dem VPS schon freigeschaltet, kostet das genau eine
#      Passphrase-Eingabe. Es wird BEWUSST kein Key ohne Passphrase erzeugt.
#   3) LaunchAgent com.code-tunnel rendern + laden -> Autostart beim Login + Watchdog
#   4) Login-/Offline-Seite per rclone spiegeln, Tunnel starten, verifizieren
#
# Ergebnis: der Tunnel laeuft als LaunchAgent. Das Terminal-Fenster kann
# geschlossen werden; `launchctl bootout gui/$(id -u)/com.code-tunnel` stoppt ihn.
set -euo pipefail
cd "$(dirname "$0")"
# Doppelklick (.command) startet mit minimalem PATH -> Werkzeuge auffindbar machen
export PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -f ../.env ]; then
  ENV_FILE=../.env
  # shellcheck disable=SC1091
  source ../.env
elif [ -f .env ]; then
  ENV_FILE=./.env
  # shellcheck disable=SC1091
  source .env
else
  echo ".env fehlt -> ../setup.sh"; exit 1
fi

TARGET="${SSH_TARGET:?FEHLER: SSH_TARGET fehlt in .env}"
PORT="${SSH_PORT:-22}"
BIND="${REMOTE_BIND:-172.18.0.1}"
REMOTE="${REMOTE_PORT:-18731}"
LOCAL="${LOCAL_PORT:-8080}"
DOMAIN="${CODE_DOMAIN:-code.example.com}"

LABEL=com.code-tunnel
AGENT_FILE="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="scripts/$LABEL.plist"
REPO="$(cd .. && pwd)"
# Kanonischer PATH fuer die plist. Der PATH des Aufrufers waere falsch: ein Start
# aus dem Finder (minimales PATH) und einer aus der Shell ergaeben verschiedene
# plists -> cmp schlaegt fehl -> der Tunnel startet grundlos neu. Die Laufzeit-PATH
# setzt run.sh selbst.
PLIST_PATH="$HOME/.opencode/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ok() { echo "OK   $1"; }
warn() { echo "WARN $1"; }
die() { echo "FEHLER: $1" >&2; exit 1; }

# sed-Ersatz: Pfade duerfen & | \ nicht enthalten, sonst expandiert der Match.
esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# KEY=VALUE idempotent in die gesetzte .env schreiben (single source of truth, gitignored)
set_env() {
  local k="$1" v="$2"
  if grep -q "^$k=" "$ENV_FILE" 2>/dev/null; then
    grep -qxF "$k=$v" "$ENV_FILE" || sed -i '' "s|^$k=.*|$k=$(esc "$v")|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$ENV_FILE"
    echo "     .env: $k=$v ergaenzt"
  fi
}

key_auth_works() { "${KEY_SSH[@]}" "$TARGET" true >/dev/null 2>&1; }
forward_up() { "${KEY_SSH[@]}" "$TARGET" "ss -tln 2>/dev/null | grep -q ':$REMOTE'" >/dev/null 2>&1; }
agent_loaded() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }
# Laeuft der Tunnel mit dem konfigurierten Key? Ein laufender Agent hat sein .env
# schon gelesen — nach einem Key-Wechsel muss er neu gestartet werden, sonst
# behaelt er den alten Key. Das Muster nimmt die Forward-Signatur dazu, damit die
# kurzen Key-Health-Checks (gleiche Optionen, aber ohne -R) nicht matchen.
tunnel_uses_identity() { pgrep -f -- "-i $IDENTITY .*-R $BIND:$REMOTE:" >/dev/null 2>&1; }

echo "== 1/4 autossh =="
if command -v autossh >/dev/null 2>&1; then
  ok "autossh $(autossh -V 2>&1 | head -1) — Reconnect aktiv"
else
  command -v brew >/dev/null 2>&1 || die "autossh und brew fehlen -> 'brew install autossh'"
  brew install autossh >/dev/null || die "brew install autossh fehlgeschlagen"
  ok "autossh installiert"
fi

echo "== 2/4 SSH-Key (bestehender Key, Passphrase 1x in die Keychain) =="
# Reihenfolge: .env, dann uebliche Standardnamen (id_ed25519 vor id_rsa).
IDENTITY=""
if [ -n "${SSH_IDENTITY:-}" ]; then
  IDENTITY="$SSH_IDENTITY"
else
  for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
    [ -f "$candidate" ] && { IDENTITY="$candidate"; break; }
  done
fi
[ -n "$IDENTITY" ] || die "kein SSH-Key gefunden — 'ssh-keygen -t ed25519' oder SSH_IDENTITY in .env setzen"
[ -f "$IDENTITY" ] || die "Key $IDENTITY fehlt (SSH_IDENTITY in .env)"
[ -f "$IDENTITY.pub" ] || die "Public Key fehlt: $IDENTITY.pub — 'ssh-keygen -y -f \"$IDENTITY\" > \"$IDENTITY.pub\"'"
ok "Key: $IDENTITY ($(ssh-keygen -lf "$IDENTITY.pub" | awk '{print $2}'))"

# ssh mit Key, nicht-interaktiv. UseKeychain=yes ist der Punkt, der den Key ohne
# TTY entsperrt: die Passphrase liegt in der Login-Keychain, nicht im Key.
# Wird erst HIER definiert — Arrays expandieren sofort, $IDENTITY muss stehen.
# ConnectTimeout: bei totem Host sonst ~75 s pro Versuch (Review-Fund).
KEY_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlPath=none -o IdentitiesOnly=yes -o UseKeychain=yes -i "$IDENTITY" -p "$PORT")
# ueber bestehende Master-Connection, sonst interaktiv (1x Passphrase des VPS-Users)
AUTH_SSH=(ssh -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath='/tmp/ssh-code-%r@%h:%p' -o ControlPersist=60 -p "$PORT")
if key_auth_works; then
  ok "Key-Auth nicht-interaktiv moeglich (Keychain hat die Passphrase)"
else
  # Passphrase einmalig in die macOS-Keychain — danach entsperrt UseKeychain=yes
  # den Key auch der LaunchAgent, weil ssh die Keychain statt /dev/tty nutzt.
  # Wichtig: `ssh-add -l` ist als Probe unbrauchbar, es liefert Exit 1 wenn der
  # Agent erreichbar, aber leer ist — genau der Normalfall hier.
  if [ "$(uname)" = Darwin ]; then
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "${SSH_AUTH_SOCK}" ] \
       && ssh-add --apple-use-keychain "$IDENTITY"; then
      ok "Passphrase in der macOS-Keychain (ssh-add)"
    else
      echo "     -> Passphrase einmalig eingeben (die macOS-Keychain merkt sie sich):"
      if "${AUTH_SSH[@]}" -o BatchMode=no -o UseKeychain=yes -o IdentitiesOnly=yes \
           -i "$IDENTITY" "$TARGET" true; then
        ok "Passphrase in der macOS-Keychain (ssh)"
      fi
    fi
  fi
  # Key-auth fehlt weiterhin -> Public Key ist am VPS nicht freigeschaltet.
  if ! key_auth_works; then
    echo "     -> Public Key wird auf $TARGET hinterlegt (VPS-Passphrase 1x noetig)..."
    cat "$IDENTITY.pub" | "${AUTH_SSH[@]}" "$TARGET" \
      'umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; k=$(cat); grep -qxF "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys; echo "     authorized_keys: $(wc -l < ~/.ssh/authorized_keys) Eintraege"' \
      || warn "authorized_keys-Update fehlgeschlagen"
  fi
fi
key_auth_works || die "Key-Auth nicht moeglich — Tunnel bleibt passwort-abhaengig, Autostart aus.
  Abhilfe: einmalig 'ssh -i \"$IDENTITY\" $TARGET true' im Terminal (Passphrase eingeben,
  wird von der Keychain gemerkt) und start-tunnel.command erneut starten."
set_env SSH_IDENTITY "$IDENTITY"
set_env SSH_KEY_AUTH 1

echo "== 3/4 LaunchAgent $LABEL =="
[ -f "$TEMPLATE" ] || die "Vorlage $TEMPLATE fehlt"
mkdir -p "$HOME/Library/LaunchAgents"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
REPO_E="$(esc "$REPO")"
PATH_E="$(esc "$PLIST_PATH")"
# shellcheck disable=SC2016
sed -e "s|__REPO__|$REPO_E|g" -e "s|__PATH__|$PATH_E|g" "$TEMPLATE" >"$TMP"
plutil -lint "$TMP" >/dev/null || die "gerenderte plist ist ungueltig"
CHANGED=0
if [ -f "$AGENT_FILE" ] && cmp -s "$TMP" "$AGENT_FILE"; then
  ok "Agent-Datei aktuell"
else
  mv "$TMP" "$AGENT_FILE"
  CHANGED=1
  ok "Agent-Datei geschrieben: $AGENT_FILE"
fi
trap - EXIT

# Fast-Path: Agent laeuft, Forward steht, Datei unveraendert, Key passt -> nichts anfassen.
if [ "$CHANGED" = 0 ] && agent_loaded && forward_up && tunnel_uses_identity; then
  echo "== 4/4 Status =="
  ok "Tunnel laeuft bereits (LaunchAgent, Key $IDENTITY, Forward VPS $BIND:$REMOTE steht)"
  echo "     Log: tail -f /tmp/code-tunnel.log"
  echo "     Stoppen: launchctl bootout gui/$(id -u)/$LABEL"
  exit 0
fi

echo "== 4/4 Website-Sync + Start =="
./sync.sh || warn "rclone-Sync fehlgeschlagen (Remote '${RCLONE_REMOTE:-vps.example.com}:' in rclone config?)"

# enable VOR bootstrap: ein zuvor `launchctl disable`ter Job waere sonst disabled
# geladen und RunAtLoad feuerte nicht.
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
if agent_loaded; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi
launchctl bootstrap "gui/$(id -u)" "$AGENT_FILE" || die "launchctl bootstrap fehlgeschlagen"
agent_loaded || die "Agent $LABEL nicht geladen"
# kickstart statt nur RunAtLoad: der Job kann geladen, aber sein Prozess tot sein
# (KeepAlive ist dann erst nach ThrottleInterval wieder dran).
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
ok "Agent geladen (gui/$(id -u)/$LABEL)"

for _ in $(seq 1 30); do
  forward_up && break
  sleep 2
done
if forward_up; then
  ok "Tunnel steht: VPS $BIND:$REMOTE -> Mac 127.0.0.1:$LOCAL (Key $IDENTITY)"
else
  warn "Forward $BIND:$REMOTE nach 60s nicht auf dem VPS sichtbar -> /tmp/code-tunnel.log"
fi
echo
echo "Fertig — Fenster schliessen ist safe, der LaunchAgent laeuft weiter."
echo "  Key:       $IDENTITY (Passphrase in der macOS-Keychain, kein TTY noetig)"
echo "  Autostart: beim Login (RunAtLoad)"
echo "  Watchdog:  KeepAlive startet nach jedem Absturz neu"
echo "  Reconnect: autossh + ServerAliveInterval (auch nach Sleep/WLAN-Wechsel)"
echo "  Status:    launchctl print gui/\$(id -u)/$LABEL | head -20"
echo "  Log:       tail -f /tmp/code-tunnel.log"
echo "  Stoppen:   launchctl bootout gui/\$(id -u)/$LABEL"
echo "  Website:   https://$DOMAIN/"
