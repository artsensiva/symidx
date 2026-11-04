#!/usr/bin/env bash
# Experiment 3, round 2: every layout and huge-page configuration, in random-order rounds (PLAN.md).
# usage: matrix.sh OUT_DIR  (expects binaries and images in toolchain/p3)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); cd "$ROOT"
OUT=$1; mkdir -p "$OUT"
W=$ROOT/toolchain/p3
RX=$ROOT/rust-expert/target/release/symidx
RS=$ROOT/experiments/03-goose-patches/layout/rust-stream/target/release/symidx
M="python3 -I experiments/03-goose-patches/measure.py"
H2=ENV:GOOSE_HUGE_AFTER=2097152; H8=ENV:GOOSE_HUGE_AFTER=8388608; LZ=ENV:SYMIDX_VALIDATE=lazy; ST=ENV:SYMIDX_VALIDATE=stream
symidx_set() { # size verb [query]
  local s=$1 v=$2 q=${3:-}
  printf '%s\n' \
    "base=$W/symidx-base $v $W/base-$s.img $q" \
    "A=$W/symidx-cfg $v $W/base-$s.img $q" \
    "A_h2=$H2 $W/symidx-cfg $v $W/base-$s.img $q" \
    "A_h8=$H8 $W/symidx-cfg $v $W/base-$s.img $q" \
    "fixed=$W/symidx-fixed $v $W/fixed-$s.img $q" \
    "fixed_h2=$H2 $W/symidx-fixed $v $W/fixed-$s.img $q" \
    "fixed_h8=$H8 $W/symidx-fixed $v $W/fixed-$s.img $q" \
    "stream=$W/symidx-chunked $v $W/chunked-$s.img $q" \
    "stream_h2=$H2 $W/symidx-chunked $v $W/chunked-$s.img $q" \
    "lazy=$LZ $W/symidx-chunked $v $W/chunked-$s.img $q" \
    "rx=$RX $v $W/rx-$s.img $q" \
    "rx_stream=$ST $RS $v $W/rx-$s.img $q" \
    "rx_lazy=$LZ $RS $v $W/rx-$s.img $q"
}
run() { # rounds csv pin set...
  local rounds=$1 csv=$2; shift 2
  mapfile -t cmds
  echo "== $csv"
  taskset -c 3 $M "$rounds" "$OUT/$csv.csv" "${cmds[@]}"
}
for s in M L; do
  symidx_set "$s" load | run 30 "load-$s"
  symidx_set "$s" find Model | run 20 "sel-$s"
done
symidx_set L find '""' | run 10 "full-L"
for s in M L; do
  printf '%s\n' \
    "A=$W/symidx-cfg build corpus/$s -o $W/t/a.img" \
    "A_h2=$H2 $W/symidx-cfg build corpus/$s -o $W/t/b.img" \
    "A_h8=$H8 $W/symidx-cfg build corpus/$s -o $W/t/c.img" \
    "fixed=$W/symidx-fixed build corpus/$s -o $W/t/d.img" \
    "stream=$W/symidx-chunked build corpus/$s -o $W/t/e.img" \
    "rx=$RX build corpus/$s -o $W/t/f.img" | run $([ "$s" = M ] && echo 10 || echo 3) "build-$s"
done
[ -z "${SKIP_LOG:-}" ] || exit 0
C=$ROOT/experiments/02-logxform/corpus/src
[ -f "$C/HDFS.log" ] || { . experiments/02-logxform/lib.sh; C=$CORPUS; }
LOG="apache $C/Apache.log ssh $C/SSH.log hdfs $C/HDFS.log"
log_set() { printf '%s\n' \
    "base=$W/logxform-base -t $1 $LOG" \
    "off=$W/logxform-cfg -t $1 $LOG" \
    "h2=$H2 $W/logxform-cfg -t $1 $LOG" \
    "h8=$H8 $W/logxform-cfg -t $1 $LOG"; }
log_set 1 | run 3 log-t1
mapfile -t cmds < <(log_set 6)
echo "== log-t6"; $M 3 "$OUT/log-t6.csv" "${cmds[@]}"
