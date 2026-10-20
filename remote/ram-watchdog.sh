#!/usr/bin/env bash
# ram-watchdog.sh — RAM-Wächter für opencode serve im code-dev-Container.
#
# GRUNDSATZ (2026-10-20): Der Wächter schützt den HOST, nicht den Container.
#
# WARUM DER UMBAU (Vorfall vom 2026-10-20, 16:05–16:08 CEST):
# Die alte Fassung beobachtete `memory.current` der cgroup und schickte bei
# 90 % SIGTERM an opencode (PID 1). `memory.current` ist die richtige Größe
# für den cgroup-Deckel — der Fehler lag woanders: **der cgroup-Deckel (7 GiB)
# ist mehr als der nutzbare Host-RAM (7,47 GiB), und code-dev hat noch dind
# (1g), den Portal-Stack (~0,9g) und OS/dockerd (~0,7g) daneben.** Als der
# Wächter bei 90 % von 7 GiB = 6,3 GiB auslöste, war der Host bereits bei
# 783 MB MemAvailable und 6,3 GB Swap — er stand am Abgrund. Die „Rettung"
# rettete den Container und trotzdem nicht den Host: 2 min 44 s Totalausfall
# (rsyslog stumm, dockerd konnte keine Health-Checks mehr forken), dann ein
# harter Reset.
#
# Am 20.10. hat der alte Wächter **drei Mal** ausgelöst (13:17, 16:05, 17:19
# CEST) — jedes Mal SIGTERM an PID 1, jedes Mal eine gerissene Sitzung.
#
# NEU: zwei Trigger, zwei sehr verschiedene Reaktionen.
#
#   A) CONTAINER-Trigger: `anon + slab_unreclaimable` >= THRESHOLD_PERCENT %
#      von `memory.max`. Das ist der Teil der cgroup, den der Kernel NICHT
#      reclaimen kann — Page-Cache kann er, anon nicht.
#      Reaktion: SIGTERM an opencode (PID 1), nach GRACE_PERIOD_S SIGKILL.
#      Zweck: verhindert, dass der Kernel-OOM-Killer im cgroup opencode abrupt
#      killt. Der Kernel nimmt immer den GRÖSSTEN Prozess im cgroup — das ist
#      opencode (PID 1) — und ein Kill von PID 1 = ganzer Container stirbt =
#      `restart: unless-stopped` = Session weg, OHNE sauberen Shutdown. Der
#      Wächter macht daraus einen geordneten Shutdown.
#
#   B) HOST-Trigger: `MemAvailable` des HOSTS unter HOST_MIN_AVAILABLE_MB.
#      `/proc/meminfo` im Container zeigt die HOST-Werte (kein Namespacing auf
#      diesem Weg — verifiziert 2026-10-20: MemTotal 7832632 kB, identisch
#      mit dem Host).
#      Reaktion: Eskalationsleiter, von harmlos nach teuer:
#        B1) Loggen mit allen Zahlen (Host-RAM, Host-Swap, cgroup anon/file).
#        B2) Speicherfresser-KINDER beenden — nach **anon** sortiert, die
#            grössten zuerst, bis die Zielsumme erreicht ist. Die Session
#            bleibt, nur die Werkzeuge sind weg.
#        B3) opencode (PID 1) beenden → Container startet neu. Die Session ist
#            weg, der HOST LEBT. „Host soll immer leben, notfalls der
#            Container."
#
#   ZWEI BEDINGUNGEN, DIE B3 UNVERBINDLICH MACHEN (beide aus dem Review am
#   2026-10-20, beide live belegt):
#
#   1) **Der Container muss schuld sein.** B3 wird nur ausgelöst, wenn
#      code-dev auch nennenswert am Host-Druck beteiligt ist
#      (CONTAINER_SHARE_MIN_PCT). Ist der Druck fremd (dind, Portal-Stack,
#      dockerd), hilft ein Container-Neustart nichts — er würde nur die
#      Sitzung vernichten und die Schleife fortsetzen: Container startet →
#      Druck besteht weiter → B3 → Container startet → … **eine Sitzung pro
#      Zyklus.** Mit dieser Bedingung kann die Schleife nicht entstehen.
#   2) **Der Druck muss anhalten** (HOLD_COUNT aufeinanderfolgende Messungen)
#      und der Wächter fasst die ersten STARTUP_GRACE_S nach einem
#      Container-Neustart nicht an (die Strikes werden dabei zurückgesetzt).
#
#   Der Host-Swap ist **Warnung, nicht Eskalation.** Mit swappiness=60 und
#   9 GiB Swap-Deckel für code-dev ist ein Swap-Füllstand von mehreren GB der
#   NORMALZUSTAND jeder Lastspitze (live am 20.10.: 6,3 GB Swap bei
#   MemAvailable 783 MB — der einzige Trigger, der im Incident überhaupt
#   anschlagen wäre). Er wird protokolliert, löst aber nichts aus; die
#   Eskalation hängt allein an MemAvailable.
#
# KEIN CAP_SYS_RESOURCE nötig: Der Watchdog schickt Signale an Prozesse im
# SELBEN Container (gleiche UID). `oom_score_adj` nach unten zu setzen wäre
# die Alternative — die braucht aber CAP_SYS_RESOURCE, die der Container
# bewusst NICHT hat (CapEff: 0). Signale brauchen keine Capability.
#
# Verifiziert am 2026-10-02 am laufenden Container:
#   - findet opencode serve als PID 1                     ✅
#   - liest echte cgroup-Werte (4070862848/5368709120)    ✅
#   - löst bei Schwelle korrekt aus                      ✅
#   - SIGTERM an kooperativen Prozess -> sauber beendet    ✅
#   - SIGTERM ignoriert -> Eskalation auf SIGKILL          ✅
# Verifiziert am 2026-10-20 (Umbau) ausschliesslich gegen DUMMY-Prozesse in
# einem Wegwerf-Container, NIE gegen das echte PID 1 — dort ist PID 1 ein
# `sleep` mit gefaelschtem argv[0]. Belegt: Container-Trigger, Host-Trigger
# mit Eskalationsleiter, HOLD_COUNT, Startup-Grace, Greedy-Auswahl nach anon.
set -uo pipefail

