#!/bin/bash
# =============================================================================
# dind-image-gc.sh — Aufräum-Job fuer den verschachtelten Docker-Daemon
# =============================================================================
# WARUM ein eigener Job:
#   Watchtower (Stack 10) raeumt nur den HOST-Daemon auf. Die Bilder im
#   DinD-Daemon (code-remote-dind) verwaltet niemand — die sind aktuell
#   78 GB gross und wachsen unbegrenzt, weil der Agenten-Workflow
#   Build-Images erzeugt (526x docker run, 51x docker build).
#
# ZIEL-DAEMON:
#   Standardmaessig der DinD (DOCKER_HOST=tcp://127.0.0.1:2375 via
#   docker exec). Der Host-Daemon wird NICHT angefasst — da ist Watchtower
#   zustaendig, und doppelte Prune-Jobs auf demselben Daemon sind wasteful.
#
# SICHERHEIT:
#   - Nur UNBENUTZTE Objekte werden entfernt. `image prune -a` fasst Images
#     an, die KEIN Container (auch kein gestoppter) referenziert.
#   - Retention-Filter: erst Objekte aelter als RETENTION_DAYS loeschen.
#     Dadurch bleiben Basis-Images (postgres, php-fpm, …) zwischen zwei
#     Builds liegen und muessen nicht jedes Mal neu gezogen werden.
#   - Lock gegen Ueberlappung (flock).
#   - Standard ist NICHT dry-run, aber --dry-run ist verfuegbar.
#
# Aufruf:
#   dind-image-gc.sh              # echter Lauf
#   dind-image-gc.sh --dry-run    # nur zeigen, was weg wuerde
#   dind-image-gc.sh --host-daemon   # stattdessen den Host-Daemon
# =============================================================================

set -euo pipefail

RETENTION_DAYS="${RETENTION_DAYS:-14}"
DIND_CONTAINER="${DIND_CONTAINER:-code-remote-dind}"
DRY_RUN=0
TARGET="dind"

for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --host-daemon) TARGET="host" ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

LOGFILE="${LOGFILE:-/var/log/dind-image-gc.log}"
LOCKFILE="${LOCKFILE:-/var/run/dind-image-gc.lock}"

log() { echo "[$(date '+%F %T')] $*" >> "$LOGFILE"; }

[[ $EUID -eq 0 ]] || { echo "muss als root laufen" >&2; exit 1; }
touch "$LOGFILE" 2>/dev/null || true

# Lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "SKIP: Ein GC-Lauf ist bereits aktiv ($LOCKFILE)"
  exit 0
fi

# --- Docker-Endpoint bestimmen ---------------------------------------------
# Der DinD-Daemon laeuft im Container. Wir fragen ihn ueber
# 'docker exec' ab, nicht ueber die IP: das funktioniert unabhaengig vom
# Port (rootless nutzt 2375 mit DOCKER_TLS_CERTDIR leer) und braucht kein
# Host-Netz.
if [[ "$TARGET" == "dind" ]]; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$DIND_CONTAINER"; then
    log "uebersprungen: Container $DIND_CONTAINER laeuft nicht"
    exit 0
  fi
  # Socket-Pfad INNEN im Container erfragen, statt ihn zu raten:
  #   rootless   -> /run/user/1000/docker.sock
  #   privileged -> /var/run/docker.sock
  # So greift das Skript vor UND nach der Umstellung auf rootless.
  DIND_SOCK="$(
    docker exec "$DIND_CONTAINER" sh -c \
      'for s in /run/user/1000/docker.sock /var/run/docker.sock; do [ -S "$s" ] && echo "$s" && exit 0; done; echo /var/run/docker.sock' \
      2>/dev/null | tr -d '\r'
  )"
  DIND_SOCK="${DIND_SOCK:-/var/run/docker.sock}"
  DOCKER_IN_DIND="docker exec -e DOCKER_HOST=unix://$DIND_SOCK $DIND_CONTAINER docker"
  DAEMON_LABEL="$DIND_CONTAINER ($DIND_SOCK)"
else
  DOCKER_IN_DIND="docker"
  DAEMON_LABEL="host"
fi

# Funktioniert die Verbindung?
if ! $DOCKER_IN_DIND version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  log "FEHLER: Daemon ($DAEMON_LABEL) nicht erreichbar — uebersprungen"
  log "  Bei rootless DinD: laeuft er mit DOCKER_TLS_CERTDIR= (leer) und dann auf 2375."
  log "  Pruefen: docker exec $DIND_CONTAINER sh -c 'DOCKER_HOST=unix:///run/user/1000/docker.sock docker info'"
  exit 0
fi

SRV=$($DOCKER_IN_DIND version --format '{{.Server.Version}}' 2>/dev/null || echo '?')
ROOTLESS=$($DOCKER_IN_DIND info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null | grep -q rootless && echo "ja" || echo "nein")

log "=========================================================="
log "dind-image-gc: Daemon=$DAEMON_LABEL Version=$SRV rootless=$ROOTLESS"
log "Retention=${RETENTION_DAYS}d DryRun=$DRY_RUN"

before=$($DOCKER_IN_DIND system df --format '{{.Size}}' 2>/dev/null | head -1 || echo '?')
log "Vorher gesamt: $before"
log "System-df vorher:"
$DOCKER_IN_DIND system df 2>/dev/null | sed 's/^/  /' >> "$LOGFILE"

