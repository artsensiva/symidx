#!/usr/bin/env bash
# usage: run-fluentbit-native.sh CORPUS [ceiling-tail|ceiling-parse]
# Native parser and grep with minimal Lua, one process per input file; records to stdout. A ceiling config doesn't do the same work.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); DIR=$ROOT/experiments/04-vs-tools; . "$DIR/corpus.sh"
B=$ROOT/toolchain/vs/fluentbit
export LD_LIBRARY_PATH=$B/lib FB_DIR=$DIR/fluentbit-native
corpus_files "$1" | while read -r fmt file; do
  conf=$FB_DIR/${2:-$fmt}.conf
  FORMAT=$fmt FILE=$file "$B/x/opt/fluent-bit/bin/fluent-bit" -q -c "$conf"
done