# Konfiguration (ueber ENV uebersteuerbar)
# THRESHOLD_PERCENT gilt auf anon+slab_unreclaimable. 85 % lassen mehr Luft,
# weil `anon` nicht reclaimbar ist — der Kernel würde bei 100 % hart killen.
THRESHOLD_PERCENT="${RAM_WATCHDOG_THRESHOLD_PERCENT:-85}"
# HOST_MIN_AVAILABLE_MB: Host-RAM, das frei bleiben MUSS, damit der Host
# nicht in die Swap-Thrash und dann in den Haenger laeuft.
# Herleitung (2026-10-20, live belegt): im Incident stand der Host bei
# 783 MB MemAvailable, waehrend code-dev 6,67 GB resident hielt. Die Schwelle
# muss DIESEN Zustand noch erfassen, sonst greift sie im dokumentierten
# Vorfall nicht. 1000 MB liegt darunter, aber deutlich ueber dem
# Normalbetrieb (live nach dem Neustart: 5,4 GiB verfuegbar). Ein
# `cargo build` mit 3 x rustc a 920 MB kostet rund 2,8 GB — der bleibt
# oberhalb der Schwelle.
HOST_MIN_AVAILABLE_MB="${RAM_WATCHDOG_HOST_AVAILABLE_MB:-1000}"
# CONTAINER_SHARE_MIN_PCT: B3 nur, wenn code-dev mindestens diesen Anteil
# am Host-Speicherverbrauch haelt. Bei Fremddruck (dind, Portal-Stack) ist
# code-dev nicht der Verursacher — dann hilft nur ein Neustart des
# Containers nichts, und der waere zudem eine Sitzung pro Zyklus.
CONTAINER_SHARE_MIN_PCT="${RAM_WATCHDOG_CONTAINER_SHARE_MIN_PCT:-50}"
# HOST_MAX_SWAP_PERCENT: Anteil des Swapfiles, der als "Host arbeitet im
# Notbetrieb" gilt. WARNUNG, keine Eskalation — siehe Kopf.
HOST_MAX_SWAP_PERCENT="${RAM_WATCHDOG_HOST_MAX_SWAP_PERCENT:-80}"
# HOLD_COUNT: so viele aufeinanderfolgende Messungen muessen den Druck
# zeigen, bevor gehandelt wird.
HOLD_COUNT="${RAM_WATCHDOG_HOST_HOLD_COUNT:-3}"
# STARTUP_GRACE_S: die ersten Sekunden nach Container-Start fasst der
# Wächter nicht an — und die Strikes werden dabei zurückgesetzt, damit sie
# sich nicht über die Grace-Fensterzeit hinweg aufsummieren.
STARTUP_GRACE_S="${RAM_WATCHDOG_STARTUP_GRACE_S:-180}"
# RSS-SUMME (anon), die mit den Kindern freigemacht werden soll (Stufe B2).
CHILD_RSS_MB="${RAM_WATCHDOG_CHILD_RSS_MB:-300}"
# Prozesse unterhalb dieses anon-Werts werden nicht angefasst (B2).
CHILD_MIN_RSS_MB="${RAM_WATCHDOG_CHILD_MIN_RSS_MB:-20}"
# Höchstzahl Prozesse, die B2 beendet (B2).
CHILD_MAX_COUNT="${RAM_WATCHDOG_CHILD_MAX_COUNT:-8}"
# Wartezeit zwischen TERM und KILL für die Kinder (Stufe B2).
CHILD_GRACE_S="${RAM_WATCHDOG_CHILD_GRACE_S:-15}"
GRACE_PERIOD_S="${RAM_WATCHDOG_GRACE_PERIOD:-30}"
POLL_INTERVAL_S="${RAM_WATCHDOG_POLL_INTERVAL:-10}"
CGROUP_DIR="${RAM_WATCHDOG_CGROUP_DIR:-/sys/fs/cgroup}"
# Wie lange auf opencode serve gewartet wird, bevor der Wächter aufgibt
# (entrypoint.sh startet den Wächter, bevor es opencode exec't).
STARTUP_WAIT_S="${RAM_WATCHDOG_STARTUP_WAIT_S:-30}"

