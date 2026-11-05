#!/usr/bin/env bash
# Everything that runs against the frozen code on this machine, in order. usage: run_freeze.sh LABEL ROUNDS
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); LABEL=$1; ROUNDS=$2
ROOT=$(cd "$HERE/../.." && pwd); T=$ROOT/toolchain/pilot; V=$T/v2; O=$HERE/results/$LABEL; mkdir -p "$O"; cd "$ROOT"
X=experiments/09-logxform-v2; C=experiments/02-logxform/corpus/src; W=$T/work
{
  echo "== servers"; for b in $X/goose/logxform $X/rust/target/release/logxform; do echo "$b"; python3 -I $X/test_server.py "$b" 2>/dev/null | tail -1; python3 -I $X/compare_vector.py "$b" toolchain/pipebench/diff 2>&1 | tail -1; done
  echo "== batch"; (cd $X/batch && python3 -I ../batch_test.py "$V/t/b" "python3 -I sanitize.py" "$V/bin/sanitize-goose" "$V/bin/sanitize-rust" 2>&1 | tail -3)
  for c in adversarial adversarial-change; do for b in "$V/bin/sanitize-goose" "$V/bin/sanitize-rust" "python3 -I $X/batch/sanitize.py"; do echo "$c $(basename "${b%% *}"): $(python3 -I experiments/07-pilot/check_oracle.py "$T/$c" "$V/t/o" $b 2>&1 | tail -1)"; done; done
  echo "== mutants"; python3 -I $X/mutate_server.py "$ROOT/toolchain/goose-v2026.3-linux-x64/goose" "$ROOT/toolchain/pipebench/mut" 2>&1 | tail -16
  pkill -x logxform
} > "$O/checks.txt" 2>&1
# The batch tool's code didn't change in the second freeze, so its timing and fuzz results stand if they're already here.
while pgrep -f '[b]atch_fuzz' > /dev/null; do sleep 20; done
P="python3 -I experiments/03-goose-patches/measure.py"
if [ ! -s "$O/batch-ssh.csv" ]; then
a="--out $W/o --rejects $W/r hdfs $C/HDFS.log"
taskset -c 3 $P 10 "$O/batch-hdfs.csv" "goose_prechange=$T/bin/sanitize-goose $a" "goose_v2=$V/bin/sanitize-goose $a" "rust_v2=$V/bin/sanitize-rust $a" >> "$O/batch.log" 2>&1
a="--out $W/o --rejects $W/r bgl $T/bgl/BGL.log"
taskset -c 3 $P 10 "$O/batch-bgl.csv" "goose_v2=$V/bin/sanitize-goose $a" "rust_v2=$V/bin/sanitize-rust $a" >> "$O/batch.log" 2>&1
a="--out $W/o --rejects $W/r hdfs $T/adversarial/escape_heavy.hdfs"
taskset -c 3 $P 5 "$O/batch-escape.csv" "goose_v2=$V/bin/sanitize-goose $a" "rust_v2=$V/bin/sanitize-rust $a" >> "$O/batch.log" 2>&1
a="--out $W/o --rejects $W/r ssh $C/SSH.log"
taskset -c 3 $P 5 "$O/batch-ssh.csv" "goose_v2=$V/bin/sanitize-goose $a" "rust_v2=$V/bin/sanitize-rust $a" >> "$O/batch.log" 2>&1
fi
[ -s "$O/batch-fuzz.txt" ] || (cd $X && python3 -I batch_fuzz.py "$V/bin" "$ROOT/$C" "$T/bgl/BGL.log" "$T/adversarial-change" "$V/fuzz" 20000 0 "$O/batch-fuzz.txt" > /dev/null 2>&1)
"$HERE/pipebench/run_formal.sh" "$LABEL" "$ROUNDS"
