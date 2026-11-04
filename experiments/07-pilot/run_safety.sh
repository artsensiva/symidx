#!/usr/bin/env bash
# The safety section (SPEC A5), everything but the sanitizer builds, which BUILD.md describes.
# usage: run_safety.sh, from anywhere. Expects toolchain/pilot/{bin-change,bgl,adversarial,adversarial-change,safety/san}. Goose sanitizer build has -fno-sanitize=alignment: see data/safety/alignment.txt.
set -uo pipefail
cd "$(dirname "$0")/../.."; X=experiments/07-pilot; T=toolchain/pilot; S=$T/safety; O=$X/data/safety; C=experiments/02-logxform/corpus/src; mkdir -p "$O" "$S/w"
mkdir -p "$S/san-bin"; cp "$S/san/sanitize-goose" "$S/san/sanitize-rust" "$S/san-bin/"
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=0 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
[ -s $O/fuzz.txt ] || { python3 -I $X/safety_fuzz.py $T/bin-change $C $T/bgl/BGL.log $T/adversarial-change $S/fuzz 20000 200 $O/fuzz.txt > /dev/null 2>&1; echo "fuzz exit $?" >> $O/status.txt; }
python3 -I $X/safety_fuzz.py $S/san-bin $C $T/bgl/BGL.log $T/adversarial-change $S/fuzz-san 2000 0 $O/fuzz-sanitizers.txt > /dev/null 2>&1; echo "fuzz-sanitizers exit $?" >> $O/status.txt
: > $O/sanitizers.txt
for n in goose rust; do
  for c in adversarial adversarial-change; do echo "$n $c: $(python3 -I $X/check_oracle.py $T/$c $S/w/o-$n $S/san-bin/sanitize-$n 2>&1 | tail -1)" >> $O/sanitizers.txt; done
  for f in "bgl $T/bgl/BGL.log" "hdfs $C/HDFS_head500k.log" "ssh $C/SSH.log" "apache $C/Apache.log"; do
    set -- $f
    $S/san-bin/sanitize-$n --out $S/w/a --rejects $S/w/ar "$1" "$2" 2> $S/w/e; rc=$?
    $T/bin-change/sanitize-$n --out $S/w/b --rejects $S/w/br "$1" "$2" 2> /dev/null
    cmp -s $S/w/a $S/w/b && o=same || o=DIFFERENT; cmp -s $S/w/ar $S/w/br && j=same || j=DIFFERENT
    echo "$n $1: exit $rc; output $o; rejects $j; sanitizer reports $(grep -a -c -E 'ERROR: AddressSanitizer|runtime error' $S/w/e)" >> $O/sanitizers.txt
  done
done
echo "sanitizers done" >> $O/status.txt
env -u ASAN_OPTIONS -u UBSAN_OPTIONS BGL_LOG=$T/bgl/BGL.log bash $X/safety_checks.sh $T/bin-change $C $S/w2 $O > $O/checks.log 2>&1; echo "checks exit $?" >> $O/status.txt
rm -rf $S/w $S/w2
