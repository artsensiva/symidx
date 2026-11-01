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
| `rust-expert/` | Rust: string arenas + `rkyv` over mmap (zero-copy, `bytecheck` + explicit validation), streaming build (`SYMIDX_BUILD=batch` for the first version) |

All three must intern names and paths, validate the whole image during load, and
produce byte-identical `find` output, checked by sha256 against a Python reference.

## Running the benchmarks

Requirements: git, Python 3, [hyperfine](https://github.com/sharkdp/hyperfine), GNU `time`, `cpio`;
the Goose compiler and a Rust toolchain for the implementations.

```
goose/build.sh          # build goose/symidx (needs the Goose compiler and clang)
corpus/make.sh          # clone pinned CPython + Django, build corpora S, M, L (~2.5 GB on disk)
bench/run.sh S M        # benchmark every built implementation on S and M
bench/baselines/run.sh M L   # ctags/readtags and SQLite baselines
```

| Corpus | Contents | Lines |
|---|---|---|
| S | Django 6.1.2 | 0.52M |
| M | + CPython v3.14.10 | 1.6M |
| L | M × 31 | 49.7M |

`bench/run.sh` options: `IMPLS="goose rust-expert"` to choose implementations,
`RUNS=10` for hyperfine runs, `COLD=1` to drop the page cache before each load/find
(needs passwordless sudo). Results go to `bench/results/<timestamp>/summary.csv`.

## Results

**Verdict: the large project should be built in Rust.** Goose has no ≥ 1.3× memory win over the
streaming rust-expert, so the kill criterion is triggered. Full methodology and analysis:
[bench/REPORT.md](bench/REPORT.md).

M corpus (1.6M lines), `bench/run.sh`, warm cache. All implementations match the reference checksum on S, M and L.

| Impl | Build | Build RAM | Image | Load | Find | Serve (selective) |
|---|---|---|---|---|---|---|
| goose | 106 ms | 14.6 MB | 3.00 MB | 12.2 ms | 12.5 ms | 11.4 MB |
| rust-idiomatic | 90 ms | 29.5 MB | 4.82 MB | 18.6 ms | 20.4 ms | 16.6 MB |
| rust-expert (streaming) | 74 ms | 14.1 MB | 3.62 MB | 1.3 ms | 2.2 ms | 5.6 MB |
| rust-expert (batch, first version) | 76 ms | 26.8 MB | 3.62 MB | 1.3 ms | 2.2 ms | 5.6 MB |

L corpus (49.7M lines):

| Impl | Build | Build RAM | Image | Load | Find | Serve (selective) |
|---|---|---|---|---|---|---|
| goose | 5.37 s | 111 MB | 39.3 MB | 134 ms | 148 ms | 116 MB |
| rust-idiomatic | 5.97 s | 442 MB | 61.7 MB | 106 ms | 144 ms | 129 MB |
| rust-expert (streaming) | 4.84 s | 106 MB | 43.9 MB | 5.3 ms | 20.4 ms | 44 MB |
| rust-expert (batch) | 4.66 s | 388 MB | 43.9 MB | 5.1 ms | 20.2 ms | 45 MB |

Market baselines (`bench/baselines/run.sh`), performance only:

| Baseline | Corpus | Build | Index | Selective query (`Model`) | Serve (selective) |
|---|---|---|---|---|---|
| ctags + readtags | M | 1.23 s | 20.1 MB | 1.3 ms | 2.2 MB |
| SQLite (Python) | M | 2.26 s | 17.7 MB | 22.6 ms | 12.9 MB |
| ctags + readtags | L | 51.8 s | 652 MB | 13.8 ms | 4.5 MB |
| SQLite (Python) | L | 98.1 s | 612 MB | 47.9 ms | 14.4 MB |

The S table and full-index serving numbers are in the report.

## Assessment

symidx is a decision instrument, not a product. The real competitors are ctags/readtags (no load step, a
1–14 ms selective lookup), SQLite and rkyv. The results:

- **Memory:** Goose's expected advantage didn't hold up against a fair Rust. Build RAM is at parity once
  rust-expert streams; the earlier 2.9× gap came from my first rust-expert. Serving memory is 2.0–2.6×
  *higher* for Goose, because `from_bytes` copies, so the read buffer and the copy are both resident. rkyv
  over mmap serves at about 1× image size.
- **Image size:** Goose wins 1.12–1.20×, below the 1.3× target. That comes from its inline varint records.
- **Load:** Goose is 10–25× slower than rust-expert and can't close that gap: on L, its `read_file` alone
  takes longer than rust-expert's whole load.
- **Layout vs language:** the large wins over SQLite, ctags and idiomatic Rust (5–17× smaller indexes, 2–4×
  less build RAM) belong to the compact layout: interning, grouping, arenas, streaming. Rust uses all of it.
  Goose's own contributions are a smaller image from inline variable-size records, and a validating loader
  that comes for free.

## Status

- **Phase 1 (this experiment): closed**, tagged
  [`v0.1-experiment`](https://github.com/artsensiva/symidx/tree/v0.1-experiment). Verdict: Rust.
- **Follow-ups since the tag:**
  - a segmented-validation experiment for rust-expert (`SYMIDX_VALIDATE=lazy`, not SPEC-conformant):
    3.5× less serving RSS on selective queries on L (`bench/REPORT.md`);
  - a draft Goose feature request for a verified zero-copy view (`spike/ISSUE_zero_copy_view.md`, not filed).
- **Phase 2: planned, not started.** [docs/PHASE2.md](docs/PHASE2.md) covers an instant-start code navigation
  index for AI coding agents, as an MCP server in Rust, built on rust-expert's design. It's awaiting approval.

## Known Goose issues

- `from_bytes` rejects valid index types into an array grown with `append`: the verifier reads a stale
  length. Filed as [aardappel/goose#177](https://github.com/aardappel/goose/issues/177). Workaround: grow
  pinned arrays with `push` (~2% of load).
- `from_bytes` always copies into fresh memory: load pays page faults plus a verify walk, and serving holds
  two copies of the image at once (see the report).
- `varint` is signed (zigzag), so an image can carry negative line numbers; the loader checks `line >= 1`.
- `os.goose` has no `lstat`, and `list_dir`/`is_dir` follow symlinks: the walk is a small C sidecar.
- Globals pinned by index types can't be cleared or reassigned, so one process loads one image.
- The default `cc` may be a wrapper (here, `zig cc`). Build with `--cc clang`; `goose/build.sh` does.

## Details

- [CLAUDE.md](CLAUDE.md) — goals, metrics and targets, the Goose design, plan.
- [bench/SPEC.md](bench/SPEC.md) — exact parsing rules, string storage, image validation, output format.
- [bench/REPORT.md](bench/REPORT.md) — methodology, full results, kill-criterion verdict, recommendation.
- [spike/FINDINGS.md](spike/FINDINGS.md) — Goose spike and load profile.
- [DEVLOG.md](DEVLOG.md) — time per session.

## License

MIT, see [LICENSE](LICENSE). Goose itself is Apache-2.0; the corpora (CPython, Django) are cloned at
build time and not redistributed here.