# Prozesse, die als Speicherfresser-Kinder in Frage kommen (Stufe B2).
# Matcht auf den Basisnamen des Executables. `node` steht bewusst mit
# drin: ueber npm installierte Dev-Server (vite/next) laufen als `node`,
# nicht als `vite`/`next` — sonst wuerde ein `pnpm dev` nie erfasst.
CHILD_EXE_MATCH="rustc cargo vite next nuxt webpack esbuild tsc javac mvn gradle bun deno node"
# cmdline-Marker fuer die CodeGraph-MCP-Server: das Executable ist `node`,
# der Pfad und das Flag verraten es. Am 2026-10-20 waren das 4 Server mit
# 90–126 MB RSS plus 4 Bridges mit 53 MB, zusammen ~650 MB RSS / 294 MB anon.
CHILD_CMD_PATH="/opt/codegraph/"
CHILD_CMD_FLAG="--liftoff-only"

log() { echo "[ram-watchdog] $(date -u '+%H:%M:%S') $*"; }

find_opencode_pid() {
  if tr '\0\n' '  ' < /proc/1/cmdline 2>/dev/null | grep -q "opencode serve"; then
    echo 1; return 0
  fi
  local p
  for p in /proc/[0-9]*; do
    if tr '\0\n' '  ' < "$p/cmdline" 2>/dev/null | grep -q "opencode serve"; then
      echo "${p#/proc/}"; return 0
    fi
  done
  return 1
}

# Host-RAM in kB: "total available"
# Achtung: im Container sind das die HOST-Werte (nicht namespaced).
read_host_mem() {
  local total avail
  total=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  avail=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  if [ -z "$total" ] || [ -z "$avail" ]; then return 1; fi
  echo "$total $avail"
}

