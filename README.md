# symidx

A code symbol index with instant loading, built three ways to test the
[Goose](https://github.com/aardappel/goose) language against Rust.

`symidx` walks a tree of `*.py` files, finds every `def` and `class`, and saves an index
(name, kind, file, line) as a binary image. Loading the image and answering a name-prefix
query should be close to instant. It is the storage layer of a future instant-start
language server for monorepos.

```
symidx build <dir> -o index.img    # build and save the index
symidx load index.img              # load it, print symbol count and load time
symidx find index.img <prefix>     # list symbols whose name starts with <prefix>
```

## Hypothesis

Goose gives noticeably lower RAM and image size, and a much faster cold start, than Rust,
thanks to variable-size records, checked indices and loading the image without parsing.
If Goose shows no ≥ 1.3× memory win over the expert Rust version, the larger project is done in Rust.

## Implementations

| Directory | Approach |
|---|---|
| `goose/` | Goose: variable-size name groups with inline occurrences, file spans into one path array, saved with `to_bytes` and loaded with the validating `from_bytes` |
| `rust-idiomatic/` | Rust: plain structs + serde/bincode |
| `rust-expert/` | Rust: string arena + `rkyv` (zero-copy, with `bytecheck`) |

All three must intern names and paths, validate the whole image during load, and
produce byte-identical `find` output, checked by sha256 against a Python reference.

## Running the benchmarks

Requirements: git, Python 3, [hyperfine](https://github.com/sharkdp/hyperfine), GNU `time`, `cpio`;
the Goose compiler and a Rust toolchain for the implementations.

```
goose/build.sh          # build goose/symidx (needs the Goose compiler and clang)
corpus/make.sh          # clone pinned CPython + Django, build corpora S, M, L (~2.5 GB on disk)
bench/run.sh S M        # benchmark every built implementation on S and M
```

| Corpus | Contents | Lines |
|---|---|---|
| S | Django 6.1.2 | 0.52M |
| M | + CPython v3.14.10 | 1.6M |
| L | M × 31 | 49.7M |

`bench/run.sh` options: `IMPLS="goose rust-expert"` to choose implementations,
`RUNS=10` for hyperfine runs, `COLD=1` to drop the page cache before each load/find
(needs passwordless sudo). Results go to `bench/results/<timestamp>/summary.csv`.

## Results so far

`bench/run.sh S M L`, 2026-11-01, 6 cores, warm page cache, other desktop apps running. All three
implementations match the reference checksum on every corpus. Times are hyperfine means over whole
processes; `find` is the mean over prefixes `get_ test Model _`, including the load.

| Impl | Corpus | Build | Peak RAM (build) | Image | Load | Find |
|---|---|---|---|---|---|---|
| goose | S | 44 ms | 9.0 MB | 1.18 MB | 5.1 ms | 5.4 ms |
| rust-idiomatic | S | 34 ms | 12.2 MB | 1.81 MB | 7.4 ms | 7.9 ms |
| rust-expert | S | 34 ms | 13.4 MB | 1.39 MB | 1.0 ms | 1.4 ms |
| goose | M | 107 ms | 17.6 MB | 3.00 MB | 11.7 ms | 12.6 ms |
| rust-idiomatic | M | 94 ms | 29.5 MB | 4.82 MB | 19.3 ms | 20.1 ms |
| rust-expert | M | 78 ms | 30.2 MB | 3.62 MB | 1.2 ms | 2.1 ms |
| goose | L | 5.98 s | 148 MB | 39.3 MB | 132 ms | 147 ms |
| rust-idiomatic | L | 6.56 s | 443 MB | 61.7 MB | 111 ms | 152 ms |
| rust-expert | L | 5.64 s | 431 MB | 43.9 MB | 5.3 ms | 19.3 ms |

Goose against rust-expert: 1.7× (M) and 2.9× (L) less peak build RAM, and a 1.20× (M) and 1.12× (L)
smaller image. Load is 10× (M) and 25× (L) slower: `from_bytes` copies into fresh memory and verifies at
about 1 GB/s, while rkyv validates in place over an mmap (`spike/FINDINGS.md`, "Load profile"). The
rust-expert build keeps every parsed file and a 16-byte sort key per symbol until the end. A leaner
build is possible, so its RAM figure is an upper bound.

Market baselines (`bench/baselines/run.sh M L`), performance only:

| Baseline | Corpus | Build | Peak RAM (build) | Index | Query |
|---|---|---|---|---|---|
| SQLite (Python, plain schema, checksum-matched) | M | 2.39 s | 38 MB | 17.7 MB | 69 ms |
| SQLite | L | 95.4 s | 673 MB | 612 MB | 1541 ms |
| universal-ctags + readtags | M, L | not run yet: ctags isn't installed | | | |

SQLite query times include 17 ms of Python startup, and its build is mostly Python parsing. A selective
query (`Model`) takes 49 ms on L, faster than Goose's one-shot `find` there, because SQLite has no load step.

## Assessment

symidx is a decision instrument, not a product. Its real competitors are ctags/readtags (near-zero load
for a prefix lookup), SQLite (an indexed file, queried without loading) and rkyv (zero-copy). So far
Goose's advantage is memory and image size, and it grows with the index: 2.9× less build RAM on L. Load
speed is not proven. Goose loads at about 0.3 GB/s, 10–25× slower than rkyv over mmap. Page faults on
the copy and the verify walk account for most of that, and the ways to close the gap are measured but
not applied (pre-faulting: -20–27%; a fixed-size occurrence layout: faster verification, but a larger image).

## Plan

1. ~~Load profiling~~ → ~~L run~~ → market baselines (SQLite done, ctags pending) → ~~Rust versions~~ → report.
2. Report (`bench/REPORT.md`) with the kill criterion: if Goose beats neither rust-expert by ≥ 1.3× in
   memory nor ctags/SQLite in a meaningful metric, the large project goes to Rust. On current numbers
   it passes the memory half of that criterion (build RAM) but misses the image-size target (≥ 1.3×).

## Known Goose issues

- `from_bytes` rejects valid index types into an array grown with `append`: the verifier reads a stale
  length. Workaround: grow pinned arrays with `push` (~2% of load). Draft upstream issue:
  `spike/ISSUE_from_bytes_append.md`.
- `varint` is signed (zigzag), so an image can carry negative line numbers; the loader checks `line >= 1`.
- `os.goose` has no `lstat`, and `list_dir`/`is_dir` follow symlinks: the walk is a small C sidecar.
- Globals pinned by index types can't be cleared or reassigned, so one process loads one image.
- The default `cc` may be a wrapper (here, `zig cc`). Build with `--cc clang`; `goose/build.sh` does.

## Details

- [CLAUDE.md](CLAUDE.md) — goals, metrics and targets, the Goose design, plan.
- [bench/SPEC.md](bench/SPEC.md) — exact parsing rules, string storage, image validation, output format.
