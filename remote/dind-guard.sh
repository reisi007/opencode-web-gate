#!/usr/bin/env bash
# =============================================================================
# dind-guard.sh — hostseitiger OOM-Schutz fuer den rootless DinD
# =============================================================================
# WARUM ein eigener Host-Dienst:
#   Im rootless DinD gibt es KEINE inneren cgroups (Alpine ohne systemd,
#   /sys/fs/cgroup im Container read-only). `mem_limit`/`cpus` an inneren
#   Containern sind deshalb wirkungslos. Der einzige wirksame Deckel ist der
#   aeussere Container `code-remote-dind`; fruehere OOMs trafen den dind-Daemon.
#   Der Host setzt jetzt oom_score_adj=-500 auf den aeusseren Init. Der Guard
#   beobachtet den Deckel und stoppt nur E2E-Container mit dem Label
#   `com.agent-tasks.stack` im verschachtelten Daemon.
#
# ZIEL (bewusst eng):
#   NUR laufende Container INNERHALB von `code-remote-dind` mit dem Label
#   `com.agent-tasks.stack`. Nie Host-Container, nie `code-dev`, kein
#   pauschales `docker stop` auf dem Host-Daemon.
#
# TRIGGER:
#   1. `oom_kill` in der Host-cgroup des dind-Containers steigt.
#   2. `anon + slab_unreclaimable + memory.swap.current` >= 85 % von
#      (`memory.max` + `memory.swap.max`) ueber 3 aufeinanderfolgende Polls.
#   3. Der aeussere dind-Container wurde neu gestartet/recreated, waehrend
#      markierte E2E-Container laufen oder innerhalb von 60 s danach starten.
#
#   Nach einem vollstaendigen Stop gilt ein Cooldown von 600 s. Beim ersten
#   Start und nach einem Host-Reboot werden historische oom_kill-/Restart-Zaehler als
#   Baseline behandelt; der Speicherdruck-Trigger bleibt aktiv. Ist die
#   verschachtelte Docker-API nicht erreichbar, bleibt der gespeicherte Zustand
#   unveraendert, damit ein Neustart-Trigger nach dem Hochkommen des Daemons
#   erneut geprueft werden kann.
#
# AUFRUF (als root, systemd-Dienst):
#   dind-guard.sh              # Dauerbetrieb, Poll alle 10 s
#   dind-guard.sh --dry-run    # einmal messen, Ziele zeigen, nichts stoppen
#
# TUNING (Umgebungsvariablen, Defaults in Klammern):
#   DIND_CONTAINER (code-remote-dind)
#   DIND_GUARD_LABEL (com.agent-tasks.stack)
#   DIND_GUARD_POLL_INTERVAL (10), DIND_GUARD_HOLD_COUNT (3)
#   DIND_GUARD_THRESHOLD_PERCENT (85), DIND_GUARD_COOLDOWN_SECONDS (600)
#   DIND_GUARD_RESTART_GRACE_SECONDS (60)
#   DIND_GUARD_STATE_DIR (/var/lib/dind-guard)
#   DIND_GUARD_CGROUP_ROOT (/sys/fs/cgroup)
#   DIND_GUARD_DOCKER_TIMEOUT (15)
# =============================================================================

set -euo pipefail

DIND_CONTAINER="${DIND_CONTAINER:-code-remote-dind}"
GUARD_LABEL="${DIND_GUARD_LABEL:-com.agent-tasks.stack}"
POLL_INTERVAL="${DIND_GUARD_POLL_INTERVAL:-10}"
HOLD_COUNT="${DIND_GUARD_HOLD_COUNT:-3}"
THRESHOLD_PERCENT="${DIND_GUARD_THRESHOLD_PERCENT:-85}"
COOLDOWN_SECONDS="${DIND_GUARD_COOLDOWN_SECONDS:-600}"
RESTART_GRACE_SECONDS="${DIND_GUARD_RESTART_GRACE_SECONDS:-60}"
STATE_DIR="${DIND_GUARD_STATE_DIR:-/var/lib/dind-guard}"
STATE_FILE="${DIND_GUARD_STATE_FILE:-${STATE_DIR}/state}"
CGROUP_ROOT="${DIND_GUARD_CGROUP_ROOT:-/sys/fs/cgroup}"
DOCKER_TIMEOUT="${DIND_GUARD_DOCKER_TIMEOUT:-15}"
DRY_RUN=0
DIND_SOCK=""
PRESSURE_HOLD=0
STOPPED_COUNT=0

