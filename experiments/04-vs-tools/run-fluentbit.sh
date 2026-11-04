#!/usr/bin/env bash
# usage: run-fluentbit.sh CORPUS  -- one Fluent Bit process per input file; records to stdout.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); DIR=$ROOT/experiments/04-vs-tools; . "$DIR/corpus.sh"
B=$ROOT/toolchain/vs/fluentbit
export LD_LIBRARY_PATH=$B/lib FB_DIR=$DIR/fluentbit
corpus_files "$1" | while read -r fmt file; do
  FORMAT=$fmt FILE=$file "$B/x/opt/fluent-bit/bin/fluent-bit" -q -c "$DIR/fluentbit/pipeline.yaml"
done
