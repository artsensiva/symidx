#!/usr/bin/env bash
# Market baselines, measured like bench/run.sh: build time, peak RAM, index size, prefix-query time.
#   bench/baselines/run.sh [M L]          — corpus sizes (default: M L)
#   BASELINES="sqlite ctags" RUNS=10 ...   — COLD=1 and PIN= as in bench/run.sh
# Performance only. ctags parses differently (its own Python parser, --kinds-Python=cfm), so its
# results are not checksum-matched; the SQLite baseline reuses bench/ref.py's rules and is checked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/bench/lib.sh"
SIZES=("${@:-M L}"); SIZES=(${SIZES[*]})
BASELINES=(${BASELINES:-sqlite ctags})
RUNS=${RUNS:-10}
PREFIXES=(get_ test Model _)
OUT="$ROOT/bench/results/baselines-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
PREPARE=()
if [ "${COLD:-0}" = 1 ]; then
  cold_allowed || { echo "COLD=1 needs passwordless sudo for: $(cold_prepare_cmd) (see bench/check-machine.sh)" >&2; exit 1; }
  # Wrapped in sh -c: with -N, hyperfine 1.x runs --prepare without a shell too (2.x uses one).
  PREPARE=(--prepare "sh -c '$(cold_prepare_cmd)'")
  sh -c "$(cold_prepare_cmd)" || { echo "COLD=1: emptying the page cache failed: $(cold_prepare_cmd)" >&2; exit 1; }
fi
setup_pin
write_env "$OUT/env.txt" "$ROOT/corpus"

CSV="$OUT/summary.csv"
echo "baseline,size,build_s,build_maxrss_kb,index_bytes,query_ms,serve_full_kb,serve_sel_kb,checksum_ok" > "$CSV"

# Process start of the query tools alone, for reading the query column.
pinned hyperfine -N -w 3 -r "$RUNS" --export-json "$OUT/python-startup.json" "python3 -I -c pass" > /dev/null
py_ms=$(hf_mean "$OUT/python-startup.json" 1000)
echo "python3 startup: $py_ms ms (included in sqlite query_ms)"

for size in "${SIZES[@]}"; do
  corpus="$ROOT/corpus/$size"
  [ -d "$corpus" ] || { echo "no corpus $corpus — run corpus/make.sh" >&2; exit 1; }
  ref=$(cat "$ROOT/bench/results/ref-$size.sha256" 2>/dev/null || echo none)
  echo "== $size"
  for b in "${BASELINES[@]}"; do
    tag="$OUT/$b-$size"
    case "$b" in
      sqlite)
        idx="$tag.db"
        build=(python3 -I "$ROOT/bench/baselines/sqlite_index.py" build "$corpus" -o "$idx")
        query() { echo "python3 -I $ROOT/bench/baselines/sqlite_index.py find $idx $1"; }
        full=(python3 -I "$ROOT/bench/baselines/sqlite_index.py" find "$idx" "")
        ;;
      ctags)
        command -v ctags > /dev/null && command -v readtags > /dev/null || { echo "  ctags: not installed, skipping"; continue; }
        idx="$tag.tags"
        build=(ctags -R --languages=Python --kinds-Python=cfm -f "$idx" "$corpus")
        query() { echo "readtags -t $idx -p $1"; }
        full=(readtags -t "$idx" -l)
        ;;
    esac

    rss=$(peak_rss_kb "$tag.build.out" "$tag.build.time" "${build[@]}")
    pinned hyperfine -N -w 0 -r 2 --export-json "$tag.build.json" "${build[*]}" > /dev/null
    size_b=$(file_size "$idx")

    qs=(); for p in "${PREFIXES[@]}"; do qs+=("$(query "$p")"); done
    pinned hyperfine -N -w 3 -r "$RUNS" ${PREPARE[@]+"${PREPARE[@]}"} --export-json "$tag.query.json" "${qs[@]}" > /dev/null

    # Serving memory, as in bench/run.sh: peak RSS of one full-index query and one selective query.
    serve_full=$(peak_rss_kb /dev/null "$tag.serve.time" "${full[@]}")
    serve_sel=$(peak_rss_kb /dev/null "$tag.serve.time" $(query Model))

    ok=n/a
    if [ "$b" = sqlite ]; then
      sum=$(python3 -I "$ROOT/bench/baselines/sqlite_index.py" find "$idx" "" | sha256)
      ok=$([ "$sum" = "$ref" ] && echo yes || echo NO)
    fi
    build_s=$(hf_mean "$tag.build.json" 1); query_ms=$(hf_mean "$tag.query.json" 1000)
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$b" "$size" "$build_s" "$rss" "$size_b" \
      "$query_ms" "$serve_full" "$serve_sel" "$ok" | tee -a "$CSV"
  done
done

command -v column > /dev/null && column -s, -t "$CSV"
echo "results: $OUT"
