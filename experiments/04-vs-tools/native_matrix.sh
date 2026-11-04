#!/usr/bin/env bash
# A5's measurement: per format, one core, then all cores. usage: native_matrix.sh OUT_DIR GOOSE_FIXES GOOSE_RELEASE RUST
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; G=$2; R=$3; RU=$4; mkdir -p "$OUT"
E=$ROOT/experiments/04-vs-tools; N=$E/run-native.sh; L=$E/run-fluentbit.sh; F=$E/run-fluentbit-native.sh
P="python3 -I experiments/03-goose-patches/measure.py"
load() { echo "$1 $(date -Is) $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/load.txt"; }
: > "$OUT/load.txt"; load start
for fmt in apache ssh; do
  taskset -c 3 $P 5 "$OUT/$fmt-one-core.csv" "goose_fixes=$N $G $fmt 1" "goose_release=$N $R $fmt 1" "rust_arena=$N $RU $fmt 1" "fb_lua=$L $fmt" "fb_native=$F $fmt"
  load "$fmt-one-core"
done
taskset -c 3 $P 3 "$OUT/hdfs-one-core.csv" "goose_fixes=$N $G hdfs 1" "goose_release=$N $R hdfs 1" "rust_arena=$N $RU hdfs 1" "fb_lua=$L hdfs" "fb_native=$F hdfs" "ceiling_parse=$F hdfs ceiling-parse" "ceiling_tail=$F hdfs ceiling-tail"
load hdfs-one-core
$P 3 "$OUT/hdfs-all-cores.csv" "goose_fixes=$N $G hdfs 6" "rust_arena=$N $RU hdfs 6" "fb_lua=$L hdfs" "fb_native=$F hdfs"
load hdfs-all-cores
echo "== done"
