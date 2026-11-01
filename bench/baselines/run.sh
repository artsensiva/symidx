#!/usr/bin/env bash
# Market baselines, measured like bench/run.sh: build time, peak RAM, index size, prefix-query time.
#   bench/baselines/run.sh [M L]          — corpus sizes (default: M L)
#   BASELINES="sqlite ctags" RUNS=10 ...
# Performance only. ctags parses differently (its own Python parser, --kinds-Python=cfm), so its
# results are not checksum-matched; the SQLite baseline reuses bench/ref.py's rules and is checked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIZES=("${@:-M L}"); SIZES=(${SIZES[*]})
BASELINES=(${BASELINES:-sqlite ctags})
RUNS=${RUNS:-10}
PREFIXES=(get_ test Model _)
OUT="$ROOT/bench/results/baselines-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

CSV="$OUT/summary.csv"
echo "baseline,size,build_s,build_maxrss_kb,index_bytes,query_ms,checksum_ok" > "$CSV"
mean() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"]; print("%.3f" % (sum(x["mean"] for x in r)/len(r)*float(sys.argv[2])))' "$@"; }

# Process start of the query tools alone, for reading the query column.
hyperfine -N -w 3 -r "$RUNS" --export-json "$OUT/python-startup.json" "python3 -I -c pass" > /dev/null
echo "python3 startup: $(mean "$OUT/python-startup.json" 1000) ms (included in sqlite query_ms)"

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
        ;;
      ctags)
        command -v ctags > /dev/null && command -v readtags > /dev/null || { echo "  ctags: not installed, skipping"; continue; }
        idx="$tag.tags"
        build=(ctags -R --languages=Python --kinds-Python=cfm -f "$idx" "$corpus")
        query() { echo "readtags -t $idx -p $1"; }
        ;;
    esac

    /usr/bin/time -v "${build[@]}" > "$tag.build.out" 2> "$tag.build.time"
    rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tag.build.time")
    hyperfine -N -w 0 -r 2 --export-json "$tag.build.json" "${build[*]}" > /dev/null
    size_b=$(stat -c %s "$idx")

    qs=(); for p in "${PREFIXES[@]}"; do qs+=("$(query "$p")"); done
    hyperfine -N -w 3 -r "$RUNS" --export-json "$tag.query.json" "${qs[@]}" > /dev/null

    ok=n/a
    if [ "$b" = sqlite ]; then
      sum=$(python3 -I "$ROOT/bench/baselines/sqlite_index.py" find "$idx" "" | sha256sum | cut -d' ' -f1)
      ok=$([ "$sum" = "$ref" ] && echo yes || echo NO)
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$b" "$size" "$(mean "$tag.build.json" 1)" "$rss" "$size_b" \
      "$(mean "$tag.query.json" 1000)" "$ok" | tee -a "$CSV"
  done
done

command -v column > /dev/null && column -s, -t "$CSV"
echo "results: $OUT"
