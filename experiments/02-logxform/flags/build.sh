#!/usr/bin/env bash
# Build-flag test (REPORT "Amendment row: build flags"; outside the pre-registered verdict).
# Builds Goose's generated C and rust-arena in four configurations each, into $OUT (default
# experiments/02-logxform/flags/bin): base, native (-O3 -march=native / target-cpu=native),
# lto (Goose: whole program incl. the runtime; Rust already has fat LTO), pgo (lto + profile from S).
#   experiments/02-logxform/flags/build.sh        then  experiments/02-logxform/flags/measure.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/bench/lib.sh"
. "$ROOT/experiments/02-logxform/lib.sh"
OUT=${OUT:-$X/flags/bin}; W=$X/flags/work
rm -rf "$OUT" "$W"; mkdir -p "$OUT" "$W"
CPROF=${CPROF:-$(command -v llvm-profdata-21 || command -v llvm-profdata)}          # clang's LLVM
RPROF=${RPROF:-$(ls "$HOME"/.rustup/toolchains/*/lib/rustlib/*/bin/llvm-profdata | head -1)}   # rustc's (rustup llvm-tools)
S=$(corpus_args S)

# --- Goose: the C that `goose build` generates, compiled by hand ---
GOOSE=${GOOSE:-$(goose_default)}
(cd "$X/goose" && "$GOOSE" build logxform.goose --cc clang -o "$OUT/goose-base" > "$W/goose.log" 2>&1)
gen=$(grep -o '/[^ ]*/logxform\.c' "$W/goose.log" | head -1)
rt=$(ls "$HOME"/.goose/build/runtime/*/clang-*-release/goose_runtime.c | head -1)
[ -f "$gen" ] && [ -f "$rt" ] || { echo "generated C or runtime source not found" >&2; exit 1; }
cp "$gen" "$W/logxform.c"; cp "$rt" "$W/goose_runtime.c"
inc=$(dirname "$(ls "$HOME"/.goose/build/prog/*/native/*/include/goose.h | head -1)")
# native: the three C files as `goose build` has them, at -O3 -march=native. lto: no LTO-capable linker
# is installed (no lld, no gold), so LTO is done by hand with clang's own LLVM: each file to bitcode,
# llvm-link merges them, and clang optimizes and generates code for the whole program at once.
cp "$X/goose/io.c" "$W/io.c"
LINK=${LINK:-$(dirname "$(readlink -f "$(command -v clang)")")/llvm-link}
sep() { clang "$@" "$W/logxform.c" "$W/goose_runtime.c" "$W/io.c" -I"$inc" -lm -pthread; }
lto() {   # lto <out> <extra flags...>: whole-program build
  local out=$1; shift
  for f in logxform goose_runtime io; do clang -O3 -march=native "$@" -flto -c "$W/$f.c" -I"$inc" -o "$W/$f.bc"; done
  "$LINK" "$W/logxform.bc" "$W/goose_runtime.bc" "$W/io.bc" -o "$W/all.bc"
  clang -O3 -march=native "$@" "$W/all.bc" -o "$out" -lm -pthread
}
sep -O3 -march=native -o "$OUT/goose-native"
lto "$OUT/goose-lto"
lto "$W/goose-gen" -fprofile-instr-generate
LLVM_PROFILE_FILE="$W/goose-%p.profraw" "$W/goose-gen" -t 1 $S > /dev/null 2>&1
"$CPROF" merge -o "$W/goose.profdata" "$W"/goose-*.profraw
lto "$OUT/goose-pgo" -fprofile-instr-use="$W/goose.profdata"

# --- rust-arena ---
# All four link with system clang: the default cc here is a zig wrapper, which breaks PGO links.
cargo_() { RUSTFLAGS="$RUSTFLAGS -C linker=clang" cargo build --release --locked -q --manifest-path "$X/rust-arena/Cargo.toml" --target-dir "$W/rt-$1"; cp "$W/rt-$1/release/logxform" "$OUT/rust-arena-$1"; }
RUSTFLAGS= cargo_ base
RUSTFLAGS="-C target-cpu=native" cargo_ native
cp "$OUT/rust-arena-native" "$OUT/rust-arena-lto"   # fat LTO is already the baseline
RUSTFLAGS="-C target-cpu=native -C profile-generate=$W/rprof" cargo_ gen
"$OUT/rust-arena-gen" -t 1 $S > /dev/null 2>&1; rm "$OUT/rust-arena-gen"
"$RPROF" merge -o "$W/rust.profdata" "$W"/rprof/*.profraw
RUSTFLAGS="-C target-cpu=native -C profile-use=$W/rust.profdata" cargo_ pgo
ls -la "$OUT"
