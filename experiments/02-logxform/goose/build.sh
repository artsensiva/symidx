#!/usr/bin/env bash
# Builds experiments/02-logxform/goose/logxform with the pinned toolchain and clang, as goose/build.sh does.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../../.. && pwd)
. "$ROOT/bench/lib.sh"
GOOSE=${GOOSE:-$(goose_default)}   # installed by goose/fetch-toolchain.sh
"$GOOSE" build logxform.goose --cc "${GOOSE_CC:-clang}" -o logxform
