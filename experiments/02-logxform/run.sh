#!/usr/bin/env bash
# logxform benchmark (SPEC "Metrics"): single-thread and multi-thread throughput, peak RSS, checksum.
#   experiments/02-logxform/run.sh [S M L]   — corpora (default: S M)
#   IMPLS="goose rust-arena"                 — implementations (default: all three; missing ones are skipped)
#   RUNS=10                                  — hyperfine runs per command
#   THREADS=N                                — the multi-thread count (default: logical cores, or PIN's size)
#   COLD=1                                   — empty the page cache before each timed run (as bench/run.sh)
#   PIN=2,3                                  — run every measurement on these CPUs (Linux, taskset)
#   OUT=<dir>                                — results directory (default experiments/02-logxform/results/<timestamp>/)
# Writes summary.csv and env.txt. Throughput is input MB (10^6 bytes) per second of hyperfine's mean wall
# time; RSS is the median of 3 runs. Warm: one untimed run first, plus hyperfine warm-up runs. All
# implementations share one hyperfine invocation per mode, and RSS rounds interleave them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/bench/lib.sh"
. "$ROOT/experiments/02-logxform/lib.sh"
SIZES=("${@:-S M}"); SIZES=(${SIZES[*]})
IMPLS=(${IMPLS:-$IMPLS_ALL})
RUNS=${RUNS:-10}
OUT=${OUT:-"$X/results/$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$OUT"

PREPARE=()
if [ "${COLD:-0}" = 1 ]; then
  cold_allowed || { echo "COLD=1 needs passwordless sudo for: $(cold_prepare_cmd) (see bench/check-machine.sh)" >&2; exit 1; }
  # Wrapped in sh -c: with -N, hyperfine 1.x runs --prepare without a shell too (2.x uses one).
  PREPARE=(--prepare "sh -c '$(cold_prepare_cmd)'")
  sh -c "$(cold_prepare_cmd)" || { echo "COLD=1: emptying the page cache failed: $(cold_prepare_cmd)" >&2; exit 1; }
fi
setup_pin
THREADS=${THREADS:-$(cores)}
write_env "$OUT/env.txt" "$CORPUS"
echo "threads (multi-thread runs): $THREADS" >> "$OUT/env.txt"

# hf_nth <hyperfine.json> <i>: mean wall time (s) of the i-th command of an export (hyperfine 1.x and 2.x).
hf_nth() {
  python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))["results"][int(sys.argv[2])]
m = r["summary"]["time_wall_clock"]["mean"] if "summary" in r else r["mean"]
print("%.3f" % m)' "$@"
}

CSV="$OUT/summary.csv"
echo "impl,size,input_bytes,st_s,st_mbps,threads,mt_s,mt_mbps,st_rss_kb,mt_rss_kb,checksum_ok" > "$CSV"
for size in "${SIZES[@]}"; do
  args=$(corpus_args "$size")
  bytes=$(corpus_bytes "$size")
  want=$(want_sum "$size"); summary=$(want_summary "$size")
  [ -n "$want" ] || { echo "no recorded checksum for $size in ref-checksums.txt" >&2; exit 1; }
  echo "== $size ($bytes bytes, ref sha256 $want, load $(uptime | sed 's/.*load averages*: //'))"
  impls=(); st=(); mt=()
  for impl in "${IMPLS[@]}"; do
    bin=$(bin_of "$impl")
    [ -x "$bin" ] || { echo "  $impl: no $bin, skipping"; continue; }
    impls+=("$impl"); st+=("$bin -t 1 $args"); mt+=("$bin -t $THREADS $args")
    # Checksum, and the untimed warming run.
    sum=$(pinned "$bin" -t 1 $args 2> "$OUT/$impl-$size.err" | sha256)
    [ "$sum" = "$want" ] && [ "$(cat "$OUT/$impl-$size.err")" = "$summary" ] && echo yes > "$OUT/$impl-$size.ok" || echo NO > "$OUT/$impl-$size.ok"
  done
  # All implementations in one hyperfine invocation per mode, so slow drift doesn't land on one of them.
  pinned hyperfine -N -w 1 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$OUT/$size.st.json" "${st[@]}" > /dev/null
  pinned hyperfine -N -w 1 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$OUT/$size.mt.json" "${mt[@]}" > /dev/null
  # Peak RSS: three rounds, implementations interleaved; the median per implementation.
  for round in 1 2 3; do
    for i in "${!impls[@]}"; do
      bin=$(bin_of "${impls[$i]}")
      peak_rss_kb /dev/null "$OUT/rss.time" "$bin" -t 1 $args >> "$OUT/${impls[$i]}-$size.st_rss"
      peak_rss_kb /dev/null "$OUT/rss.time" "$bin" -t "$THREADS" $args >> "$OUT/${impls[$i]}-$size.mt_rss"
    done
  done
  for i in "${!impls[@]}"; do
    impl=${impls[$i]}
    # Assigned first so that a parse failure stops the run instead of leaving an empty column.
    st_s=$(hf_nth "$OUT/$size.st.json" "$i"); mt_s=$(hf_nth "$OUT/$size.mt.json" "$i")
    st_rss=$(sort -n "$OUT/$impl-$size.st_rss" | sed -n 2p); mt_rss=$(sort -n "$OUT/$impl-$size.mt_rss" | sed -n 2p)
    st_mbps=$(awk -v b="$bytes" -v s="$st_s" 'BEGIN {printf "%.1f", b / 1e6 / s}')
    mt_mbps=$(awk -v b="$bytes" -v s="$mt_s" 'BEGIN {printf "%.1f", b / 1e6 / s}')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$impl" "$size" "$bytes" "$st_s" "$st_mbps" "$THREADS" \
      "$mt_s" "$mt_mbps" "$st_rss" "$mt_rss" "$(cat "$OUT/$impl-$size.ok")" | tee -a "$CSV"
  done
done
rm -f "$OUT/rss.time"
command -v column > /dev/null && column -s, -t "$CSV"
echo "results: $OUT"