STATE_PRESENT=0
STATE_BOOT_ID=""
STATE_DIND_ID=""
STATE_DIND_STARTED=""
STATE_OOM_KILL=""
STATE_LAST_ACTION="0"
STATE_PENDING_RESTART_ID=""
STATE_PENDING_RESTART_STARTED=""
STATE_PENDING_RESTART_AT="0"

usage() {
  sed -n '2,46p' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
  esac
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

if [[ -z "$DIND_CONTAINER" || -z "$GUARD_LABEL" ]]; then
  echo "FEHLER: DIND_CONTAINER und DIND_GUARD_LABEL duerfen nicht leer sein." >&2
  exit 2
fi

for value in "$POLL_INTERVAL" "$HOLD_COUNT" "$THRESHOLD_PERCENT" \
             "$COOLDOWN_SECONDS" "$RESTART_GRACE_SECONDS" "$DOCKER_TIMEOUT"; do
  if ! is_uint "$value"; then
    echo "FEHLER: numerischer Guard-Wert ist ungueltig: $value" >&2
    exit 2
  fi
done
if (( POLL_INTERVAL < 1 || HOLD_COUNT < 1 || DOCKER_TIMEOUT < 1 )); then
  echo "FEHLER: Poll-Intervall, Hold-Count und Timeout muessen >= 1 sein." >&2
  exit 2
fi
if (( THRESHOLD_PERCENT < 1 || THRESHOLD_PERCENT > 100 )); then
  echo "FEHLER: DIND_GUARD_THRESHOLD_PERCENT muss zwischen 1 und 100 liegen." >&2
  exit 2
fi

log() {
  printf '%s dind-guard: %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  printf '%s dind-guard: WARN: %s\n' "$(date '+%F %T')" "$*" >&2
}

run_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

current_boot_id() {
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id
  elif [[ -r /proc/stat ]]; then
    awk '/^btime / { print "btime-" $2; found = 1; exit } END { if (!found) exit 1 }' /proc/stat
  else
    printf 'unbekannt'
  fi
}

read_cg_raw() {
  local file="$1" value=""
  [[ -r "$file" ]] || return 1
  IFS= read -r value < "$file" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

read_memstat() {
  local key="$1" file="$2" value=""
  [[ -r "$file" ]] || return 1
  value="$(awk -v key="$key" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "$file" 2>/dev/null)" || return 1
  is_uint "$value" || return 1
  printf '%s\n' "$value"
}

load_state() {
  [[ -r "$STATE_FILE" ]] || return 0
  STATE_PRESENT=1
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      boot_id)      STATE_BOOT_ID="$value" ;;
      dind_id)      STATE_DIND_ID="$value" ;;
      dind_started) STATE_DIND_STARTED="$value" ;;
      oom_kill)     STATE_OOM_KILL="$value" ;;
      last_action)  STATE_LAST_ACTION="$value" ;;
      pending_restart_id)      STATE_PENDING_RESTART_ID="$value" ;;
      pending_restart_started) STATE_PENDING_RESTART_STARTED="$value" ;;
      pending_restart_at)      STATE_PENDING_RESTART_AT="$value" ;;
    esac
  done < "$STATE_FILE"
}

