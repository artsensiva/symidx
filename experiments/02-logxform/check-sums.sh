#!/usr/bin/env bash
# Correctness only (SPEC "Reference"): every implementation, at -t 1 and -t 4, must print exactly the
# recorded reference output (sha256 of stdout, and the stderr summary line) on each corpus, and the edge
# corpus's expected output. REF=1 also reruns ref.py and checks it against the record.
#   experiments/02-logxform/check-sums.sh [S M L]   — corpora (default: S M); the edge corpus always runs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/bench/lib.sh"
. "$ROOT/experiments/02-logxform/lib.sh"
SIZES=("${@:-S M}"); SIZES=(edge ${SIZES[*]})
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
for size in "${SIZES[@]}"; do
  args=$(corpus_args "$size")
  if [ "$size" = edge ]; then
    want=$(sha256 < "$X/test/edge.expected"); summary=$(cat "$X/test/edge.summary")
  else
    want=$(want_sum "$size"); summary=$(want_summary "$size")
    [ -n "$want" ] || { echo "no recorded checksum for $size"; exit 1; }
  fi
  if [ "${REF:-0}" = 1 ] || [ "$size" = edge ]; then
    got=$(python3 -I "$X/ref.py" $args 2> "$TMP/err" | sha256)
    [ "$got" = "$want" ] && [ "$(cat "$TMP/err")" = "$summary" ] && echo "$size ref.py               ok" \
      || { echo "$size ref.py               MISMATCH $got $(cat "$TMP/err")"; fail=1; }
  fi
  for impl in $IMPLS_ALL; do
    bin=$(bin_of "$impl")
    [ -x "$bin" ] || { printf '%s %-20s MISSING %s\n' "$size" "$impl" "$bin"; fail=1; continue; }
    for t in 1 4; do
      got=$("$bin" -t $t $args 2> "$TMP/err" | sha256)
      if [ "$got" = "$want" ] && [ "$(cat "$TMP/err")" = "$summary" ]; then printf '%s %-20s ok\n' "$size" "$impl -t $t"
      else printf '%s %-20s MISMATCH %s %s\n' "$size" "$impl -t $t" "$got" "$(cat "$TMP/err")"; fail=1; fi
    done
  done
done
exit $fail
