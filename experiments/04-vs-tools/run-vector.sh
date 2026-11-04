#!/usr/bin/env bash
# usage: run-vector.sh S|M THREADS [OUT]  -- one Vector process per input file; records appended to OUT
# (default /dev/null).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); DIR=$ROOT/experiments/04-vs-tools; . "$DIR/corpus.sh"
V=$ROOT/toolchain/vs/vector/x/vector-x86_64-unknown-linux-gnu/bin/vector
OUT=${3:-/dev/null}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
corpus_files "$1" | while read -r fmt file; do
  sed "s|@FORMAT@|$fmt|; s|@DIR@|$DIR/vector|; s|@OUT@|$OUT|" "$DIR/vector/common.yaml.in" > "$T/$fmt.yaml"
  "$V" --quiet --threads "$2" --config "$T/$fmt.yaml" < "$file"
done
