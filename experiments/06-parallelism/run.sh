#!/usr/bin/env bash
# Experiment 6's measurements. usage: run.sh OUT_DIR BIN_DIR  (BIN_DIR holds both-0, rust-0, timed and qbench, built as PLAN.md says)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; B=$2; mkdir -p "$OUT"
C=$ROOT/experiments/02-logxform/corpus/src; M="apache $C/Apache.log ssh $C/SSH.log hdfs $C/HDFS.log"
cut -d' ' -f1-3 /proc/loadavg > "$OUT/load.txt"
c=(); for t in 1 2 3 4 6; do c+=("goose-t$t=$B/both-0 -t $t $M" "rust-t$t=$B/rust-0 -t $t $M"); done
python3 -I experiments/03-goose-patches/measure.py 3 "$OUT/scaling.csv" "${c[@]}" 2>/dev/null > "$OUT/scaling.txt"
for t in 2 3 4 5 6; do for r in 1 2; do echo "== t=$t run=$r"; "$B/timed" -t "$t" $M 2>&1 >/dev/null | grep -v '^lines='; done; done > "$OUT/stages.txt"
for sz in 65536 1048576 4194304 9000000 16000000 40000000; do n=$(( 2000000000 / sz )); [ $n -gt 500 ] && n=500; [ $n -lt 40 ] && n=40; taskset -c 2,3 "$B/qbench" "$sz" "$n"; done > "$OUT/qbench.txt"
cut -d' ' -f1-3 /proc/loadavg >> "$OUT/load.txt"
