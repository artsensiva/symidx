#!/usr/bin/env bash
# Experiment 5 (PLAN.md): correctness, Goose's test suite, then the measurements. usage: run.sh OUT_DIR
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"; OUT=$1; mkdir -p "$OUT/bin"; B=$OUT/bin
TC=$ROOT/toolchain; REL=$TC/goose-v2026.3-linux-x64/stdlib; X=$ROOT/experiments/02-logxform; C=$X/corpus/src
# Patched json only, so that F2 can be built with the base compiler and F1 without F2.
F2=$OUT/stdlib-f2; rm -rf "$F2"; cp -r "$REL" "$F2"; cp "$TC/goose-src/stdlib/json.goose" "$F2/json.goose"
build_goose() { # name compiler stdlib
  for i in 0 1 2; do
    d=$OUT/src/$1-$i; rm -rf "$d"; mkdir -p "$d"; cp "$X/goose/"*.goose "$X/goose/"*.c "$d/"; cp "$X/goose/"*.build "$d/" 2>/dev/null
    [ "$i" = 0 ] || sed -i "0,/usage: /s//usage$i: /" "$d/logxform.goose"
    (cd "$d" && GOOSE_STDLIB=$3 "$2" build logxform.goose --cc clang -o "$B/$1-$i" > build.log 2>&1) || { echo "build failed: $1-$i"; tail -3 "$d/build.log"; exit 1; }
  done
}
build_goose base "$TC/goose-build-base/goose" "$REL"
build_goose f1 "$TC/goose-build-s2/goose" "$REL"
build_goose f2 "$TC/goose-build-base/goose" "$F2"
build_goose both "$TC/goose-build-s2/goose" "$F2"
for i in 0 1 2; do
  d=$OUT/src/rust-$i; rm -rf "$d"; mkdir -p "$d/src"; cp "$X/rust-arena/Cargo.toml" "$X/rust-arena/Cargo.lock" "$d/"; cp "$X/rust-arena/src/"*.rs "$d/src/"
  [ "$i" = 0 ] || sed -i "0,/usage: /s//usage$i: /" "$d/src/main.rs"
  cargo build --release --locked --manifest-path "$d/Cargo.toml" > "$d/build.log" 2>&1 || { echo "build failed: rust-$i"; exit 1; }
  cp "$d/target/release/logxform" "$B/rust-$i"
done
echo "== correctness"
want() { awk -v s="$1" '$1==s{print $2}' "$X/ref-checksums.txt"; }
EDGE=$(sha256sum < "$X/test/edge.expected" | cut -d' ' -f1)
S="apache $C/Apache.log ssh $C/SSH.log hdfs $C/HDFS_head500k.log"; M="apache $C/Apache.log ssh $C/SSH.log hdfs $C/HDFS.log"
bad=0
for v in base f1 f2 both; do for i in 0 1 2; do for t in 1 4; do
  a=$("$B/$v-$i" -t $t $S 2>/dev/null | sha256sum | cut -d' ' -f1); [ "$a" = "$(want S)" ] || { echo "BAD S $v-$i -t $t"; bad=1; }
  a=$("$B/$v-$i" -t $t hdfs "$X/test/edge.hdfs" ssh "$X/test/edge.ssh" apache "$X/test/edge.apache" 2>/dev/null | sha256sum | cut -d' ' -f1); [ "$a" = "$EDGE" ] || { echo "BAD edge $v-$i -t $t"; bad=1; }
done; done; done
for v in f1 f2 both; do a=$("$B/$v-0" -t 1 $M 2>/dev/null | sha256sum | cut -d' ' -f1); [ "$a" = "$(want M)" ] && echo "ok M $v" || { echo "BAD M $v"; bad=1; }; done
[ "$bad" = 0 ] || { echo "correctness failed"; exit 1; }
echo "correctness done"
"$ROOT/experiments/05-goose-fixes/check_f3.sh" "$OUT/f3"
echo "== goose tests"
# Both suites are expected to report some failures, so their exit codes aren't the test; the failing tests' names must match.
(cd "$TC/goose-src" && GOOSE_STDLIB=$TC/goose-src/stdlib timeout 1500 python3 test/run_tests.py --exe ../goose-build-s2/goose --cc clang -j 5 > "$OUT/tests-s2.log" 2>&1) || true
python3 -I "$ROOT/experiments/05-goose-fixes/compare_tests.py" "$TC/tests-base-v2.log" "$OUT/tests-s2.log"
echo "== logxform matrix"
cmds=(); for v in base f1 f2 both rust; do for i in 0 1 2; do cmds+=("$v-$i=$B/$v-$i -t 1 $M"); done; done
taskset -c 3 python3 -I experiments/03-goose-patches/measure.py 5 "$OUT/log-t1.csv" "${cmds[@]}" 2>/dev/null
echo "== symidx F3"
W=$TC/p3; RX=$ROOT/rust-expert/target/release/symidx
for s in M L; do
  taskset -c 3 python3 -I experiments/03-goose-patches/measure.py 30 "$OUT/load-$s.csv" "base=$W/symidx-base load $W/base-$s.img" "p2=$W/symidx-p2 load $W/base-$s.img" "f3=$W/symidx-s2 load $W/base-$s.img" "rx=$RX load $W/rx-$s.img"
  taskset -c 3 python3 -I experiments/03-goose-patches/measure.py 20 "$OUT/sel-$s.csv" "base=$W/symidx-base find $W/base-$s.img Model" "p2=$W/symidx-p2 find $W/base-$s.img Model" "f3=$W/symidx-s2 find $W/base-$s.img Model" "rx=$RX find $W/rx-$s.img Model"
done
echo "== done"
