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

## Status

- Days 1–2 done: corpus, behavior spec, reference implementation, benchmark script.
- Next: the Goose version (days 3–5), then the two Rust versions and the final report.

## Details

- [CLAUDE.md](CLAUDE.md) — goals, metrics and targets, the Goose design, plan.
- [bench/SPEC.md](bench/SPEC.md) — exact parsing rules, string storage, image validation, output format.
