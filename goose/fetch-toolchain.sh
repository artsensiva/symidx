#!/usr/bin/env bash
# Downloads the pinned Goose release for this platform into toolchain/ and checks its sha256 against
# goose/toolchain.sha256. Upstream publishes no checksums: the hashes were recorded from the release
# assets on 2026-11-01, and the Linux one matches the tarball used for every Phase 1 result.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/bench/lib.sh"
VERSION=v2026.3
goose=$(goose_default) || { echo "no Goose $VERSION release for $(uname -sm)" >&2; exit 1; }
[ -x "$goose" ] && { echo "already installed: $goose"; exit 0; }
dir=$(basename "$(dirname "$goose")")
tarball="$dir.tar.gz"
mkdir -p "$ROOT/toolchain/dl"
cd "$ROOT/toolchain/dl"
[ -s "$tarball" ] || curl -fsSL -o "$tarball" "https://github.com/aardappel/goose/releases/download/$VERSION/$tarball"
want=$(awk -v f="$tarball" '$2 == f {print $1}' "$ROOT/goose/toolchain.sha256")
got=$(sha256 < "$tarball")
[ -n "$want" ] && [ "$got" = "$want" ] || { echo "sha256 mismatch for $tarball: got $got, want ${want:-none}" >&2; rm -f "$tarball"; exit 1; }
tar xzf "$tarball" -C "$ROOT/toolchain"
echo "installed: $goose ($("$goose" version))"
