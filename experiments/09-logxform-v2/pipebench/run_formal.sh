#!/usr/bin/env bash
# The formal evaluation: round after round of the frozen test list, keeping every run, because PipeBench's rerun replaces a result.
# usage: run_formal.sh HARDWARE_LABEL ROUNDS [perf|correctness|all]. Run from anywhere, with PipeBench at $PIPEBENCH.
# Whole rounds go first, so stopping early still leaves complete rounds.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); LABEL=$1; ROUNDS=$2; WHAT=${3:-all}
PB=${PIPEBENCH:-$HERE/../../../toolchain/pipebench/PipeBench}
OUT=$HERE/../results/$LABEL; mkdir -p "$OUT"
cd "$PB"
PERF1="tcp_to_tcp regex_mask set_field syslog_parsing real_world_1 tcp_to_blackhole"
PERF2="tcp_to_http file_to_tcp tcp_to_tcp_persistent disk_buffer"
REAL="real_ssh_mask real_hdfs_mask real_ssh_syslog"
CORRECT="file_rotate_create file_rotate_truncate file_truncate file_rotate_restart tcp_to_tcp_persistent tcp_to_tcp_persistent_restart tcp_to_tcp_persistent_crash disk_buffer_persistence tcp_to_http_persistent sighup wrapped_json"
{
  date -Is; uname -a; lscpu | grep -E 'Model name|^CPU\(s\)|Thread'; free -g | sed -n 2p; docker --version
  echo "pipebench $(git rev-parse HEAD)"; echo "symidx $(git -C "$HERE" rev-parse HEAD)"
  for i in logxform-goose:dev logxform-rust:dev; do echo "$i $(docker image inspect --format '{{.Id}}' "$i")"; done
} > "$OUT/system.txt" 2>&1
run() { # test subject round
  local t=$1 s=$2 r=$3 d="$OUT/round-$r"
  mkdir -p "$d"
  [ -s "$d/$t.$s.json" ] && return   # a finished run isn't repeated, so this can resume
  local before; before=$(cut -d' ' -f1-3 /proc/loadavg)
  timeout 1200 ./bin/harness test -t "$t" -s "$s" --hardware "$LABEL" > "$d/$t.$s.log" 2>&1
  python3 -I "$HERE/take_result.py" "web/results/$LABEL/$s.json" "$t" "$d/$t.$s.json" "$before" >> "$d/$t.$s.log" 2>&1
  echo "$(date +%H:%M) round $r $t $s: $(grep -E "^$t " "$d/$t.$s.log" | tail -1 | tr -s ' ' | cut -c1-80)" >> "$OUT/progress.txt"
}
for r in $(seq 1 "$ROUNDS"); do
  if [ "$WHAT" != correctness ]; then
    for name in $PERF1 $REAL $PERF2; do
      for s in logxform-goose logxform-rust vector fluent-bit; do run "${name}_performance" "$s" "$r"; done
    done
  fi
  if [ "$WHAT" != perf ]; then
    for name in $CORRECT; do
      for s in logxform-goose logxform-rust; do run "${name}_correctness" "$s" "$r"; done
    done
  fi
done
echo "finished $(date -Is)" >> "$OUT/progress.txt"
