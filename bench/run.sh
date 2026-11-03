#!/usr/bin/env bash
# symidx benchmarks: build (time + peak RAM), image size, load, find, checksum.
#   bench/run.sh [S M L]            — corpus sizes (default: all)
#   IMPLS="goose rust-expert" ...   — which implementations (default: all three; missing ones are skipped)
#   COLD=1                          — empty the page cache before each load/find run: Linux drop_caches,
#                                     macOS purge (passwordless sudo for that command; see bench/check-machine.sh)
#   RUNS=10                         — number of hyperfine runs
#   PIN=2,3                         — run every measurement on these CPUs (Linux, taskset); builds then see
#                                     only these cores, so compare builds only between runs with the same PIN
# Writes summary.csv and env.txt (machine and toolchain) to bench/results/<timestamp>/. Linux and macOS.
# serve_*_kb: peak RSS of `find` (load + query) for the whole index ("") and for $SELECTIVE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bench/lib.sh"
SIZES=("${@:-S M L}"); SIZES=(${SIZES[*]})
IMPLS=(${IMPLS:-goose rust-idiomatic rust-expert rust-expert-batch})
RUNS=${RUNS:-10}
PREFIXES=(get_ test Model _)
SELECTIVE=Model          # the selective query for serving memory
OUT=${OUT:-"$ROOT/bench/results/$(date +%Y%m%d-%H%M%S)"}   # OUT=<dir> to choose the results directory
mkdir -p "$OUT"

bin_of() {
  case "$1" in
    goose) echo "$ROOT/goose/symidx" ;;
    rust-expert-batch) echo "$ROOT/rust-expert/target/release/symidx" ;;
    rust-*) echo "$ROOT/$1/target/release/symidx" ;;
  esac
}

# Environment for the build command: rust-expert-batch is rust-expert's first, non-streaming build.
build_env_of() {
  case "$1" in
    rust-expert-batch) echo "SYMIDX_BUILD=batch" ;;
    *) echo "SYMIDX_BUILD=default" ;;
  esac
}

PREPARE=()
if [ "${COLD:-0}" = 1 ]; then
  cold_allowed || { echo "COLD=1 needs passwordless sudo for: $(cold_prepare_cmd) (see bench/check-machine.sh)" >&2; exit 1; }
  PREPARE=(--prepare "$(cold_prepare_cmd)")
fi
setup_pin
write_env "$OUT/env.txt" "$ROOT/corpus"

# Reference checksums are computed once per corpus and cached.
ref_sum() {
  local cache="$ROOT/bench/results/ref-$1.sha256"
  [ -s "$cache" ] || python3 -I "$ROOT/bench/ref.py" "$ROOT/corpus/$1" | sha256 > "$cache"
  cat "$cache"
}

CSV="$OUT/summary.csv"
echo "impl,size,build_s,build_maxrss_kb,image_bytes,load_ms,find_ms,serve_full_kb,serve_sel_kb,checksum_ok" > "$CSV"

for size in "${SIZES[@]}"; do
  corpus="$ROOT/corpus/$size"
  [ -d "$corpus" ] || { echo "no corpus $corpus — run corpus/make.sh" >&2; exit 1; }
  ref=$(ref_sum "$size")
  echo "== $size (ref sha256 $ref)"
  for impl in "${IMPLS[@]}"; do
    bin=$(bin_of "$impl")
    [ -x "$bin" ] || { echo "  $impl: no $bin, skipping"; continue; }
    img="$OUT/$impl-$size.img"
    tag="$OUT/$impl-$size"

    benv=$(build_env_of "$impl")
    # `env` execs the binary, so the peak RSS is the binary's own.
    rss=$(peak_rss_kb "$tag.build.out" "$tag.build.time" env "$benv" "$bin" build "$corpus" -o "$img")
    # The variable goes to hyperfine, not into the timed command: an `env` wrapper adds an exec (~2 ms).
    env "$benv" ${PINPFX[@]+"${PINPFX[@]}"} hyperfine -N -w 1 -r 3 --export-json "$tag.build.json" "$bin build $corpus -o $img" > /dev/null
    imgsz=$(file_size "$img")

    pinned hyperfine -N -w 3 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$tag.load.json" "$bin load $img" > /dev/null
    finds=(); for p in "${PREFIXES[@]}"; do finds+=("$bin find $img $p"); done
    pinned hyperfine -N -w 3 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$tag.find.json" "${finds[@]}" > /dev/null

    # Serving memory: peak RSS of one process that loads and answers a full-index query, and a selective one.
    serve_full=$(peak_rss_kb /dev/null "$tag.serve.time" "$bin" find "$img" "")
    serve_sel=$(peak_rss_kb /dev/null "$tag.serve.time" "$bin" find "$img" "$SELECTIVE")

    sum=$("$bin" find "$img" "" | sha256)
    ok=$([ "$sum" = "$ref" ] && echo yes || echo NO)

    # Assigned first so that a parse failure stops the run instead of leaving an empty column.
    build_s=$(hf_mean "$tag.build.json" 1); load_ms=$(hf_mean "$tag.load.json" 1000); find_ms=$(hf_mean "$tag.find.json" 1000)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$impl" "$size" "$build_s" "$rss" "$imgsz" \
      "$load_ms" "$find_ms" "$serve_full" "$serve_sel" "$ok" | tee -a "$CSV"
  done
done

command -v column >/dev/null && column -s, -t "$CSV"
echo "results: $OUT"
