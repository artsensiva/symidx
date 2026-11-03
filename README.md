# symidx

**TL;DR.** symidx tested whether [Goose](https://github.com/aardappel/goose) beats Rust on memory, image size and
start-up as the storage layer of an instant-start code index, with three byte-identical implementations.
**Verdict: Rust.** Goose's `from_bytes` copies the image, giving 2–3× the serving memory and 10–25× slower load
(warm; 1–2× cold) than rkyv over mmap; the verdict rests on serving memory, which replaced the original build-RAM
criterion mid-experiment. Practical finding: the compact layout gives 5–15× smaller indexes and 10–17× faster
builds than ctags, with lookups as fast or faster. Details: [bench/REPORT.md](bench/REPORT.md); upstream:
[goose#177](https://github.com/aardappel/goose/issues/177) (bug found), [goose#221](https://github.com/aardappel/goose/issues/221) (zero-copy view request).

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

Linux (x86-64) or macOS (Apple Silicon). Requirements: git, Python 3, [hyperfine](https://github.com/sharkdp/hyperfine),
`cpio`, clang, a Rust toolchain; on Linux also GNU `time` (macOS uses its own `/usr/bin/time -l`).

```
goose/fetch-toolchain.sh     # download the pinned Goose release, check its sha256 (goose/toolchain.sha256)
goose/build.sh               # build goose/symidx with clang
cargo build --release --manifest-path rust-expert/Cargo.toml     # likewise rust-idiomatic
corpus/make.sh               # clone pinned CPython + Django, build corpora S, M, L (~2.5 GB on disk); or: corpus/make.sh S M
bench/check-sums.sh S M      # correctness: every implementation against bench/ref-checksums.txt
bench/check-machine.sh       # is this machine ready for reliable numbers? (read-only; prints fix commands)
bench/run.sh S M             # benchmark every built implementation on S and M
bench/baselines/run.sh M L   # ctags/readtags and SQLite baselines
```

| Corpus | Contents | Lines |
|---|---|---|
| S | Django 6.1.2 | 0.52M |
| M | + CPython v3.14.10 | 1.6M |
| L | M × 31 | 49.7M |

`bench/run.sh` options: `IMPLS="goose rust-expert"` to choose implementations, `RUNS=10` for hyperfine runs,
`COLD=1` to empty the page cache before each load/find (Linux `drop_caches`, macOS `purge`; needs passwordless
sudo for that one command, and `bench/check-machine.sh` prints the sudoers line), `PIN=2,3` to run every
measurement on those CPUs (Linux `taskset`; all three implementations size their worker pools from the affinity,
so builds then use only those cores). Results go to `bench/results/<timestamp>/`: `summary.csv`, plus `env.txt`
with the CPU, cores, governor, RAM, OS, the storage holding the corpus, tool versions and the COLD/PIN settings.

## Benchmarking environments

| Tier | What it is for | What it is not for |
|---|---|---|
| Local development machine | developing, profiling, quick comparisons; run `bench/check-machine.sh` first | published absolute numbers: governor, background load and free RAM vary |
| CI (`.github/workflows/bench.yml`, ubuntu-latest and macos-latest) | correctness on both platforms (checksums on S and M), and relative comparisons **within one run** | comparing numbers across runs or with local results: shared runners are noisy and vary between jobs |
| Dedicated or bare-metal Linux server | numbers to publish: `performance` governor, `PIN=`, `COLD=1`, nothing else running, `perf` available | — |
| Real user environments | the cold-start worst case and platform effects: an Apple Silicon Mac (16 KB pages, APFS, `purge`), a cloud VM with network storage | tight comparisons: these are for checking that the conclusions hold, not for ranking |

Every result directory carries its `env.txt`, so a number can always be traced to the machine it came from.

The Phase 1 numbers come from one development machine (a 6-core desktop, `powersave` governor, warm cache).
The verdict holds despite that noise: the gaps that decide it are 2.0–3.1× in serving memory and 10–25× in warm
load time, far beyond run-to-run variation of a few percent, and they come from how each implementation works
(`from_bytes` copies the image, rkyv maps it), not from this machine. The numbers that would move on other
hardware are the absolute ones, and the close ones (build time and build RAM at parity) are not claimed as wins.
One exception, open and not investigated: in three CI runs on a macOS VM (3 cores), streaming rust-expert's
build RAM on M was 18.6–20.8 MB against Goose's 13.9 MB (1.34–1.50×), while on Linux the two are at parity. That
meets the literal (build-RAM) kill criterion on that VM. The verdict rests on serving memory instead, which is
3.1× higher for Goose on the same VM ([bench/REPORT.md](bench/REPORT.md), "Criterion refinement").

## Results

**Verdict: the large project should be built in Rust.** Goose's serving memory is 2.0–3.1× worse than the
streaming rust-expert's on every platform measured, warm and cold. The original build-RAM reading of the kill
criterion is met on Linux and not on the macOS CI VM; the report gives both readings. Full methodology,
cross-platform and cold-cache tables: [bench/REPORT.md](bench/REPORT.md).

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

- **Memory:** Goose's expected advantage didn't hold up against a fair Rust. Build RAM is at parity on Linux
  once rust-expert streams (the earlier 2.9× gap came from my first rust-expert); on the macOS CI VM Goose's is
  1.34–1.50× lower, uninvestigated. Serving memory is 2.0–3.1× *higher* for Goose everywhere, because `from_bytes` copies, so the read buffer and the copy are both resident. rkyv
  over mmap serves at about 1× image size.
- **Image size:** Goose wins 1.12–1.20×, below the 1.3× target. That comes from its inline varint records.
- **Load:** with a warm cache, Goose is 10–25× slower than rust-expert and can't close that gap: on L, its
  `read_file` alone takes longer than rust-expert's whole load. Cold, storage dominates both: 1–2× (parity on
  the macOS VM).
- **Layout vs language:** the large wins over SQLite, ctags and idiomatic Rust (5–17× smaller indexes, 2–4×
  less build RAM) belong to the compact layout: interning, grouping, arenas, streaming. Rust uses all of it.
  Goose's own contributions are a smaller image from inline variable-size records, and a validating loader
  that comes for free.

## Status

- **Phase 1 (this experiment): complete**, released as
  [v1.0](https://github.com/artsensiva/symidx/releases/tag/v1.0). Verdict: Rust.
  [`v0.1-experiment`](https://github.com/artsensiva/symidx/tree/v0.1-experiment) marks the state of the first report.
- **Since then:**
  - a segmented-validation experiment for rust-expert (`SYMIDX_VALIDATE=lazy`, not SPEC-conformant):
    3.5× less serving RSS on selective queries on L (`bench/REPORT.md`);
  - reproducible benchmarking: `env.txt` per result, `bench/check-machine.sh`, macOS support, and CI on Linux
    and macOS, warm and cold;
  - a Goose feature request for a verified zero-copy view, filed as
    [goose#221](https://github.com/aardappel/goose/issues/221) (`spike/ISSUE_zero_copy_view.md`).
- **Open item:** rust-expert's higher build RAM on the macOS CI VM, not investigated.
- **Phase 2: draft, not started, pending decision.** [docs/PHASE2.md](docs/PHASE2.md) covers an instant-start
  code navigation index for AI coding agents, as an MCP server in Rust, built on rust-expert's design.

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