# Host-Swap: "total used" in kB
read_swap_mem() {
  local total free
  total=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  free=$(awk '/^SwapFree:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  if [ -z "$total" ] || [ -z "$free" ]; then return 1; fi
  echo "$total $(( total - free ))"
}

# cgroup-Speicher in Bytes: "anon+slab_unreclaimable max"
# `anon` ist der Teil, den der Kernel NICHT reclaimen kann — nur der zählt
# für die OOM-Frage. `file` (Page-Cache) wird bewusst NICHT mitgezählt.
read_cgroup_mem() {
  local stat="$CGROUP_DIR/memory.stat" max anon slab
  max=$(cat "$CGROUP_DIR/memory.max" 2>/dev/null) || return 1
  if [ -z "$max" ] || [ "$max" = "max" ]; then return 1; fi
  anon=$(awk '$1=="anon"{print $2; exit}' "$stat" 2>/dev/null)
  slab=$(awk '$1=="slab_unreclaimable"{print $2; exit}' "$stat" 2>/dev/null)
  [ -n "$anon" ] || anon=0
  [ -n "$slab" ] || slab=0
  echo "$((anon + slab)) $max"
}

# residenter Speicher des cgroups (Bytes) — RAM-Anteil, unabhaengig vom Cache
read_cgroup_current() {
  cat "$CGROUP_DIR/memory.current" 2>/dev/null
}

# page cache im cgroup (nur fürs Logging)
read_cgroup_file() {
  awk '$1=="file"{print $2; exit}' "$CGROUP_DIR/memory.stat" 2>/dev/null
}

# anon-Anteil eines Prozesses in kB (Private_Dirty aus smaps_rollup).
# Wichtig: nach ANON sortieren, nicht nach RSS. Die CodeGraph-Server haben
# 660 MB RSS bei nur 294 MB anon — der Rest ist mmap'd SQLite-Index und
# Node-Binary, also reclaimbarer Page-Cache. Nach RSS zu sortieren wuerde
# genau die falschen Prozesse treffen und den echten Verbraucher (PID 1)
# stehen lassen.
read_proc_anon_kb() {
  local pid="$1" v
  v=$(awk '/^Private_Dirty:/{print $2; exit}' "/proc/$pid/smaps_rollup" 2>/dev/null)
  if [ -z "$v" ]; then
    v=$(awk '/^VmRSS:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
  fi
  echo "${v:-0}"
}

# Zustand eines Prozesses: Z = Zombie. Ein Zombie haelt keinen Speicher,
# ist aber mit "kill -0" nicht von einem lebenden Prozess zu unterscheiden.
proc_is_zombie() {
  local st
  st=$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)
  [ "$st" = "Z" ]
}

# Alle Speicherfresser-Kinder sammeln: "pid|anon_kB|rss_kB|exe|cmdline-auszug"
collect_children() {
  local p pid cmd rss exe anon
  for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    [ "$pid" = "1" ] && continue              # opencode = PID 1, gehört Stufe B3
    [ "$pid" = "$$" ] && continue             # der Wächter selbst
    cmd=$(tr '\0\n' '  ' < "$p/cmdline" 2>/dev/null)
    [ -n "$cmd" ] || continue
    exe=$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | head -1)
    exe="${exe##*/}"
    rss=$(awk '/^VmRSS:/{print $2; exit}' "$p/status" 2>/dev/null)
    if [[ " $CHILD_EXE_MATCH " == *" $exe "* ]]; then
      anon=$(read_proc_anon_kb "$pid")
      echo "$pid|${anon:-0}|${rss:-0}|$exe|${cmd:0:60}"
      continue
    fi
    case "$cmd" in
      *"$CHILD_CMD_PATH"*) anon=$(read_proc_anon_kb "$pid")
                         echo "$pid|${anon:-0}|${rss:-0}|$exe|${cmd:0:60}" ;;
      *"$CHILD_CMD_FLAG"*) anon=$(read_proc_anon_kb "$pid")
                         echo "$pid|${anon:-0}|${rss:-0}|$exe|${cmd:0:60}" ;;
    esac
  done
}