save_state() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local tmp=""
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    warn "State-Verzeichnis ${STATE_DIR} ist nicht anlegbar; Zustand bleibt nur im Prozess."
    return 1
  fi
  if ! tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX" 2>/dev/null)"; then
    warn "temporaere State-Datei konnte nicht angelegt werden."
    return 1
  fi
  if ! {
    printf 'boot_id=%s\n' "$STATE_BOOT_ID"
    printf 'dind_id=%s\n' "$STATE_DIND_ID"
    printf 'dind_started=%s\n' "$STATE_DIND_STARTED"
    printf 'oom_kill=%s\n' "$STATE_OOM_KILL"
    printf 'last_action=%s\n' "$STATE_LAST_ACTION"
    printf 'pending_restart_id=%s\n' "$STATE_PENDING_RESTART_ID"
    printf 'pending_restart_started=%s\n' "$STATE_PENDING_RESTART_STARTED"
    printf 'pending_restart_at=%s\n' "$STATE_PENDING_RESTART_AT"
  } > "$tmp"; then
    rm -f "$tmp"
    warn "State-Datei konnte nicht geschrieben werden."
    return 1
  fi
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$STATE_FILE"; then
    rm -f "$tmp"
    warn "State-Datei konnte nicht ersetzt werden."
    return 1
  fi
  return 0
}

detect_dind_socket() {
  # Rootless nutzt /run/user/1000/docker.sock; der Fallback deckt die
  # frueher privilegierte Variante ab. Nie den Host-Socket verwenden.
  # shellcheck disable=SC2016 # $s wird absichtlich im Container ausgewertet.
  DIND_SOCK="$(run_timeout "$DOCKER_TIMEOUT" docker exec "$DIND_CONTAINER" sh -c \
    'for s in /run/user/1000/docker.sock /var/run/docker.sock; do [ -S "$s" ] && { echo "$s"; exit 0; }; done; echo /run/user/1000/docker.sock' \
    2>/dev/null | tr -d '\r' | head -n 1)" || true
  DIND_SOCK="${DIND_SOCK:-/run/user/1000/docker.sock}"
}

dind_docker() {
  run_timeout "$DOCKER_TIMEOUT" docker exec \
    -e "DOCKER_HOST=unix://${DIND_SOCK}" "$DIND_CONTAINER" docker "$@"
}

report_targets() {
  local targets="$1" cid cname
  if [[ -z "$targets" ]]; then
    log "  (keine laufenden Container mit Label ${GUARD_LABEL})"
    return 0
  fi
  while IFS='|' read -r cid cname; do
    [[ -z "$cid" ]] && continue
    log "  -> ${cname:-?} (${cid})"
  done <<< "$targets"
}

stop_targets() {
  local targets="$1" reason="$2" cid cname stopped=0
  STOPPED_COUNT=0
  log "Trigger [${reason}]: stoppe laufende Container mit Label ${GUARD_LABEL} im DinD."
  while IFS='|' read -r cid cname; do
    [[ -z "$cid" ]] && continue
    log "  stop ${cname:-?} (${cid})"
    if dind_docker stop --time 10 "$cid" >/dev/null 2>&1; then
      stopped=$((stopped + 1))
    else
      warn "  stop ${cname:-?} (${cid}) fehlgeschlagen; kein Fallback auf andere Container."
    fi
  done <<< "$targets"
  STOPPED_COUNT="$stopped"
  log "Trigger [${reason}]: ${stopped} Container gestoppt."
}

