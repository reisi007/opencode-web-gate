#!/usr/bin/env bash
# Deployt ausschliesslich die Compose-Datei des Remote-Stacks.
# Die Host-.env bleibt unangetastet und muss bereits vorhanden sein.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="dev-vm"
REMOTE_DIR="/opt/stacks/${STACK_NAME}"
REMOTE_ENV="${REMOTE_DIR}/.env"
COMPOSE_FILE="${ROOT_DIR}/remote/docker-compose.yml"
DEPLOY_TARGET="root@reisinger.pictures"
SSH_PORT="${SSH_PORT:-22}"
DRY_RUN=0

usage() {
  echo "Aufruf: $0 [--dry-run]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi
if [[ $# -eq 1 ]]; then
  if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=1
  else
    usage
    exit 2
  fi
fi

CONTROL_DIR="${HOME}/.ssh/opencode-web-gate"
SSH_OPTS=(
  -p "$SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=10
)
if [[ "$DRY_RUN" -eq 1 ]]; then
  # Do not create a local control socket or directory during a dry run.
  SSH_OPTS+=(-o ControlMaster=no -o ControlPath=none)
else
  if [[ -L "$CONTROL_DIR" ]]; then
    echo "FEHLER: SSH-Control-Verzeichnis ist ein Symlink: ${CONTROL_DIR}" >&2
    exit 1
  fi
  (umask 077 && mkdir -p "$CONTROL_DIR")
  if [[ "$(uname -s)" == Darwin ]]; then
    CONTROL_META="$(stat -f '%u %Lp' "$CONTROL_DIR")"
  else
    CONTROL_META="$(stat -c '%u %a' "$CONTROL_DIR")"
  fi
  read -r CONTROL_OWNER CONTROL_MODE <<< "$CONTROL_META"
  if [[ "$CONTROL_OWNER" != "$(id -u)" || "$CONTROL_MODE" != 700 ]]; then
    echo "FEHLER: SSH-Control-Verzeichnis muss dem aktuellen Benutzer gehören und Modus 0700 haben." >&2
    exit 1
  fi
  SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=${CONTROL_DIR}/%C" -o ControlPersist=60)
fi

REMOTE_STATUS=""
if ! REMOTE_STATUS="$(ssh "${SSH_OPTS[@]}" "$DEPLOY_TARGET" \
  'if [ ! -d /opt/stacks/dev-vm ]; then printf missing-dir; elif [ ! -f /opt/stacks/dev-vm/.env ]; then printf missing-env; elif [ "$(stat -c "%u:%g:%a" /opt/stacks/dev-vm/.env 2>/dev/null)" != "0:0:600" ]; then printf bad-env; else printf ok; fi')"; then
  echo "FEHLER: SSH-Vorprüfung auf ${DEPLOY_TARGET} fehlgeschlagen." >&2
  exit 1
fi

case "$REMOTE_STATUS" in
  ok) ;;
  missing-dir)
    echo "FEHLER: ${REMOTE_DIR} fehlt auf dem Host; Stack-Verzeichnis zuerst anlegen." >&2
    exit 1
    ;;
  missing-env)
    echo "FEHLER: ${REMOTE_ENV} fehlt auf dem Host. Die Datei muss dort root:root mit Modus 0600 angelegt werden; dieses Skript erzeugt oder überträgt sie nie." >&2
    exit 1
    ;;
  bad-env)
    echo "FEHLER: ${REMOTE_ENV} muss root:root gehören und Modus 0600 haben." >&2
    exit 1
    ;;
  *)
    echo "FEHLER: Unerwartete Antwort bei der Host-Vorprüfung." >&2
    exit 1
    ;;
esac

RSYNC_BIN="${RSYNC_BIN:-$(command -v rsync || true)}"
if [[ -z "$RSYNC_BIN" ]]; then
  echo "FEHLER: rsync fehlt." >&2
  exit 1
fi

# Connection-Reuse fuer Vorpruefung, rsync und Compose-Aufruf.
RSH="ssh $(printf '%q ' "${SSH_OPTS[@]}")"
RSYNC_OPTS=(--times --itemize-changes --rsh="$RSH")
if [[ "$DRY_RUN" -eq 1 ]]; then
  RSYNC_OPTS+=(--dry-run)
fi

REMOTE_CANDIDATE="${REMOTE_DIR}/.compose.candidate.$$.${RANDOM}.yaml"
cleanup_candidate() {
  if ! ssh "${SSH_OPTS[@]}" "$DEPLOY_TARGET" bash -s -- "$REMOTE_CANDIDATE" <<'CLEANUP'
set -euo pipefail
rm -f -- "$1"
CLEANUP
  then
    echo "WARNUNG: Kandidat ${REMOTE_CANDIDATE} konnte nicht entfernt werden und muss auf dem Host geprueft werden." >&2
  fi
}

echo "Hinweis: Vor dem Deploy den effektiven AUTH_HASH in ${REMOTE_ENV} pruefen (er muss zum laufenden Auth-Container passen); dieses Skript liest und aendert die Host-.env nicht." >&2
echo "Deploy ${COMPOSE_FILE} -> ${DEPLOY_TARGET}:${REMOTE_CANDIDATE} ..."
if ! "$RSYNC_BIN" "${RSYNC_OPTS[@]}" "$COMPOSE_FILE" "${DEPLOY_TARGET}:${REMOTE_CANDIDATE}"; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    cleanup_candidate
  fi
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run abgeschlossen; Compose wurde nicht gestartet."
  exit 0
