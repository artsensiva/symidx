#!/usr/bin/env bash
# The same-session run behind docs/GOOSE_LOGXFORM_REPORT.md. usage: consolidated.sh OUT_DIR BIN_DIR
#   1. logXform of Goose (fixes), rust-arena, rust-arena-fair: three neutral rebuilds, -t 1 (5 rounds) and -t 6 (3 rounds).
#   2. All six programs, one process per file through one wrapper, one core then all cores, 3 rounds.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; B=$2; mkdir -p "$OUT"
E=$ROOT/experiments/04-vs-tools; C=$ROOT/experiments/02-logxform/corpus/src
M="apache $C/Apache.log ssh $C/SSH.log hdfs $C/HDFS.log"; P="python3 -I experiments/03-goose-patches/measure.py"
load() { echo "$1 $(date -Is) $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/load.txt"; }
: > "$OUT/load.txt"
load start
c=(); for v in both rust rustfair; do for i in 0 1 2; do c+=("$v-$i=$B/$v-$i -t 1 $M"); done; done
taskset -c 3 $P 5 "$OUT/fair-t1.csv" "${c[@]}" 2>/dev/null; load fair-t1
c=(); for v in base both rust rustfair; do for i in 0 1 2; do c+=("$v-$i=$B/$v-$i -t 6 $M"); done; done
$P 3 "$OUT/fair-t6.csv" "${c[@]}" 2>/dev/null; load fair-t6
N="$E/run-native.sh"
taskset -c 3 $P 3 "$OUT/all-one-core.csv" "goose_fixes=$N $B/both-0 M 1" "goose_release=$N $B/base-0 M 1" "rust_arena=$N $B/rust-0 M 1" "rust_fair=$N $B/rustfair-0 M 1" "fluentbit=$E/run-fluentbit.sh M" "vector=$E/run-vector.sh M 1" 2>/dev/null; load all-one-core
$P 3 "$OUT/all-six-cores.csv" "goose_fixes=$N $B/both-0 M 6" "goose_release=$N $B/base-0 M 6" "rust_arena=$N $B/rust-0 M 6" "rust_fair=$N $B/rustfair-0 M 6" "fluentbit=$E/run-fluentbit.sh M" "vector=$E/run-vector.sh M 6" 2>/dev/null; load all-six-cores
echo "== done"
