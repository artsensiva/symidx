#!/usr/bin/env bash
# Experiment 4: M corpus, 3 random-order rounds, one core then all cores (SPEC.md).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; mkdir -p "$OUT"
E=$ROOT/experiments/04-vs-tools; LX=$ROOT/experiments/02-logxform/goose/logxform; RA=$ROOT/experiments/02-logxform/rust-arena/target/release/logxform
M="python3 -I experiments/03-goose-patches/measure.py"
echo "== one core"; taskset -c 3 $M 3 "$OUT/one-core.csv" "logxform=$E/run-native.sh $LX M 1" "rust_arena=$E/run-native.sh $RA M 1" "fluentbit=$E/run-fluentbit.sh M" "vector=$E/run-vector.sh M 1"
echo "== all cores"; $M 3 "$OUT/all-cores.csv" "logxform=$E/run-native.sh $LX M 6" "rust_arena=$E/run-native.sh $RA M 6" "fluentbit=$E/run-fluentbit.sh M" "vector=$E/run-vector.sh M 6"