poll_once() {
  local boot_id="" inspect_out="" dind_id="" running="" started=""
  local cg="" oom_current="" anon="" slab="" swap_current=""
  local mem_max_raw="" swap_max_raw="" used="" total="" pct=""
  local targets="" target_count=0
  local baseline=0 baseline_reason=""
  local dind_changed=0
  local restart_triggered=0 state_advance=1 state_dirty=0 pressure_triggered=0
  local reason_text="" now=0 cooldown_remaining=0 restart_age=0
  local reasons=()

  STOPPED_COUNT=0
  boot_id="$(current_boot_id)"

  if ! inspect_out="$(run_timeout "$DOCKER_TIMEOUT" docker inspect \
      -f '{{.Id}}|{{.State.Running}}|{{.State.StartedAt}}' "$DIND_CONTAINER" 2>/dev/null)"; then
    PRESSURE_HOLD=0
    warn "Host-Docker kann ${DIND_CONTAINER} nicht inspizieren; Zustand bleibt unveraendert."
    return 1
  fi
  IFS='|' read -r dind_id running started <<< "$inspect_out"
  if [[ -z "$dind_id" || "$running" != "true" ]]; then
    PRESSURE_HOLD=0
    warn "${DIND_CONTAINER} laeuft nicht (running=${running:-?}); Zustand bleibt unveraendert."
    return 1
  fi

  cg="${CGROUP_ROOT}/system.slice/docker-${dind_id}.scope"
  if [[ -d "$cg" ]]; then
    oom_current="$(read_memstat oom_kill "$cg/memory.events" || true)"
    anon="$(read_memstat anon "$cg/memory.stat" || true)"
    slab="$(read_memstat slab_unreclaimable "$cg/memory.stat" || true)"
    swap_current="$(read_cg_raw "$cg/memory.swap.current" || true)"
    mem_max_raw="$(read_cg_raw "$cg/memory.max" || true)"
    swap_max_raw="$(read_cg_raw "$cg/memory.swap.max" || true)"
    if is_uint "$anon" && is_uint "$slab" && is_uint "$swap_current" \
       && is_uint "$mem_max_raw" && is_uint "$swap_max_raw"; then
      used=$((anon + slab + swap_current))
      total=$((mem_max_raw + swap_max_raw))
    fi
  else
    warn "cgroup ${cg} fehlt; Speicher-Trigger wird in diesem Poll uebersprungen."
  fi

  detect_dind_socket
  if ! dind_docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    PRESSURE_HOLD=0
    warn "Nested Docker-API (${DIND_SOCK}) nicht erreichbar; Zustand bleibt unveraendert."
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "Dry-Run Messwerte: dind=${dind_id} cgroup=${cg} oom_kill=${oom_current:-?} anon=${anon:-?} slab_unreclaimable=${slab:-?} swap.current=${swap_current:-?} max=${mem_max_raw:-?} swap.max=${swap_max_raw:-?}"
    fi
    return 1
  fi

  if ! targets="$(dind_docker ps --filter "label=${GUARD_LABEL}" \
      --filter status=running --format '{{.ID}}|{{.Names}}' 2>/dev/null)"; then
    PRESSURE_HOLD=0
    warn "Nested Docker-API (${DIND_SOCK}) konnte Container nicht auflisten; Zustand bleibt unveraendert."
    return 1
  fi
  targets="$(printf '%s\n' "$targets" | sed '/^$/d')"
  if [[ -n "$targets" ]]; then
    target_count="$(printf '%s\n' "$targets" | wc -l | tr -d ' ')"
  fi
  now="$(date +%s)"

  if [[ "$STATE_PRESENT" -eq 0 || -z "$STATE_DIND_ID" ]]; then
    baseline=1
    baseline_reason="Erstinstallation/kein Zustand"
  elif [[ -z "$STATE_BOOT_ID" || "$STATE_BOOT_ID" != "$boot_id" ]]; then
    baseline=1
    baseline_reason="Host-Reboot (Boot-ID ${STATE_BOOT_ID:-?} -> ${boot_id})"
  fi

  if [[ "$baseline" -eq 1 ]]; then
    STATE_PENDING_RESTART_ID=""
    STATE_PENDING_RESTART_STARTED=""
    STATE_PENDING_RESTART_AT="0"
    log "Baseline (${baseline_reason}): historische OOM-/Restart-Zaehler werden nicht ausgeloest; Speicherdruck bleibt aktiv."
  else
    if [[ "$dind_id" != "$STATE_DIND_ID" || "$started" != "$STATE_DIND_STARTED" ]]; then
      dind_changed=1
      log "dind-Neustart/Recreate erkannt: ${STATE_DIND_ID}@${STATE_DIND_STARTED} -> ${dind_id}@${started}"
      STATE_PENDING_RESTART_ID=""
      STATE_PENDING_RESTART_STARTED=""
      STATE_PENDING_RESTART_AT="0"
      if (( target_count > 0 )); then
        reasons+=("dind-restart")
        restart_triggered=1
      else
        STATE_PENDING_RESTART_ID="$dind_id"
        STATE_PENDING_RESTART_STARTED="$started"
        STATE_PENDING_RESTART_AT="$now"
        log "Keine laufenden Container mit Label ${GUARD_LABEL}; Restart-Trigger wartet bis zu ${RESTART_GRACE_SECONDS}s auf Start."
      fi
    elif [[ -n "$STATE_PENDING_RESTART_ID" ]]; then
      if [[ "$dind_id" == "$STATE_PENDING_RESTART_ID" \
         && "$started" == "$STATE_PENDING_RESTART_STARTED" \
         && "$STATE_PENDING_RESTART_AT" =~ ^[0-9]+$ ]]; then
        restart_age=$((now - STATE_PENDING_RESTART_AT))
        if (( target_count > 0 && restart_age <= RESTART_GRACE_SECONDS )); then
          reasons+=("dind-restart (verzoegert)")
          restart_triggered=1
        elif (( restart_age > RESTART_GRACE_SECONDS )); then
          log "Restart-Trigger abgelaufen: ${restart_age}s ohne laufende Container mit Label ${GUARD_LABEL}."
          STATE_PENDING_RESTART_ID=""
          STATE_PENDING_RESTART_STARTED=""
          STATE_PENDING_RESTART_AT="0"
        fi
      else
        STATE_PENDING_RESTART_ID=""
        STATE_PENDING_RESTART_STARTED=""
        STATE_PENDING_RESTART_AT="0"
      fi
    fi

    # oom_kill nur vergleichen, wenn derselbe cgroup-Zaehler weiterlaeuft.
    # Bei Recreate/Neustart ist der Zaehler neu; ein alter Wert waere kein
    # Ereignis. Ein Ruecksprung wird als Reset rebaselined.
    if [[ "$dind_changed" -eq 0 && -n "$oom_current" && "$STATE_OOM_KILL" =~ ^[0-9]+$ ]]; then
      if (( oom_current > STATE_OOM_KILL )); then
        log "Neuer OOM-Kill im dind-cgroup: ${STATE_OOM_KILL} -> ${oom_current}"
        if (( target_count > 0 )); then
          reasons+=("oom_kill +$((oom_current - STATE_OOM_KILL))")
        else
          log "Keine laufenden Container mit Label ${GUARD_LABEL}; kein Stop."
        fi
      elif (( oom_current < STATE_OOM_KILL )); then
        log "oom_kill-Zaehler zurueckgesetzt (${STATE_OOM_KILL} -> ${oom_current}); Baseline wird nachgezogen."
      fi
    fi
  fi

  if [[ -n "$used" && -n "$total" ]] && (( total > 0 )); then
    pct=$(( used * 100 / total ))
    if (( used * 100 >= total * THRESHOLD_PERCENT )); then
      PRESSURE_HOLD=$((PRESSURE_HOLD + 1))
    else
      PRESSURE_HOLD=0
    fi
  else
    PRESSURE_HOLD=0
  fi

  if (( PRESSURE_HOLD >= HOLD_COUNT )); then
    if (( target_count > 0 )); then
      log "Speicherdruck ${pct}% (anon+slab_unreclaimable+swap.current) seit ${PRESSURE_HOLD} Polls."
      reasons+=("memory-pressure ${pct}%")
      pressure_triggered=1
    else
      log "Speicherdruck ${pct}% seit ${PRESSURE_HOLD} Polls, aber keine Label-Container; kein Stop."
    fi
    # Nach dem Ausloesen neu zaehlen; der Cooldown schuetzt vor Wiederholung.
    PRESSURE_HOLD=0
  fi

  if [[ "$STATE_LAST_ACTION" =~ ^[0-9]+$ ]] \
     && (( now - STATE_LAST_ACTION < COOLDOWN_SECONDS )); then
    cooldown_remaining=$(( COOLDOWN_SECONDS - (now - STATE_LAST_ACTION) ))
  fi

  if (( ${#reasons[@]} > 0 )); then
    reason_text="$(printf '%s; ' "${reasons[@]}")"
    reason_text="${reason_text%; }"
    if (( cooldown_remaining > 0 )); then
      log "Trigger [${reason_text}] unterdrueckt: Cooldown noch ${cooldown_remaining}s."
      state_advance=0
      if (( pressure_triggered )); then
        PRESSURE_HOLD=$((HOLD_COUNT - 1))
      fi
      if (( restart_triggered )) && [[ -n "$STATE_PENDING_RESTART_ID" ]]; then
        # A delayed restart trigger was observed inside its 60s window. Keep
        # it pending through the current cooldown, as long as targets persist.
        STATE_PENDING_RESTART_AT="$now"
        state_dirty=1
      fi
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      log "DRY-RUN Trigger [${reason_text}]: diese Ziele wuerden gestoppt:"
    else
      stop_targets "$targets" "$reason_text"
      if (( STOPPED_COUNT > 0 && STOPPED_COUNT == target_count )); then
        STATE_LAST_ACTION="$now"
      fi
      if (( STOPPED_COUNT < target_count )); then
        state_advance=0
        if (( pressure_triggered )); then
          PRESSURE_HOLD=$((HOLD_COUNT - 1))
        fi
        if (( restart_triggered )) && [[ -n "$STATE_PENDING_RESTART_ID" ]]; then
          STATE_PENDING_RESTART_AT="$now"
          state_dirty=1
        fi
        warn "Nur ${STOPPED_COUNT}/${target_count} Container gestoppt; Trigger bleibt aktiv."
      elif (( restart_triggered )); then
        STATE_PENDING_RESTART_ID=""
        STATE_PENDING_RESTART_STARTED=""
        STATE_PENDING_RESTART_AT="0"
      fi
    fi
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-Run: kein Trigger."
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry-Run Messwerte: dind=${dind_id} cgroup=${cg} oom_kill=${oom_current:-?} anon=${anon:-?} slab_unreclaimable=${slab:-?} swap.current=${swap_current:-?} max=${mem_max_raw:-?} swap.max=${swap_max_raw:-?} used=${used:-?} total=${total:-?} pct=${pct:-?} targets=${target_count}"
    report_targets "$targets"
    log "Dry-Run: Zustand wird nicht geschrieben, es wird nichts gestoppt."
    if [[ -z "$oom_current" || -z "$used" || -z "$total" ]]; then
      warn "Dry-Run unvollstaendig: dind-cgroup-Zaehler/Limit fehlen oder sind ungueltig."
      return 1
    fi
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if (( state_advance == 1 )); then
      STATE_PRESENT=1
      STATE_BOOT_ID="$boot_id"
      STATE_DIND_ID="$dind_id"
      STATE_DIND_STARTED="$started"
      if [[ -n "$oom_current" ]]; then
        STATE_OOM_KILL="$oom_current"
      fi
    fi
    if (( state_advance == 1 || state_dirty == 1 || STOPPED_COUNT > 0 )); then
      save_state || true
    fi
  fi

  return 0
}

main() {
  log "Start: container=${DIND_CONTAINER} label=${GUARD_LABEL} poll=${POLL_INTERVAL}s hold=${HOLD_COUNT} threshold=${THRESHOLD_PERCENT}% cooldown=${COOLDOWN_SECONDS}s dry_run=${DRY_RUN}"
  load_state

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if poll_once; then
      return 0
    fi
    warn "Dry-Run-Poll fehlgeschlagen."
    return 1
  fi

  while true; do
    poll_once || warn "Poll fehlgeschlagen; naechster Versuch in ${POLL_INTERVAL}s."
    sleep "$POLL_INTERVAL"
  done
}

main
