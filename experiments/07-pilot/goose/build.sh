#!/usr/bin/env bash
# Builds logXform of Goose's tool with the pinned, unpatched Goose release.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../../.. && pwd)
. "$ROOT/bench/lib.sh"
GOOSE=${GOOSE:-$(goose_default)}
"$GOOSE" build sanitize.goose --cc "${GOOSE_CC:-clang}" -o "${1:-sanitize}"