if [[ $DRY_RUN -eq 1 ]]; then
  log "DRY-RUN — nichts wird geloescht. Was waere reclaimable:"
  $DOCKER_IN_DIND system df 2>/dev/null | sed 's/^/  /' >> "$LOGFILE"
  $DOCKER_IN_DIND system df --format '{{.Type}} reclaimable: {{.Reclaimable}} ({{.Percent}})' 2>/dev/null \
    | grep -viE ' reclaimable: 0B' | sed 's/^/  /' >> "$LOGFILE"
  log "Befehle waeren:"
  log "  image prune    -a --filter until=${RETENTION_DAYS}h"
  log "  builder prune  -a --filter until=${RETENTION_DAYS}h"
  log "  volume prune     --filter until=${RETENTION_DAYS}h   <- groesster Posten"
  log "  container prune  --filter until=${RETENTION_DAYS}h"
  log "  network  prune   --filter until=${RETENTION_DAYS}h"
  exit 0
fi

# Reihenfolge nach Groessenwirkung, nicht nach Gewohnheit: bei einem
# agenten-Workflow mit vielen 'docker run' OHNE --rm sind es die anonymen
# Volumes, die den Platz fressen (live gemessen: 76 GB von 78 GB), nicht
# die Images. Deshalb steht volume prune hier bewusst weit oben.
# Nur dangling/unbenutzt, mit Altersfilter — aktive Volumes bleiben.
# --- Volumes: Alter selbst pruefen ------------------------------------------
# 'docker volume prune' kennt KEINEN until-Filter (nur label=) — ein
# '--filter until=14h' liefert "Error response from daemon: invalid filter
# 'until'". Ohne Altersschutz wuerde '-a' sofort ALLES unbenutzte loeschen.
#
# Deshalb: dangling Volumes listen, CreatedAt auslesen, nur die aelter als
# RETENTION_DAYS loeschen. 'docker volume rm' verweigert den Dienst, wenn ein
# Volume doch noch benutzt wird — zweite Sicherung.
#
# Groesster Posten: live gemessen 15 verwaiste anonyme Volumes mit 76,44 GB
# bei 0 aktiven. Ursache: 'docker run' ohne --rm legt bei Images mit VOLUME
# ein anonymes Volume an, und 'docker rm' ohne -v nimmt es nicht mit.
log "  volumes: Alterspruefung selbst (behalte juenger als ${RETENTION_DAYS}d)"
cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%s 2>/dev/null || echo 0)"
vol_list="$($DOCKER_IN_DIND volume ls --filter dangling=true --format '{{.Name}}' 2>/dev/null)"
vol_n=0
if [[ -n "$vol_list" && "$cutoff" -gt 0 ]]; then
  while read -r vname; do
    [[ -z "$vname" ]] && continue
    created="$($DOCKER_IN_DIND volume inspect --format '{{.CreatedAt}}' "$vname" 2>/dev/null)"
    [[ -z "$created" ]] && continue
    cts="$(date -u -d "$created" +%s 2>/dev/null || echo 0)"
    [[ "$cts" -eq 0 ]] && continue
    if [[ "$cts" -lt "$cutoff" ]]; then
      log "    loesche Volume $vname (erstellt $created)"
      if $DOCKER_IN_DIND volume rm "$vname" >>"$LOGFILE" 2>&1; then
        vol_n=$((vol_n + 1))
      else
        log "      (nicht loeschbar, vermutlich doch benutzt)"
      fi
    else
      log "    behalte Volume $vname (erstellt $created)"
    fi
  done <<< "$vol_list"
  log "    -> $vol_n Volume(s) geloescht"
else
  log "    (keine dangling Volumes, oder cutoff nicht berechenbar)"
fi

log "  builder prune -a --filter until=${RETENTION_DAYS}h"
$DOCKER_IN_DIND builder prune -a --force --filter "until=${RETENTION_DAYS}h" >>"$LOGFILE" 2>&1 || \
  log "    (builder prune meldete Fehler, siehe Log)"

log "  image prune -a --filter until=${RETENTION_DAYS}h"
$DOCKER_IN_DIND image prune -a --force --filter "until=${RETENTION_DAYS}h" >>"$LOGFILE" 2>&1 || \
  log "    (image prune meldete Fehler, siehe Log)"

# Gestoppte Container, verwaiste Netze
log "  container prune --filter until=${RETENTION_DAYS}h"
$DOCKER_IN_DIND container prune --force --filter "until=${RETENTION_DAYS}h" >>"$LOGFILE" 2>&1 || true
log "  network prune --filter until=${RETENTION_DAYS}h"
$DOCKER_IN_DIND network prune --force --filter "until=${RETENTION_DAYS}h" >>"$LOGFILE" 2>&1 || true

after=$($DOCKER_IN_DIND system df --format '{{.Size}}' 2>/dev/null | head -1 || echo '?')
log "Nachher gesamt: $after"
log "System-df nachher:"
$DOCKER_IN_DIND system df 2>/dev/null | sed 's/^/  /' >> "$LOGFILE"
log "dind-image-gc fertig."
log "=========================================================="
