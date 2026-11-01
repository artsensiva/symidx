#!/usr/bin/env bash
# Correctness only: every implementation, built fresh on each corpus, must print exactly the reference
# output of bench/ref.py, and that reference must match the recorded one in bench/ref-checksums.txt
# (so results agree across machines and operating systems). Fails on any missing binary or mismatch.
#   bench/check-sums.sh [S M L]   — corpus sizes (default: S M)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bench/lib.sh"
SIZES=("${@:-S M}"); SIZES=(${SIZES[*]})
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
for size in "${SIZES[@]}"; do
  corpus="$ROOT/corpus/$size"
  [ -d "$corpus" ] || { echo "no corpus $corpus — run corpus/make.sh $size" >&2; exit 1; }
  want=$(awk -v s="$size" '$2 == s {print $1}' "$ROOT/bench/ref-checksums.txt")
  ref=$(python3 -I "$ROOT/bench/ref.py" "$corpus" | sha256)
  [ "$ref" = "$want" ] && echo "$size ref.py            ok" || { echo "$size ref.py            MISMATCH $ref (recorded $want)"; fail=1; }
  for impl in goose rust-idiomatic rust-expert rust-expert-batch; do
    case "$impl" in
      goose) bin="$ROOT/goose/symidx" ;;
      rust-expert-batch) bin="$ROOT/rust-expert/target/release/symidx" ;;
      *) bin="$ROOT/$impl/target/release/symidx" ;;
    esac
    [ -x "$bin" ] || { printf '%s %-17s MISSING %s\n' "$size" "$impl" "$bin"; fail=1; continue; }
    benv=SYMIDX_BUILD=default; [ "$impl" = rust-expert-batch ] && benv=SYMIDX_BUILD=batch
    env "$benv" "$bin" build "$corpus" -o "$TMP/i.img" > /dev/null
    "$bin" load "$TMP/i.img" > /dev/null
    sum=$("$bin" find "$TMP/i.img" "" | sha256)
    [ "$sum" = "$ref" ] && printf '%s %-17s ok\n' "$size" "$impl" || { printf '%s %-17s MISMATCH %s\n' "$size" "$impl" "$sum"; fail=1; }
  done
done
exit $fail
