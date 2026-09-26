#!/usr/bin/env bash
# start-tunnel.command – Doppelklick am Mac: richtet beim Start alles ein
# (autossh, SSH-Key, LaunchAgent com.code-tunnel), spiegelt die Login-Seite und
# startet den Tunnel. Das Terminal-Fenster kann danach geschlossen werden:
# der LaunchAgent startet beim Login neu und nach jedem Absturz wieder.
# Ohne launchd/Key-Auth (z. B. Fremd-Mac) Fallback: Tunnel im Vordergrund,
# dann Fenster offen lassen (Ctrl+C beendet).
set -euo pipefail
cd "$(dirname "$0")"
if ./bootstrap.sh; then
  exit 0
fi
echo
echo "Bootstrap nicht vollstaendig -> Fallback: Tunnel hier im Vordergrund."
echo "Terminal-Fenster offen lassen (Ctrl+C beendet den Tunnel)."
exec ./run.sh
