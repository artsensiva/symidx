#!/usr/bin/env bash
# Times the build-flag variants (flags/build.sh) on M, -t 1, warm, all in one hyperfine invocation,
# after checking each against the recorded S checksum. Writes $OUT/summary.csv (default flags/results/).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/bench/lib.sh"
. "$ROOT/experiments/02-logxform/lib.sh"
B=${BIN:-$X/flags/bin}; OUT=${OUT:-$X/flags/results}; RUNS=${RUNS:-5}; mkdir -p "$OUT"
write_env "$OUT/env.txt" "$CORPUS"
S=$(corpus_args S); M=$(corpus_args M); bytes=$(corpus_bytes M)
cmds=(); names=()
for impl in goose rust-arena; do for cfg in base native lto pgo; do
  b="$B/$impl-$cfg"
  [ "$("$b" -t 1 $S 2> /dev/null | sha256)" = "$(want_sum S)" ] || { echo "$impl-$cfg: S checksum mismatch" >&2; exit 1; }
  cmds+=("$b -t 1 $M"); names+=("$impl,$cfg")
done; done
"$b" -t 1 $M > /dev/null 2>&1   # warm the page cache
hyperfine -N -w 1 -r "$RUNS" --export-json "$OUT/st.json" "${cmds[@]}" > /dev/null
echo "impl,config,st_s,st_mbps" > "$OUT/summary.csv"
for i in "${!names[@]}"; do
  s=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"][int(sys.argv[2])]; print("%.3f" % (r["summary"]["time_wall_clock"]["mean"] if "summary" in r else r["mean"]))' "$OUT/st.json" "$i")
  echo "${names[$i]},$s,$(awk -v b="$bytes" -v s="$s" 'BEGIN {printf "%.1f", b / 1e6 / s}')" >> "$OUT/summary.csv"
done
column -s, -t "$OUT/summary.csv"
