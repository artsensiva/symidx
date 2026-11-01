#!/usr/bin/env bash
# symidx benchmarks: build (time + peak RAM), image size, load, find, checksum.
#   bench/run.sh [S M L]            — corpus sizes (default: all)
#   IMPLS="goose rust-expert" ...   — which implementations (default: all three; missing ones are skipped)
#   COLD=1                          — drop the page cache before load/find (needs passwordless sudo)
#   RUNS=10                         — number of hyperfine runs
# serve_*_kb: peak RSS of `find` (load + query) for the whole index ("") and for $SELECTIVE.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZES=("${@:-S M L}"); SIZES=(${SIZES[*]})
IMPLS=(${IMPLS:-goose rust-idiomatic rust-expert rust-expert-batch})
RUNS=${RUNS:-10}
PREFIXES=(get_ test Model _)
SELECTIVE=Model          # the selective query for serving memory
OUT="$ROOT/bench/results/$(date +%Y%m%d-%H%M%S)"
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
  sudo -n true || { echo "COLD=1 requires passwordless sudo" >&2; exit 1; }
  PREPARE=(--prepare 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null')
fi

# Reference checksums are computed once per corpus and cached.
ref_sum() {
  local cache="$ROOT/bench/results/ref-$1.sha256"
  [ -s "$cache" ] || python3 -I "$ROOT/bench/ref.py" "$ROOT/corpus/$1" | sha256sum | cut -d' ' -f1 > "$cache"
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
    /usr/bin/time -v env "$benv" "$bin" build "$corpus" -o "$img" > "$tag.build.out" 2> "$tag.build.time"
    rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tag.build.time")
    hyperfine -N -w 1 -r 3 --export-json "$tag.build.json" "env $benv $bin build $corpus -o $img" > /dev/null
    imgsz=$(stat -c %s "$img")

    hyperfine -N -w 3 -r "$RUNS" "${PREPARE[@]}" --export-json "$tag.load.json" "$bin load $img" > /dev/null
    finds=(); for p in "${PREFIXES[@]}"; do finds+=("$bin find $img $p"); done
    hyperfine -N -w 3 -r "$RUNS" "${PREPARE[@]}" --export-json "$tag.find.json" "${finds[@]}" > /dev/null

    # Serving memory: peak RSS of one process that loads and answers a full-index query, and a selective one.
    serve_rss() { /usr/bin/time -f %M "$bin" find "$img" "$1" 2>&1 > /dev/null | tail -1; }
    serve_full=$(serve_rss "")
    serve_sel=$(serve_rss "$SELECTIVE")

    sum=$("$bin" find "$img" "" | sha256sum | cut -d' ' -f1)
    ok=$([ "$sum" = "$ref" ] && echo yes || echo NO)

    mean() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"]; print("%.3f" % (sum(x["mean"] for x in r)/len(r)*float(sys.argv[2])))' "$@"; }
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$impl" "$size" "$(mean "$tag.build.json" 1)" "$rss" "$imgsz" \
      "$(mean "$tag.load.json" 1000)" "$(mean "$tag.find.json" 1000)" "$serve_full" "$serve_sel" "$ok" | tee -a "$CSV"
  done
done

command -v column >/dev/null && column -s, -t "$CSV"
echo "results: $OUT"