fi

echo "Pruefe Kandidat und code-dev-RAM-Limits vor dem Ersetzen der aktiven Compose-Datei ..."
if ! ssh "${SSH_OPTS[@]}" "$DEPLOY_TARGET" bash -s -- "$REMOTE_CANDIDATE" <<'REMOTE'
set -euo pipefail
candidate="$1"
stack_dir="/opt/stacks/dev-vm"
compose_file="${stack_dir}/compose.yaml"
env_file="${stack_dir}/.env"
case "$candidate" in
  /opt/stacks/dev-vm/.compose.candidate.*.yaml) ;;
  *) echo "FEHLER: Kandidatenpfad ausserhalb des Stack-Verzeichnisses." >&2; exit 2 ;;
esac
if [[ ! -f "$candidate" || -L "$candidate" ]]; then
  echo "FEHLER: Deploy-Kandidat fehlt oder ist ungueltig." >&2
  exit 1
fi
trap 'rm -f -- "$candidate"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
  echo "FEHLER: python3 fehlt auf dem Host; die RAM-Limit-Pruefung braucht python3 (siehe remote/README.md)." >&2
  exit 1
fi

if ! docker compose -p dev-vm --project-directory "$stack_dir" \
  --env-file "$env_file" -f "$candidate" config -q; then
  echo "FEHLER: Compose-Konfiguration des Kandidaten ungueltig; aktive Compose-Datei bleibt unveraendert." >&2
  exit 1
fi

if ! resolved_limits="$(docker compose -p dev-vm --project-directory "$stack_dir" \
  --env-file "$env_file" -f "$candidate" config --format json \
  | python3 -c 'import json,sys; service=json.load(sys.stdin)["services"]["code-dev"]; values=(service.get("mem_limit"),service.get("memswap_limit")); sys.exit(1) if any(value is None for value in values) else print(*values)')"; then
  echo "FEHLER: effektive code-dev-Limits konnten nicht aus Compose gelesen werden." >&2
  exit 1
fi
read -r resolved_memory resolved_memswap <<< "$resolved_limits"

if ! live_limits="$(docker inspect --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' code-dev)"; then
  echo "FEHLER: code-dev fehlt; die offene Memory-Drift kann nicht sicher geprueft werden." >&2
  exit 1
fi
read -r live_memory live_memswap <<< "$live_limits"

if [[ "$resolved_memory" != "$live_memory" || "$resolved_memswap" != "$live_memswap" ]]; then
  printf 'FEHLER: Compose code-dev limits (%s/%s bytes) weichen vom laufenden Container (%s/%s bytes) ab. Deploy abgebrochen; die offene 5g/9g-vs-7g/12g-Drift braucht eine Owner-Entscheidung.\n' \
    "$resolved_memory" "$resolved_memswap" "$live_memory" "$live_memswap" >&2
  exit 1
fi

printf 'code-dev RAM-Limits unveraendert (%s/%s bytes).\n' "$live_memory" "$live_memswap"

backup="${stack_dir}/.compose.previous.$$.${RANDOM}.yaml"
if [[ -f "$compose_file" ]]; then
  if ! cp -p -- "$compose_file" "$backup"; then
    rm -f -- "$backup"
    echo "FEHLER: bestehende Compose-Datei konnte nicht als Recovery-Backup gesichert werden." >&2
    exit 1
  fi
else
  backup=""
fi

if ! mv -f -- "$candidate" "$compose_file"; then
  echo "FEHLER: Kandidat konnte nicht atomar zur aktiven Compose-Datei werden." >&2
  if [[ -n "$backup" ]]; then rm -f -- "$backup"; fi
  exit 1
fi
trap - EXIT

if ! docker compose -p dev-vm --project-directory "$stack_dir" \
  --env-file "$env_file" -f "$compose_file" up -d --wait; then
  echo "FEHLER: docker compose up ist fehlgeschlagen." >&2
  if [[ -n "$backup" ]]; then
    if mv -f -- "$backup" "$compose_file"; then
      echo "Vorherige compose.yaml wurde wiederhergestellt; Stack- und Containerstatus pruefen." >&2
    else
      echo "FEHLER: Wiederherstellung fehlgeschlagen; Recovery-Backup bleibt unter ${backup}." >&2
    fi
  else
    echo "FEHLER: Es gab keine vorherige compose.yaml zum Wiederherstellen; Stack- und Containerstatus pruefen." >&2
  fi
  exit 1
fi

if [[ -n "$backup" ]]; then rm -f -- "$backup"; fi

if ! docker compose -p dev-vm --project-directory "$stack_dir" \
  --env-file "$env_file" -f "$compose_file" ps; then
  echo "WARNUNG: 'docker compose up' war erfolgreich, aber 'docker compose ps' ist fehlgeschlagen; Stack-Status auf dem Host pruefen." >&2
fi
REMOTE
then
  cleanup_candidate
  echo "FEHLER: Remote-Deploy fehlgeschlagen. Validierungsfehler erhalten die aktive Compose-Datei; nach Fehlern waehrend 'up' den Stack- und Containerstatus auf dem Host pruefen." >&2
  exit 1
fi
echo "Deploy ${STACK_NAME} abgeschlossen."
