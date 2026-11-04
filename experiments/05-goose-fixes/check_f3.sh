#!/usr/bin/env bash
# F3's differential check: test_f3_differential.goose and patch 2's test_from_file.goose, built by the compiler with F3
# and by the one without it, at every optimization level and in debug, must each pass and print identical output.
# usage: check_f3.sh SCRATCH_DIR     Exits non-zero on any difference or failure.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); S=$1; mkdir -p "$S"
export GOOSE_STDLIB=$ROOT/toolchain/goose-src/stdlib
WITH=$ROOT/toolchain/goose-build-s2/goose; WITHOUT=$ROOT/toolchain/goose-build-p2/goose
status=0
for src in "$ROOT/experiments/05-goose-fixes/test_f3_differential.goose" "$ROOT/experiments/03-goose-patches/patch2/test_from_file.goose"; do
  name=$(basename "$src" .goose)
  for mode in -O0 -O1 -O2 --debug; do
    for c in with without; do
      g=$WITH; [ "$c" = without ] && g=$WITHOUT
      "$g" build "$src" --cc clang $mode -o "$S/$name-$c$mode" > "$S/build.log" 2>&1 || { echo "BUILD FAILED $name $c $mode"; tail -5 "$S/build.log"; exit 1; }
      "$S/$name-$c$mode" "$S" > "$S/$name-$c$mode.out" 2>&1 || { echo "FAILED $name $c $mode"; grep -v '^ok' "$S/$name-$c$mode.out" | head -8; status=1; }
    done
    if cmp -s "$S/$name-with$mode.out" "$S/$name-without$mode.out"; then
      echo "same  $name $mode ($(grep -c '^ok' "$S/$name-with$mode.out") checks)"
    else
      echo "DIFFERENT $name $mode"; diff "$S/$name-with$mode.out" "$S/$name-without$mode.out" | head -8; status=1
    fi
  done
done
exit $status
