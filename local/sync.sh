#!/usr/bin/env bash
# sync.sh — Login-/Offline-Seite (apps/web/dist) via rsync/ssh auf den VPS.
#
# Ersetzt die rclone-Sftp-Variante (Remote "reisinger.pictures", Port 2222).
# Dieselbe Migration wie in all-the.rest und portal.reisinger.pictures
# (2026-09-26), Hintergrund und Reihenfolge dort: strato-vps/README.md.
#
# Aufruf:
#   ./sync.sh              echter Deploy (macht live, siehe AGENTS.md §11)
#   ./sync.sh --dry-run    nur anzeigen, nichts aendern (empfohlen zuerst)
set -euo pipefail
cd "$(dirname "$0")"
# sync.sh laeuft aus bootstrap.sh heraus, also auch aus dem Finder-Doppelklick
# mit reduziertem PATH — sonst findet der Doppelklick das Homebrew-rsync nicht.
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

# --- GNU-rsync-Pflicht -------------------------------------------------------
# macOS liefert per Default /usr/bin/rsync = openrsync (Protokoll 29), das weder
# --chown noch --chmod im benoetigten Umfang unterstuetzt.
# WICHTIG: nicht per `rsync --version | grep -q ...` pruefen. Unter `set -o
# pipefail` beendet `grep -q` den Upstream vorzeitig per SIGPIPE, die Pipeline
# gilt dann als fehlgeschlagen und der Guard schlaegt IMMER an. Deshalb die
# Ausgabe zuerst in eine Variable ziehen.
RSYNC_BIN="${RSYNC_BIN:-$(command -v rsync || true)}"
_rsync_version="$("$RSYNC_BIN" --version 2>/dev/null | head -1 || true)"
if [[ "$_rsync_version" != "rsync  version"* ]]; then
  echo "FEHLER: GNU-rsync benoetigt (macOS-Default ist openrsync)." >&2
  echo "       Install:  brew install rsync" >&2
  echo "       Oder:     RSYNC_BIN=/opt/homebrew/bin/rsync ./sync.sh" >&2
  exit 1
fi
unset _rsync_version

# --- Ziele ------------------------------------------------------------------
# Achtung beim Testen: LOCAL_DIST steht in .env, und `source ../.env` oben
# ueberschreibt einen von aussen exportierten Wert. `LOCAL_DIST=/tmp/x ./sync.sh
# --dry-run` aus der Shell wird also ignoriert und zeigt still einen No-Op.
# Zum Ausprobieren den Wert in .env aendern, nicht per Environment.
DIST="${LOCAL_DIST:-apps/web/dist}"
# Achtung: es gibt keinen SFTP-Chroot mehr, der SFTPGo-Weg (Port 2222, User
# webadmin) ist weg — der Publish laeuft wie in den anderen Repos ueber
# root@<host> auf Port 22. /srv/websites ist im caddy-Container ein Bind-Mount
# auf genau dieses Verzeichnis.
SITES_ROOT="${SYNC_SITES_ROOT:-/home/webadmin/websites}"
SITE_DIR="${SYNC_SITE_DIR:-code.all-the.rest}"
TARGET="${SSH_TARGET:?FEHLER: SSH_TARGET fehlt in .env}"
PORT="${SSH_PORT:-22}"
DEST="${TARGET}:${SITES_ROOT}/${SITE_DIR}/"

# Key-Optionen wie in run.sh: bootstrap.sh ruft sync.sh ohne TTY auf, also
# BatchMode + UseKeychain — sonst haengt der Publish an einer Passphrase-Prompt
# bzw. bricht ab, wenn gar kein Terminal da ist.
KEY_OPTS=()
if [ "${SSH_KEY_AUTH:-0}" = 1 ] && [ -n "${SSH_IDENTITY:-}" ] && [ -f "${SSH_IDENTITY}" ]; then
  KEY_OPTS=(-o IdentitiesOnly=yes -o UseKeychain=yes -i "$SSH_IDENTITY")
fi
# Connection-Reuse: /tmp/ssh-sync-* ist bewusst ein eigener Socket, nicht der
# des Tunnels (/tmp/ssh-code-*, local/AGENTS.md §1) — der Tunnel soll ohne
# Master-Connection auskommen, der Publish darf sie nicht mitbenutzen.
SSH_OPTS=(-o BatchMode=yes -o ControlMaster=auto -o ControlPath='/tmp/ssh-sync-%r@%h:%p' -o ControlPersist=60)
if [ "${#KEY_OPTS[@]}" -gt 0 ]; then
  SSH_OPTS+=("${KEY_OPTS[@]}")
fi
# --rsh ist ein einzelner String; %q haelt Pfade mit Leerzeichen intakt.
RSH="ssh -p $PORT $(printf '%q ' "${SSH_OPTS[@]}")"

# --delete-Sicherheitsnetz. Der Publish ist sofort und ist die Tuer des Gates
# (AGENTS.md §11) — deshalb darf ein falsches SYNC_SITE_DIR nicht still
# woanders loeschen. Das Zielverzeichnis gehoert ausschliesslich diesem Sync
# (live genau login.html + tunnel-down.html). Alles, was nicht `*.html` ist,
# stoppt den Deploy.
STRAY="$(ssh -p "$PORT" "${SSH_OPTS[@]}" "$TARGET" \
  "ls -A '$SITES_ROOT/$SITE_DIR' 2>/dev/null | grep -v '\.html\$' || true")"
if [ -n "$STRAY" ]; then
  echo "FEHLER: Im Ziel liegen Dateien, die nicht aus $DIST stammen — --delete wuerde sie loeschen:" >&2
  printf '  %s\n' "$STRAY" >&2
  exit 1
fi

# Rechte-Modell der Sites: 1002:webgroup, Dateien 666, Verzeichnisse 2777
# (setgid). Ein reines -a wuerde die LOKALEN Rechte (644/755) durchdruecken
# und das Modell zerstoeren — identisch zu all-the.rest/sync.sh.
echo "Sync $DIST/ -> $DEST ..."
"$RSYNC_BIN" "$DIST/" "$DEST" \
  --archive \
  --delete \
  --chown=1002:webgroup \
  --chmod=D2777,F666 \
  --info=progress2 \
  --rsh="$RSH" \
  "$@"
echo "Sync ok."