# Stufe B2: die GROSSTEN Kinder zuerst beenden, bis die Zielsumme erreicht
# ist. Sortiert nach ANON (siehe read_proc_anon_kb). Nicht alle: 100 × 3 MB
# wären genau 300 MB und alle wuerden sterben, 99 × 3 MB wuerden keinen
# treffen. Mit "groesste zuerst, bis Zielsumme" ist beides vernuenftig.
free_children() {
  local children sum=0 pid anon rss exe cmd
  children=$(collect_children)
  if [ -z "$children" ]; then
    log "B2: keine Speicherfresser-Kinder im Container — nichts zu tun."
    return 1
  fi

  while IFS='|' read -r pid anon _ _ _; do
    [ -n "$pid" ] || continue
    sum=$(( sum + ${anon:-0} ))
  done <<< "$children"

  local sum_mb=$(( sum / 1024 ))
  if [ "$sum_mb" -lt "$CHILD_RSS_MB" ]; then
    log "B2: Speicherfresser-Kinder nur ${sum_mb} MB anon — unter ${CHILD_RSS_MB} MB, kein Eingriff."
    return 1
  fi

  local target=$(( CHILD_RSS_MB * 1024 ))
  local min_anon=$(( CHILD_MIN_RSS_MB * 1024 ))
  local max_count="${CHILD_MAX_COUNT:-8}"
  local freed=0 count=0 selected=""

  log "B2: ${sum_mb} MB anon in Speicherfresser-Kindern — beende die grössten (Ziel ${CHILD_RSS_MB} MB, max ${max_count} Prozesse). Session bleibt, Werkzeuge gehen."
  while IFS='|' read -r pid anon rss exe cmd; do
    [ -n "$pid" ] || continue
    [ "$freed" -ge "$target" ] && break
    [ "$count" -ge "$max_count" ] && break
    [ "${anon:-0}" -lt "$min_anon" ] && continue
    log "B2: TERM an PID ${pid} (${anon} kB anon, ${rss} kB RSS, ${exe}) — ${cmd}"
    kill -TERM "$pid" 2>/dev/null
    selected="$selected $pid"
    freed=$(( freed + ${anon:-0} ))
    count=$(( count + 1 ))
  done <<< "$(printf '%s\n' "$children" | sort -t'|' -k2 -n -r)"

  [ "$count" -eq 0 ] && { log "B2: kein Kind ueber ${CHILD_MIN_RSS_MB} MB anon — kein Eingriff."; return 1; }

  # Grace und KILL gelten NUR den tatsaechlich ausgewaehlten PIDs. Ein KILL
  # ueber die ganze Liste wuerde die Auswahl (groesste zuerst, bis Zielsumme)
  # wieder aufheben und am Ende doch alle Kinder treffen.
  local waited=0
  while [ "$waited" -lt "$CHILD_GRACE_S" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    local still=0
    for pid in $selected; do
      if kill -0 "$pid" 2>/dev/null && ! proc_is_zombie "$pid"; then still=1; break; fi
    done
    [ "$still" -eq 0 ] && break
  done

  for pid in $selected; do
    if kill -0 "$pid" 2>/dev/null && ! proc_is_zombie "$pid"; then
      log "B2: PID ${pid} lebt noch — KILL."
      kill -KILL "$pid" 2>/dev/null
    fi
  done

  return 0
}

# opencode serve kann noch nicht laufen: entrypoint.sh startet den Wächter,
# exec't opencode aber erst weiter unten. Also warten statt sich zu beenden
# (der Wächter ist tragend für "Host lebt").
OC_PID=""
for _ in $(seq 1 "$STARTUP_WAIT_S"); do
  OC_PID="$(find_opencode_pid || true)"
  [ -n "${OC_PID:-}" ] && break
  sleep 1
done
if [ -z "${OC_PID:-}" ]; then
  log "FEHLER: opencode serve nach ${STARTUP_WAIT_S}s nicht gefunden — Watchdog beendet sich (Start blockiert nicht)."
  exit 1
fi
# Nur PID 1 wird beendet. Ein opencode als Kindprozess (z. B. `opencode
# serve --service`) zu SIGTERM'en und sich danach zu beenden wuerde den
# Container OHNE Wächter weiterlaufen lassen — genau den Schutz, den die
# Eskalation liefern soll.
if [ "$OC_PID" != "1" ]; then
  log "FEHLER: opencode serve laeuft als PID ${OC_PID}, nicht als PID 1 — Watchdog beendet sich (er darf nur PID 1 beenden)."
  exit 1
fi

log "gestartet. opencode serve = PID ${OC_PID}. anon-Schwelle ${THRESHOLD_PERCENT}%, Host-Mindest-RAM ${HOST_MIN_AVAILABLE_MB} MB, Container-Anteil >= ${CONTAINER_SHARE_MIN_PCT}%, Poll ${POLL_INTERVAL_S}s, Grace ${GRACE_PERIOD_S}s."

# Stufe B3: opencode beenden. Der Container startet neu (restart: unless-stopped),
# die Session ist weg — der Host lebt.
terminate() {
  local reason="$1" waited=0
  log "AUSLOESER: $reason"
  log "SIGTERM an opencode (PID ${OC_PID}) — sauberer Shutdown, Restart-Policy startet neu."
  kill -TERM "$OC_PID" 2>/dev/null
  while [ "$waited" -lt "$GRACE_PERIOD_S" ]; do
    if ! kill -0 "$OC_PID" 2>/dev/null; then
      log "opencode beendet nach ${waited}s (sauber). Watchdog beendet sich."
      exit 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  log "opencode nach ${GRACE_PERIOD_S}s noch aktiv — eskaliere auf SIGKILL."
  kill -KILL "$OC_PID" 2>/dev/null
  exit 0
}

WARNED_ANON_PCT=0
HOST_STRIKES=0
HOST_TRIGGER_WARNED=0
SWAP_WARNED=0

while true; do
  # ---- Trigger B: Host-Druck ----------------------------------------------------
  host_mem=$(read_host_mem || true)
  swap_mem=$(read_swap_mem || true)
  if [ -z "${host_mem:-}" ]; then
    if [ "$HOST_TRIGGER_WARNED" -eq 0 ]; then
      log "WARNUNG: /proc/meminfo unbrauchbar — der Host-Trigger (B) ist deaktiviert, es wirkt nur der Container-Trigger (A)."
      HOST_TRIGGER_WARNED=1
    fi
  else
    h_total=${host_mem% *}
    h_avail=${host_mem#* }
    h_avail_mb=$(( h_avail / 1024 ))
    h_used_kb=$(( h_total - h_avail ))
    cg_file=$(read_cgroup_file || echo 0)

    # Swap = WARNUNG, nicht Eskalation (siehe Kopf).
    if [ -n "${swap_mem:-}" ]; then
      s_total=${swap_mem% *}
      s_used=${swap_mem#* }
      s_pct=0
      [ "$s_total" -gt 0 ] && s_pct=$(( s_used * 100 / s_total ))
      if [ "$s_pct" -ge "$HOST_MAX_SWAP_PERCENT" ] && [ "$SWAP_WARNED" -eq 0 ]; then
        log "WARNUNG: Host-Swap ${s_pct}% belegt ($(( s_used / 1024 )) MB von $(( s_total / 1024 )) MB) — der Host arbeitet im Notbetrieb. Das ist KEIN Eskalationsgrund."
        SWAP_WARNED=1
      elif [ "$s_pct" -lt "$HOST_MAX_SWAP_PERCENT" ]; then
        SWAP_WARNED=0
      fi
    fi

    if [ "$h_avail_mb" -lt "$HOST_MIN_AVAILABLE_MB" ]; then
      HOST_STRIKES=$(( HOST_STRIKES + 1 ))

      if [ "$HOST_STRIKES" -lt "$HOLD_COUNT" ]; then
        log "HOST-DRUCK (${HOST_STRIKES}/${HOLD_COUNT}): MemAvailable ${h_avail_mb} MB < ${HOST_MIN_AVAILABLE_MB} MB — noch kein Eingriff, der Druck muss anhalten."
      elif [ "$SECONDS" -lt "$STARTUP_GRACE_S" ]; then
        log "HOST-DRUCK, aber erst ${SECONDS}s nach Container-Start (< ${STARTUP_GRACE_S}s) — keine Eskalation (Schutz gegen Neustart-Schleife)."
        HOST_STRIKES=0
      else
        log "HOST-DRUCK (${HOST_STRIKES}/${HOLD_COUNT}): MemAvailable ${h_avail_mb} MB < ${HOST_MIN_AVAILABLE_MB} MB (MemTotal $(( h_total / 1024 )) MB, cgroup file $(( ${cg_file:-0} / 1048576 )) MB)."

        # B2 zuerst: billiger als ein Container-Neustart, und die Session bleibt.
        free_children || true
        sleep 2

        host_mem=$(read_host_mem || true)
        if [ -n "${host_mem:-}" ]; then
          h_total=${host_mem% *}
          h_avail=${host_mem#* }
          h_avail_mb=$(( h_avail / 1024 ))
          h_used_kb=$(( h_total - h_avail ))
        fi

        if [ "$h_avail_mb" -lt "$HOST_MIN_AVAILABLE_MB" ]; then
          # B3 nur, wenn code-dev auch schuld ist. Bei Fremddruck hilft der
          # Container-Neustart nichts — er wuerde nur die Sitzung vernichten
          # und die Schleife fortsetzen (eine Sitzung pro Zyklus).
          cg_cur=$(read_cgroup_current || echo 0)
          share=0
          [ "$h_used_kb" -gt 0 ] && share=$(( cg_cur * 100 / (h_used_kb * 1024) ))
          if [ "$share" -lt "$CONTAINER_SHARE_MIN_PCT" ]; then
            log "HOST-DRUCK unveraendert (MemAvailable ${h_avail_mb} MB), aber code-dev haelt nur ${share}% des Host-Verbrauchs (< ${CONTAINER_SHARE_MIN_PCT}%) — der Druck kommt von ausserhalb. PID 1 zu opfern wuerde nichts freimachen und nur die Sitzung vernichten. Kein Eingriff."
            HOST_STRIKES=0
          else
            terminate "HOST-DRUCK unveraendert: MemAvailable ${h_avail_mb} MB < ${HOST_MIN_AVAILABLE_MB} MB, code-dev haelt ${share}% des Host-Verbrauchs. Host schuetzen, Container opfern."
          fi
        else
          log "HOST-DRUCK entlastet: MemAvailable jetzt ${h_avail_mb} MB."
          HOST_STRIKES=0
        fi
      fi
    else
      [ "$HOST_STRIKES" -gt 0 ] && log "HOST-DRUCK ueberstanden (${HOST_STRIKES} Messungen) — kein Eingriff."
      HOST_STRIKES=0
    fi
  fi

  # ---- Trigger A: cgroup-Druck (nur anon, nie der Page-Cache) -------------------
  cg=$(read_cgroup_mem || true)
  if [ -n "${cg:-}" ]; then
    cg_used=${cg% *}
    cg_max=${cg#* }
    pct=$(( cg_used * 100 / cg_max ))

    if [ "$pct" -ge "$THRESHOLD_PERCENT" ]; then
      terminate "cgroup-anon ${pct}% >= Schwelle ${THRESHOLD_PERCENT}% (${cg_used}/${cg_max} Bytes, ohne Page-Cache)"
    fi

    # Warnung, wenn die Last der Schwelle naeherkommt (einmal pro 5%) — aber
    # KEIN Abbruch. Der Watchdog ist die letzte Instanz vor dem Kernel-Kill.
    if [ "$pct" -ge $(( THRESHOLD_PERCENT - 15 )) ] && [ "$pct" -lt "$THRESHOLD_PERCENT" ]; then
      if [ "${WARNED_ANON_PCT:-0}" -ne "$pct" ]; then
        log "WARNUNG: cgroup-anon ${pct}% — ${THRESHOLD_PERCENT}% erreicht, opencode wird dann beendet."
        WARNED_ANON_PCT=$pct
      fi
    fi
  fi

  sleep "$POLL_INTERVAL_S"
done
