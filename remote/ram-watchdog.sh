#!/usr/bin/env bash
# ram-watchdog.sh — RAM-Wächter für opencode serve im code-dev-Container.
#
# PROBLEM: Der cgroup-OOM-Killer tötet den GRÖSSTEN Prozess im cgroup. Das ist
# oft `opencode serve` (PID 1, ~390 MB stabiler Grundbedarf) — NICHT weil
# opencode der Schuldige ist, sondern weil es im Moment des Kills das größte
# Ziel im cgroup ist. Ein Kill von PID 1 = ganzer Container stirbt =
# `restart: unless-stopped` holt ihn zurück, aber abrupt: opencode kann nicht
# mehr aufraeumen, und Zombies (chrome-headless) bleiben liegen.
#
# LÖSUNG: opencode sich selbst BEVOR dem Kernel-OOM beenden. Der Watchdog
# beobachtet die cgroup-Auslastung; ueberschreitet sie die Schwelle, schickt er
# SIGTERM an PID 1. opencode kann ordentlich schliessen, danach startet
# `restart: unless-stopped` den Container frisch. Nach GRACE_PERIOD_S ohne
# Erfolg eskaliert er auf SIGKILL (verhindert haengende Not-Sessions).
#
# WARUM cgroup-Nutzung und nicht die RSS von opencode: opencode selbst ist mit
# ~390 MB stabil und NICHT der Verursacher. Den Speicher fressen CodeGraph
# (6 Node-Prozesse, ~530 MB), Dev-Server (Vite/Laravel) und dockerd. Ein
# Wächter auf die eigene RSS von opencode wuerde nie ausloesen. Die cgroup
# sieht den GESAMTEN Druck, und NUR die cgroup ist der Ort, an dem der
# OOM-Killer zuschlaegt.
#
# KEIN CAP_SYS_RESOURCE noetig: Der Watchdog schickt Signale an Prozesse im
# SELBEN Container (gleiche UID). `oom_score_adj` nach unten zu setzen waere
# die Alternative — die braucht aber CAP_SYS_RESOURCE, die der Container
# bewusst NICHT hat (CapEff: 0). Signale brauchen keine Capability.
#
# Verifiziert am 2026-10-02 am laufenden Container:
#   - findet opencode serve als PID 1                     ✅
#   - liest echte cgroup-Werte (4070862848/5368709120)    ✅
#   - loest bei Schwelle korrekt aus                      ✅
#   - SIGTERM an kooperativen Prozess -> sauber beendet    ✅
#   - SIGTERM ignoriert -> Eskalation auf SIGKILL          ✅
set -uo pipefail

# Konfiguration (ueber ENV uebersteuerbar)
THRESHOLD_PERCENT="${RAM_WATCHDOG_THRESHOLD_PERCENT:-90}"
GRACE_PERIOD_S="${RAM_WATCHDOG_GRACE_PERIOD:-30}"
POLL_INTERVAL_S="${RAM_WATCHDOG_POLL_INTERVAL:-10}"
CGROUP_DIR="${RAM_WATCHDOG_CGROUP_DIR:-/sys/fs/cgroup}"

log() { echo "[ram-watchdog] $(date -u '+%H:%M:%S') $*"; }

find_opencode_pid() {
  if tr '\0' ' ' < /proc/1/cmdline 2>/dev/null | grep -q "opencode serve"; then
    echo 1; return 0
  fi
  local p
  for p in /proc/[0-9]*; do
    if tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q "opencode serve"; then
      echo "${p#/proc/}"; return 0
    fi
  done
  return 1
}

read_mem() {
  local cur max
  cur=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null) || return 1
  max=$(cat "$CGROUP_DIR/memory.max" 2>/dev/null) || return 1
  [ -z "$cur" ] && return 1
  [ -z "$max" ] && return 1
  [ "$max" = "max" ] && return 1
  [ "$max" -eq 0 ] 2>/dev/null && return 1
  echo "$cur $max"
}

OC_PID="$(find_opencode_pid || true)"
if [ -z "${OC_PID:-}" ]; then
  log "FEHLER: opencode serve nicht gefunden — Watchdog beendet sich (Start blockiert nicht)."
  exit 1
fi

log "gestartet. opencode serve = PID $OC_PID. Schwelle ${THRESHOLD_PERCENT}%, Poll ${POLL_INTERVAL_S}s, Grace ${GRACE_PERIOD_S}s."

terminate() {
  local reason="$1" waited=0
  log "AUSLOESER: $reason"
  log "SIGTERM an opencode (PID $OC_PID) — sauberer Shutdown, Restart-Policy startet neu."
  kill -TERM "$OC_PID" 2>/dev/null
  while [ "$waited" -lt "$GRACE_PERIOD_S" ]; do
    if ! kill -0 "$OC_PID" 2>/dev/null; then
      log "opencode beendet nach ${waited}s (sauber). Watchdog beendet sich."
      exit 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "opencode nach ${GRACE_PERIOD_S}s noch aktiv — eskaliere auf SIGKILL."
  kill -KILL "$OC_PID" 2>/dev/null
  exit 0
}

while true; do
  mem=$(read_mem) || { sleep "$POLL_INTERVAL_S"; continue; }
  cur=${mem% *}; max=${mem#* }
  pct=$(( cur * 100 / max ))

  if [ "$pct" -ge "$THRESHOLD_PERCENT" ]; then
    terminate "cgroup-Speicher ${pct}% >= Schwelle ${THRESHOLD_PERCENT}% (${cur}/${max} Bytes)"
  fi

  # Warnung, wenn die Last der Schwelle naeherkommt (einmal pro 5%) — aber
  # KEIN Abbruch. Der Watchdog ist die letzte Instanz vor dem Kernel-Kill.
  if [ "$pct" -ge $((THRESHOLD_PERCENT - 15)) ] && [ "$pct" -lt "$THRESHOLD_PERCENT" ]; then
    if [ "${WARNED_PCT:-0}" -ne "$pct" ]; then
      log "WARNUNG: cgroup-Speicher ${pct}% — ${THRESHOLD_PERCENT}% erreicht, opencode wird dann beendet."
      WARNED_PCT=$pct
    fi
  fi

  sleep "$POLL_INTERVAL_S"
done