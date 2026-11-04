#!/usr/bin/env bash
# Performance after the change request (SPEC A6). usage: measure_change.sh OUT_DIR BASE_BIN CHANGE_BIN WORK_DIR BGL_LOG
# Close programs run in many paired rounds on their own, since wall time depends on what ran before (RESULTS.md).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; B0=$2; B1=$3; W=$4; BGL=$5; mkdir -p "$OUT" "$W"
X=$ROOT/experiments/07-pilot; H=$ROOT/experiments/02-logxform/corpus/src/HDFS.log; L=$X/tools/sanitize_tool.py; PY=/usr/bin/python3
P="$PY -I experiments/03-goose-patches/measure.py"
load() { echo "$1 $(date -Is) $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/load.txt"; }
: > "$OUT/load.txt"; load start
a="--out $W/o --rejects $W/r hdfs $H"
taskset -c 3 $P 10 "$OUT/hdfs-before-after.csv" "goose_base=$B0/sanitize-goose $a" "goose_change=$B1/sanitize-goose $a" "rust_base=$B0/sanitize-rust $a" "rust_change=$B1/sanitize-rust $a"
load hdfs-before-after
a="--out $W/o --rejects $W/r bgl $BGL"
taskset -c 3 $P 10 "$OUT/bgl-goose-rust.csv" "goose=$B1/sanitize-goose $a" "rust=$B1/sanitize-rust $a"
load bgl-goose-rust
taskset -c 3 $P 5 "$OUT/bgl-one-core.csv" "goose=$B1/sanitize-goose $a" "rust=$B1/sanitize-rust $a" "python=$PY -I $X/sanitize.py $a" "fluentbit=$PY -I $L fluentbit $a" "vector=$PY -I $L vector $a"
load bgl-one-core
# Correctness on the real corpus, every program against the reference, by the strict checker.
$PY -I "$X/sanitize.py" --out "$W/ref" --rejects "$W/ref.rej" bgl "$BGL"
: > "$OUT/correctness.txt"
for t in "goose $B1/sanitize-goose" "rust $B1/sanitize-rust" "fluentbit $PY -I $L fluentbit" "vector $PY -I $L vector"; do
  set -- $t; n=$1; shift
  "$@" --out "$W/o" --rejects "$W/r" bgl "$BGL" 2>> "$OUT/correctness.txt"
  r=ok; $PY -I experiments/04-vs-tools/check.py "$W/ref" "$W/o" >> "$OUT/correctness.txt" 2>&1 || r=FAILED
  cmp -s "$W/ref" "$W/o" && b=identical || b=different
  cmp -s "$W/ref.rej" "$W/r" && j=same || j=different
  echo "$n: check.py $r; bytes $b; rejects $j" >> "$OUT/correctness.txt"
done
rm -f "$W/ref" "$W/ref.rej"
load end
echo "== done"
