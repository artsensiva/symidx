#!/usr/bin/env bash
# Every tool's output against the native reference, on the edge corpus, S and the measured M corpus. Exits non-zero if any
# unexpected difference is found. usage: check_tools.sh LOGXFORM_BINARY SCRATCH_DIR
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); DIR=$ROOT/experiments/04-vs-tools; LX=$1; S=$2; mkdir -p "$S"
python3 -I "$DIR/test_check.py" || exit 1
status=0
for c in edge S M; do
  ref=$S/ref-$c.ndjson; "$DIR/run-native.sh" "$LX" "$c" 1 > "$ref" || { echo "reference failed on $c"; exit 1; }
  echo "== $c: reference has $(wc -l < "$ref") records"
  rm -f "$S/vector-$c.ndjson"
  "$DIR/run-vector.sh" "$c" 6 "$S/vector-$c.ndjson" 2>/dev/null || { echo "vector failed on $c"; status=1; }
  [ -e "$S/vector-$c.ndjson" ] || : > "$S/vector-$c.ndjson"
  echo "vector:"; python3 -I "$DIR/check.py" "$ref" "$S/vector-$c.ndjson" || status=1
  "$DIR/run-fluentbit.sh" "$c" > "$S/fb-$c.ndjson" 2>/dev/null || { echo "fluentbit failed on $c"; status=1; }
  # SPEC A1: tail drops a final line with no newline. One input on the edge corpus ends that way, and two on S and M.
  allow=2; [ "$c" = edge ] && allow=1
  echo "fluentbit (up to $allow final lines without a newline may be missing, SPEC A1):"
  python3 -I "$DIR/check.py" "$ref" "$S/fb-$c.ndjson" --allow-missing "$allow" || status=1
  rm -f "$S/vector-$c.ndjson" "$S/fb-$c.ndjson" "$ref"
done
exit $status
