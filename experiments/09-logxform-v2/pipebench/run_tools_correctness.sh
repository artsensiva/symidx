#!/usr/bin/env bash
# Runs PipeBench's correctness tests on Vector and Fluent Bit, with the configs PipeBench ships for them (amendment A8).
# usage: run_tools_correctness.sh HARDWARE_LABEL ROUNDS. Run from anywhere, with PipeBench at $PIPEBENCH.
# A failed test is a result: it isn't retried, and no config is changed. A run that gives no result is logged as NO RESULT.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); LABEL=$1; ROUNDS=$2
PB=${PIPEBENCH:-$HERE/../../../toolchain/pipebench/PipeBench}
OUT=${RESULTS:-$HERE/../results/$LABEL}; mkdir -p "$OUT"
HERE_TAKE=$HERE/take_result.py
cd "$PB"
CORRECT="file_rotate_create file_rotate_truncate file_truncate file_rotate_restart tcp_to_tcp_persistent tcp_to_tcp_persistent_restart tcp_to_tcp_persistent_crash disk_buffer_persistence tcp_to_http_persistent sighup wrapped_json"
{ date -Is; echo "pipebench $(git rev-parse HEAD 2>/dev/null)"; echo "symidx $(git -C "$HERE" rev-parse HEAD)"; } >> "$OUT/tools-system.txt" 2>&1
run() { # test subject round
  local t=$1 s=$2 r=$3 d="$OUT/round-$r"
  mkdir -p "$d"
  [ -s "$d/$t.$s.json" ] && return
  local before; before=$(cut -d' ' -f1-3 /proc/loadavg)
  # PipeBench keeps one file per label and subject. A label per round means a run with no result can't pick up an earlier round's.
  local hw="$LABEL-tools-r$r"
  timeout 1200 ./bin/harness test -t "$t" -s "$s" --hardware "$hw" > "$d/$t.$s.log" 2>&1
  local code=$?
  if python3 -I "$HERE_TAKE" "web/results/$hw/$s.json" "$t" "$d/$t.$s.json" "$before" >> "$d/$t.$s.log" 2>&1; then
    echo "$(date +%H:%M) tools round $r $t $s: $(grep -E "^$t " "$d/$t.$s.log" | tail -1 | tr -s ' ' | cut -c1-80)" >> "$OUT/progress.txt"
  else
    rm -f "$d/$t.$s.json"
    echo "$(date +%H:%M) tools round $r $t $s: NO RESULT, harness exit $code" >> "$OUT/progress.txt"
  fi
}
# The order rotates, as in run_formal.sh, so neither tool always runs first.
for r in $(seq 1 "$ROUNDS"); do
  for name in $CORRECT; do
    if [ $(( (r + ${#name}) % 2 )) = 0 ]; then order="vector fluent-bit"; else order="fluent-bit vector"; fi
    for s in $order; do run "${name}_correctness" "$s" "$r"; done
  done
done
echo "tools finished $(date -Is)" >> "$OUT/progress.txt"
