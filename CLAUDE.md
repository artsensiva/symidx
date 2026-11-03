All code, comments, docs and commit messages are in English.

# symidx — a code symbol index with instant loading

**Status: Phase 1 complete** (v1.0; verdict Rust, see `bench/REPORT.md`). Phase 2 (`docs/PHASE2.md`) is a draft,
not started, pending decision.

## Goal
A micro-project to test the Goose language (https://github.com/aardappel/goose) in practice.
It is the storage layer of a future instant-start language server for monorepos.

Hypothesis: Goose gives noticeably lower RAM and image size, and a much faster cold start,
than Rust, thanks to variable-size records, checked indices and loading the image without parsing.

## What the tool does
- `symidx build <dir> -o index.img` — walks *.py, finds `def`/`class`, builds an index
  (name, kind, file, line), saves the image to disk.
- `symidx load index.img` — loads the image, prints the symbol count and the load time.
- `symidx find index.img <prefix>` — name prefix search (binary search over a sorted array of references).

## Implementations to compare
All three must intern names and paths (see `bench/SPEC.md`, "String storage").
All loaders must validate the image (see `bench/SPEC.md`, "Image validation").
1. `goose/` — Goose, grouped verified layout. The image is three global arrays:
   - `paths: u8[>..]` — all file paths concatenated, in path order (bytewise);
   - `files: File[>..]`, `File { lo: u32 upto paths, hi: u32 upto paths }` — fixed-size spans into `paths`;
   - `groups: NameGroup[>..]` (variable-size elements), one per unique name, in name order (bytewise):
     `NameGroup { name: u8[varint], occs: Occ[varint] }`,
     `Occ { file: u32 in files, line: varint, kind: u8 }` (kind: 0 = def, 1 = class), occs sorted by (file, line).
   Saving via `to_bytes`, loading via `from_bytes` (validating loader: it checks every index and bound type
   against its array). The image has no `in pool` links and no unchecked offsets. After `from_bytes`,
   one sequential pass over `groups` builds the in-memory index `group_at: (NameGroup&<u32 in groups>)[>..]`
   for binary search; this pass counts toward load time. Files are parsed in `thread_fn` workers; records are
   passed through queues as flat values.
   Note: self-relative links (`T&<u32>`) are not exercised by this data shape — each one would have to target
   its own array, and nothing here links within one array. The comparison measures variable-size records,
   index types and the validating loader, not relative references.
2. `rust-idiomatic/` — `Vec<Symbol { name: String, file: String, … }>` + serde/bincode.
3. `rust-expert/` — string arena + `rkyv` (zero-copy loading).

All three implementations must produce the same result checksum.

## Corpus
CPython + Django (1.6M lines). For stress, replicate up to ~50M lines. Three sizes: S, M, L.
Prepared by `corpus/make.sh`: S = Django 6.1.2 (0.52M lines), M = + CPython v3.14.10 (1.6M),
L = M × 31 (49.7M). Parsing rules and output format are in `bench/SPEC.md`; the reference for checksums is `bench/ref.py`.

## Metrics (script `bench/run.sh`: hyperfine + GNU `time` on Linux, `/usr/bin/time -l` on macOS)
| Metric | Goose target vs Rust idiomatic | vs Rust expert |
|---|---|---|
| Peak RAM (build) | ≥ 2× less | ≥ 1.3× less |
| Image size | ≥ 2× smaller | ≥ 1.3× smaller |
| Cold load | ≥ 10× faster | ≈ parity |
| Build time | ≥ 1.2× faster | ≈ parity |
| Prefix find | parity | parity |
We also record development hours for each version.

**Kill criterion:** no ≥ 1.3× memory win over rust-expert → the big project is done in Rust.

## Plan
1. Days 1–2: build the Goose compiler, corpus, benchmark script.
2. Days 3–5: the Goose version.
3. Days 6–7: the two Rust versions.
4. Days 8–10: S/M/L runs, report `bench/REPORT.md`.

## Goose notes
- Installation: a release from GitHub Releases on PATH; on Linux it needs `libc6-dev`, and `goose build` needs gcc or clang.
  Or from source: CMake ≥ 3.27, a C++20 compiler, Python 3.
- Build programs with threads only via `goose build` (TinyCC does not support TLS).
- `goose check` — type checking only; `--bce-lines` — remaining bounds checks; `--debug` — extra checks.
- Each data stack reserves 2 GB of address space (`--stack-reserve` changes it).
- Arrays of variable-size elements cannot be indexed — only iterated, or indexed through
  a separate array of references.
- No move for resizable values: assigning large values = a copy.
- Directory walking may require an `extern fn` for `opendir`/`readdir` (C ABI).
- Documentation: https://aardappel.github.io/goose/docs/index.html
