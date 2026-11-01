#!/usr/bin/env bash
# Is this machine ready for reliable benchmark numbers? Read-only: it changes nothing and runs no sudo
# command that would need a password. For each problem it prints the command to fix it, for you to run.
#   bench/check-machine.sh          — exit 0 if ready, 1 if any problem was found
#   MIN_FREE_GB=4 CPU_PCT=10 ...    — thresholds for free RAM and for a "heavy" process
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bench/lib.sh"
MIN_FREE_GB=${MIN_FREE_GB:-4}   # corpus L's page cache (~2.5 GB) plus a build (~0.5 GB) should fit
CPU_PCT=${CPU_PCT:-10}

problems=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FIX   %s\n' "$1"; shift; for c in "$@"; do printf '%s\n' "$c" | sed 's/^/          /'; done; problems=$((problems + 1)); }
info() { printf '  info  %s\n' "$1"; }

echo "== $(probe 'uname -srm'), $(probe 'nproc || sysctl -n hw.logicalcpu') logical CPUs, virtualization: $(probe virtualization)"

echo "-- CPU frequency"
if [ "$OS" = Linux ]; then
  govs=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2> /dev/null | sort -u | tr '\n' ' ')
  if [ -z "$govs" ]; then
    info "no cpufreq governor exposed (VM or container?): frequency scaling is up to the host"
  elif [ "$govs" = "performance " ]; then
    ok "governor: performance"
  else
    bad "governor: $govs(clock speed varies with load; want performance)" \
      "echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" \
      "# undo afterwards: echo powersave | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
  fi
  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" = 1 ] && ok "turbo boost: off" ||
      info "turbo boost: on (fine for relative numbers; for the steadiest clocks: echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo)"
  fi
else
  info "macOS has no governor; keep the Mac on power and avoid Low Power Mode (pmset -g | grep lowpowermode)"
fi

echo "-- power"
case "$OS" in
  Darwin) src=$(pmset -g batt 2> /dev/null | sed -n "1s/.*'\(.*\)'.*/\1/p") ;;
  *) src=$(power_linux) ;;
esac
case "$src" in
  "AC Power"|ac) ok "on mains power" ;;
  "Battery Power"|battery) bad "running on battery: CPUs may be throttled" "# plug in the power supply" ;;
  *) info "power source not reported (desktop or VM)" ;;
esac

echo "-- memory"
free_kb=$(probe ram_free_kb)
if [ "$free_kb" = unknown ]; then
  info "free RAM unknown"
elif [ "$free_kb" -lt $((MIN_FREE_GB * 1024 * 1024)) ]; then
  bad "available RAM $((free_kb / 1024)) MB < ${MIN_FREE_GB} GB: the corpus may not stay cached and warm runs turn partly cold" \
    "# close large applications, or benchmark S and M only. Largest now:" \
    "$(ps -A -o pid=,rss=,comm= 2> /dev/null | sort -k2 -nr | head -5 | awk '{printf "pid %s  %d MB  %s\n", $1, $2 / 1024, $3}')"
else
  ok "available RAM $((free_kb / 1024)) MB"
fi

echo "-- other load"
# Current CPU use from a second top sample (ps %cpu is a lifetime average and misses current load).
case "$OS" in
  Darwin) sample=$(top -l 2 -s 1 -o cpu -stats pid,cpu,command 2> /dev/null | awk '/^PID/ {n++; next} n == 2 && NF >= 3') ;;
  *) sample=$(top -b -n 2 -d 1 -w 512 2> /dev/null | awk '/^ *PID/ {n++; next} n == 2 && NF >= 12 {print $1, $9, $12}') ;;
esac
[ -n "$sample" ] || sample=$(ps -A -o pid=,pcpu=,comm= 2> /dev/null)
heavy=$(echo "$sample" | awk -v t="$CPU_PCT" '$2 + 0 >= t && $3 != "top"' | sort -k2 -nr | head -8)
load=$(probe "uptime | sed 's/.*load averages*: //'")
if [ -n "$heavy" ]; then
  bad "processes using >= ${CPU_PCT}% CPU (load average $load):" \
    "$(echo "$heavy" | awk '{printf "pid %s  %s%%  %s\n", $1, $2, $3}')" "# close them, or: kill <pid>"
else
  ok "no process above ${CPU_PCT}% CPU (load average $load)"
fi

echo "-- cold cache (COLD=1)"
case "$OS" in
  Darwin) cmd=/usr/sbin/purge ;;
  *) cmd="$(command -v tee) /proc/sys/vm/drop_caches" ;;
esac
if cold_allowed; then
  ok "passwordless sudo allowed for: $cmd"
else
  f=/etc/sudoers.d/symidx-cold-cache
  bad "no passwordless sudo for: $cmd (COLD=1 will refuse to run). To allow only that one command:" \
    "echo '$(id -un) ALL=(root) NOPASSWD: $cmd' | sudo tee $f" \
    "sudo chmod 440 $f && sudo visudo -cf $f" \
    "# undo: sudo rm $f"
fi

echo "-- profiler"
if [ "$OS" = Linux ]; then
  paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2> /dev/null || echo unknown)
  if ! command -v perf > /dev/null || ! perf --version > /dev/null 2>&1; then
    bad "perf not installed" "sudo apt install linux-tools-common linux-tools-$(uname -r)  # Debian/Ubuntu"
  elif perf stat -e task-clock true > /dev/null 2>&1; then
    ok "perf usable (perf_event_paranoid=$paranoid)"
  else
    bad "perf installed but blocked (perf_event_paranoid=$paranoid; user-space profiling needs <= 2)" \
      "sudo sysctl kernel.perf_event_paranoid=1   # until reboot" \
      "echo kernel.perf_event_paranoid=1 | sudo tee /etc/sysctl.d/99-perf.conf   # persistent"
  fi
else
  info "no perf on macOS; profile with Instruments (xcrun xctrace) or samply"
fi

echo "-- tools"
for t in hyperfine python3 git cpio; do
  command -v "$t" > /dev/null && ok "$t" || bad "$t missing" "$([ "$OS" = Darwin ] && echo "brew install $t" || echo "sudo apt install $t")"
done
if [ "$OS" = Linux ]; then
  /usr/bin/time -f %M true > /dev/null 2>&1 && ok "GNU time" || bad "GNU time (/usr/bin/time) missing" "sudo apt install time"
fi

echo
if [ "$problems" = 0 ]; then echo "ready for reliable numbers"; else echo "$problems problem(s); numbers taken now are fine for relative comparisons within one run"; fi
[ "$problems" = 0 ]
