#!/usr/bin/env bash
# usage: run-native.sh BINARY CORPUS THREADS  -- one process per input file, the same harness as the tools.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); DIR=$ROOT/experiments/04-vs-tools; . "$DIR/corpus.sh"
corpus_files "$2" | while read -r fmt file; do "$1" -t "$3" "$fmt" "$file" 2>/dev/null; done
