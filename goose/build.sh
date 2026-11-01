#!/usr/bin/env bash
# Builds goose/symidx with the pinned toolchain and system clang (spike/FINDINGS.md: the
# default `cc` on this machine is a zig wrapper, so the compiler is named explicitly).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
. ../bench/lib.sh
GOOSE=${GOOSE:-$(goose_default)}   # installed by goose/fetch-toolchain.sh
"$GOOSE" build symidx.goose --cc "${GOOSE_CC:-clang}" -o symidx
