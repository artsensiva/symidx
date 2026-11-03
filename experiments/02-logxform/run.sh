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
# time; RSS is the median of 3 runs. Warm: one untimed run first, plus hyperfine warm-up runs.
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

# median3 <cmd...>: median peak RSS (KiB) of three runs, stdout and stderr discarded.
median3() {
  local a b c
  a=$(peak_rss_kb /dev/null "$OUT/rss.time" "$@"); b=$(peak_rss_kb /dev/null "$OUT/rss.time" "$@")
  c=$(peak_rss_kb /dev/null "$OUT/rss.time" "$@")
  printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -n | sed -n 2p
}

CSV="$OUT/summary.csv"
echo "impl,size,input_bytes,st_s,st_mbps,threads,mt_s,mt_mbps,st_rss_kb,mt_rss_kb,checksum_ok" > "$CSV"
for size in "${SIZES[@]}"; do
  args=$(corpus_args "$size")
  bytes=$(corpus_bytes "$size")
  want=$(want_sum "$size"); summary=$(want_summary "$size")
  [ -n "$want" ] || { echo "no recorded checksum for $size in ref-checksums.txt" >&2; exit 1; }
  echo "== $size ($bytes bytes, ref sha256 $want)"
  for impl in "${IMPLS[@]}"; do
    bin=$(bin_of "$impl")
    [ -x "$bin" ] || { echo "  $impl: no $bin, skipping"; continue; }
    tag="$OUT/$impl-$size"
    # Checksum, and the untimed warming run.
    sum=$(pinned "$bin" -t 1 $args 2> "$tag.err" | sha256)
    ok=$([ "$sum" = "$want" ] && [ "$(cat "$tag.err")" = "$summary" ] && echo yes || echo NO)
    pinned hyperfine -N -w 1 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$tag.st.json" "$bin -t 1 $args" > /dev/null
    pinned hyperfine -N -w 1 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$tag.mt.json" "$bin -t $THREADS $args" > /dev/null
    st_rss=$(median3 "$bin" -t 1 $args)
    mt_rss=$(median3 "$bin" -t "$THREADS" $args)
    # Assigned first so that a parse failure stops the run instead of leaving an empty column.
    st_s=$(hf_mean "$tag.st.json" 1); mt_s=$(hf_mean "$tag.mt.json" 1)
    st_mbps=$(awk -v b="$bytes" -v s="$st_s" 'BEGIN {printf "%.1f", b / 1e6 / s}')
    mt_mbps=$(awk -v b="$bytes" -v s="$mt_s" 'BEGIN {printf "%.1f", b / 1e6 / s}')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$impl" "$size" "$bytes" "$st_s" "$st_mbps" "$THREADS" \
      "$mt_s" "$mt_mbps" "$st_rss" "$mt_rss" "$ok" | tee -a "$CSV"
  done
done
rm -f "$OUT/rss.time"
command -v column > /dev/null && column -s, -t "$CSV"
echo "results: $OUT"
