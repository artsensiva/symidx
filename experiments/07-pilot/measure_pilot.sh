#!/usr/bin/env bash
# One measurement session for the pilot: end to end, writing real output and rejects files. usage: measure_pilot.sh OUT_DIR BIN_DIR WORK_DIR
# Goose and Rust are single-threaded (SPEC A4). The tools run on one core and on all cores. Python is one core.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; B=$2; W=$3; mkdir -p "$OUT" "$W"
C=$ROOT/experiments/02-logxform/corpus/src; A=$ROOT/toolchain/pilot/adversarial; X=$ROOT/experiments/07-pilot; L=$X/tools/sanitize_tool.py; PY=/usr/bin/python3
P="python3 -I experiments/03-goose-patches/measure.py"
load() { echo "$1 $(date -Is) $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/load.txt"; }
: > "$OUT/load.txt"; load start
args() { echo "--out $W/o --rejects $W/r $1 $2"; }
one_core() { # name format file rounds
  local a; a=$(args "$2" "$3")
  taskset -c 3 $P "$4" "$OUT/$1-one-core.csv" "goose=$B/sanitize-goose $a" "rust=$B/sanitize-rust $a" "python=$PY -I $X/sanitize.py $a" "fluentbit=$PY -I $L fluentbit $a" "vector=ENV:SANITIZE_THREADS=1 $PY -I $L vector $a"
  load "$1-one-core"
}
one_core apache apache "$C/Apache.log" 5
one_core ssh ssh "$C/SSH.log" 5
one_core escape_heavy hdfs "$A/escape_heavy.hdfs" 5
one_core mostly_filtered hdfs "$A/mostly_filtered.hdfs" 5
one_core hdfs hdfs "$C/HDFS.log" 5
a=$(args hdfs "$C/HDFS.log")
$P 3 "$OUT/hdfs-all-cores.csv" "goose=$B/sanitize-goose $a" "rust=$B/sanitize-rust $a" "fluentbit=$PY -I $L fluentbit $a" "vector=$PY -I $L vector $a"
load hdfs-all-cores
echo "== done"
