# symidx

[![bench](https://github.com/artsensiva/symidx/actions/workflows/bench.yml/badge.svg)](https://github.com/artsensiva/symidx/actions/workflows/bench.yml)

**TL;DR.** symidx tested whether [Goose](https://github.com/aardappel/goose) beats Rust on memory, image size and
start-up as the storage layer of an instant-start code index, with three byte-identical implementations.
**Verdict: Rust.** Goose's `from_bytes` copies the image, giving 2–3× the serving memory and 10–25× slower load
(warm; 1–2× cold) than rkyv over mmap; the verdict rests on serving memory, which replaced the original build-RAM
criterion mid-experiment. Practical finding: the compact layout gives 5–15× smaller indexes and 10–17× faster
builds than ctags, with lookups as fast or faster. Details: [bench/REPORT.md](bench/REPORT.md); where Goose could
fit instead: [docs/GOOSE_OPPORTUNITIES.md](docs/GOOSE_OPPORTUNITIES.md); upstream: [goose#177](https://github.com/aardappel/goose/issues/177) (bug found),
[goose#221](https://github.com/aardappel/goose/issues/221) (zero-copy view request).

**Experiment 2** ([experiments/02-logxform](experiments/02-logxform/REPORT.md), pre-registered) tested the two
strongest remaining candidates, transform kernels and log processing, on 1.66 GB of Loghub logs. After a
fairness audit, Goose reached 0.88× arena Rust's single-thread throughput and used 1.07× less peak RSS,
against a ≥ 1.3× kill criterion: **not met; the Goose track ends.** Goose beat idiomatic Rust 2.2× and
2.7×, the layout's win again. Qualification: on the macOS CI VM Goose used 1.9× less RSS (uninvestigated).

**Since then: experiments 3–5 and a product goal.** The aim is now products built on Goose, starting with a log processor. Full results, changes and
methods: **[docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md)**. On one core, Goose logxform runs about 20× and 42× as fast as Fluent Bit and Vector on the same task,
with 19× and 43× less CPU per GB and less memory, though it's a fixed-purpose program and not yet a product, and tuned Rust wins by about as much. Against tuned Rust it reaches 1.10× on one core
(1.03× once Rust gets the same scan trick, so parity to a small lead) and about 0.57× on six cores. These rely on local Goose patches, not yet published.

## What it is

A code symbol index with instant loading, built three ways to test the Goose language against Rust.
`symidx` walks a tree of `*.py` files, finds every `def` and `class`, and saves an index (name, kind, file,
line) as a binary image. Loading the image and answering a name-prefix query should be close to instant. It
was meant as the storage layer of a future instant-start language server for monorepos.

```
symidx build <dir> -o index.img    # build and save the index
symidx load index.img              # load it, print symbol count and load time
symidx find index.img <prefix>     # list symbols whose name starts with <prefix>
```

| Directory | Approach |
|---|---|
| `goose/` | Goose: variable-size name groups with inline occurrences, file spans into one path array, saved with `to_bytes` and loaded with the validating `from_bytes` |
| `rust-idiomatic/` | Rust: plain structs + serde/bincode, then a validation pass |
| `rust-expert/` | Rust: interned string arenas + `rkyv` over mmap (zero-copy, `bytecheck` + explicit validation), streaming build (`SYMIDX_BUILD=batch` for the first, non-streaming version) |

## Hypothesis

**Original** (CLAUDE.md): Goose gives noticeably lower RAM and image size, and a much faster cold start, than
Rust, thanks to variable-size records, checked indices and loading the image without parsing. Kill criterion:
no ≥ 1.3× memory win over the expert Rust version → the larger project is done in Rust. The target table
measured memory as **peak build RAM** and image size.

**Refined** mid-experiment: **serving memory** (peak RSS of a process that loads the image and answers a query)
became the primary memory metric, because an always-resident server pays it constantly while builds are rare.
The report gives both readings side by side ([bench/REPORT.md](bench/REPORT.md), "Criterion refinement"):

| Reading | Linux (local, CI) | macOS CI VM |
|---|---|---|
| Literal: build RAM, Goose ≥ 1.3× less? | not met (parity) | met in 3 of 4 runs (1.28–1.50×, low confidence, uninvestigated) |
| Refined: serving memory, Goose ≥ 1.3× less? | not met: 2.0–2.7× **more** | not met: 3.1× **more** |

The verdict rests on the refined reading, and says so.

## Methodology

- **Task and output** ([bench/SPEC.md](bench/SPEC.md)): exact parsing rules (`def`, `class`, `async def`; identifier
  bytes), output `name\tkind\tfile\tline` sorted by name, file, line. Every implementation's `find ""` output
  must match the Python reference (`bench/ref.py`) by sha256 on every corpus; the reference checksums are
  recorded in `bench/ref-checksums.txt` and match on Linux and macOS (S and M, in CI).
- **Corpora** (`corpus/make.sh`, pinned tags):

  | Corpus | Contents | Files | Lines |
  |---|---|---|---|
  | S | Django 6.1.2 | 2,919 | 0.52M |
  | M | S + CPython v3.14.10 | 5,077 | 1.6M |
  | L | M × 31 | 157k | 49.7M |

  L repeats M's names 31 times, so M is the primary memory comparison and L the scaling check.
- **Fairness rules:**
  - every implementation interns names and paths;
  - any tuning given to one is given to all: pre-faulting was measured for Goose and applied to none;
  - the same harness for everyone, each in its optimized build: Rust release + LTO + one codegen unit, Goose's default `goose build` with clang;
  - nothing extra exec'd inside a timed command;
  - the kill criterion uses the better Rust number.
  A fairness audit is part of the method: see "Lessons learned".
- **Validation rules:** every loader validates the whole image eagerly, before any query; lazy bounds checks at
  query time don't count. A structurally invalid image is rejected with a non-zero exit. Other corruption may
  give wrong results but must never crash. There's no integrity checksum, and sort order isn't checked.
  rust-idiomatic adds a validation pass after bincode; rust-expert runs bytecheck plus an explicit pass; Goose
  gets most of it from `from_bytes`.
- **Measurements** (`bench/run.sh`):
  - times are hyperfine means of whole processes;
  - build and serving RSS come from GNU `time` on Linux and `/usr/bin/time -l` on macOS;
  - "find" is the mean over the prefixes `get_ test Model _`, with load included;
  - "serving" is the peak RSS for a full-index query (`""`) and a selective one (`Model`);
  - each result directory carries an `env.txt` with the machine, OS, storage, tool versions and COLD/PIN settings.
- **Environments:**

  | Tier | What it is for | What it is not for |
  |---|---|---|
  | Local development machine (here: i5-8400T, 6 cores, NVMe, `powersave`, 2–4 GB free RAM) | developing, profiling, quick comparisons; run `bench/check-machine.sh` first | published absolute numbers |
  | CI (`.github/workflows/bench.yml`: ubuntu-24.04 and macos-26, pinned; warm and cold) | correctness on both platforms, and relative comparisons **within one run** | comparing across runs or with local numbers: shared runners are noisy |
  | Dedicated or bare-metal Linux server | numbers to publish: `performance` governor, `PIN=`, `COLD=1`, `perf` | — |
  | Real user environments (an Apple Silicon Mac, a cloud VM with network storage) | the cold-start worst case and platform effects | tight rankings |

  The verdict holds despite local noise: the deciding gaps (2.0–3.1× in serving memory, 10–25× in warm load)
  are far beyond run-to-run variation of a few percent. They come from how each implementation works
  (`from_bytes` copies the image, rkyv maps it), not from the machine.

## Results

All implementations match the reference checksum on S, M and L, locally and in CI.

**Local Linux, warm cache, M corpus** (the Phase 1 run):

| Impl | Build | Build RAM | Image | Load | Find | Serve (selective) |
|---|---|---|---|---|---|---|
| goose | 106 ms | 14.6 MB | 3.00 MB | 12.2 ms | 12.5 ms | 11.4 MB |
| rust-idiomatic | 90 ms | 29.5 MB | 4.82 MB | 18.6 ms | 20.4 ms | 16.6 MB |
| rust-expert (streaming) | 74 ms | 14.1 MB | 3.62 MB | 1.3 ms | 2.2 ms | 5.6 MB |
| rust-expert (batch, first version) | 76 ms | 26.8 MB | 3.62 MB | 1.3 ms | 2.2 ms | 5.6 MB |

**Local Linux, warm cache, L corpus:**

| Impl | Build | Build RAM | Image | Load | Find | Serve (selective) |
|---|---|---|---|---|---|---|
| goose | 5.37 s | 111 MB | 39.3 MB | 134 ms | 148 ms | 116 MB |
| rust-idiomatic | 5.97 s | 442 MB | 61.7 MB | 106 ms | 144 ms | 129 MB |
| rust-expert (streaming) | 4.84 s | 106 MB | 43.9 MB | 5.3 ms | 20.4 ms | 44 MB |
| rust-expert (batch) | 4.66 s | 388 MB | 43.9 MB | 5.1 ms | 20.2 ms | 45 MB |

**Goose / rust-expert on M across environments**, warm and cold (CI [run 41640770345](https://github.com/artsensiva/symidx/actions/runs/41640770345),
RUNS=3; cold = page cache emptied before every timed run). Local cold isn't measured: there's no passwordless
sudo on that machine.

| Environment | Load | Find | Serving RSS (selective) | Image |
|---|---|---|---|---|
| Local Linux, warm (re-run 2026-11-03) | 11.8 / 1.2 ms (9.5×) | 12.9 / 2.3 ms | 11.6 / 5.7 MB (2.0×) | 3.00 / 3.62 MB |
| CI Linux, warm | 10.8 / 1.0 ms (10.5×) | 12.8 / 1.8 ms | 11.3 / 5.6 MB (2.0×) | 3.00 / 3.62 MB |
| CI Linux, cold | 18.4 / 9.3 ms (2.0×) | 20.1 / 12.5 ms | 11.3 / 4.1 MB (2.7×) | 3.00 / 3.62 MB |
| CI macOS, warm (low confidence) | 9.4 / 2.9 ms (3.3×) | 10.0 / 4.4 ms | 10.6 / 3.5 MB (3.1×) | 3.00 / 3.62 MB |
| CI macOS, cold (low confidence) | 121.8 / 119.7 ms (parity) | 129 / 193 ms | 10.6 / 3.5 MB (3.1×) | 3.00 / 3.62 MB |

macOS numbers come from a 3-core VM with a load average above 40, over 3 runs.

**Market baselines** (`bench/baselines/run.sh`, local Linux, performance only):

| Baseline | Corpus | Build | Index | Selective query (`Model`) | Serve (selective) |
|---|---|---|---|---|---|
| ctags + readtags | M | 1.23 s | 20.1 MB | 1.3 ms | 2.2 MB |
| SQLite (Python) | M | 2.26 s | 17.7 MB | 22.6 ms | 12.9 MB |
| ctags + readtags | L | 51.8 s | 652 MB | 13.8 ms | 4.5 MB |
| SQLite (Python) | L | 98.1 s | 612 MB | 47.9 ms | 14.4 MB |

Against ctags, rust-expert builds 10–17× faster and its index is 5.6× (M) to 15× (L) smaller. Its `Model` query
takes 1.3 ms (M, the same as readtags) and 5.9 ms (L, against 13.8 ms). The S table, full-index serving
numbers and the Goose load profile are in [bench/REPORT.md](bench/REPORT.md).

## Lessons learned

- **Layout beats language.** The large wins over SQLite, ctags and idiomatic Rust (5–17× smaller indexes,
  2–4× less build RAM) come from the compact layout: interning, grouping by name, arenas, streaming. Rust can
  use all of it, and rust-expert does. What belongs to Goose itself is a 1.12–1.20× smaller image from inline
  varint records, and a validating loader for free. Against that, `from_bytes` copies, which costs serving
  memory and warm load.
- **Fairness audits reversed results.** An early run showed Goose with 2.9× less build RAM. The audit found
  my first rust-expert held all parsed text before building. Once it streamed like Goose, the gap vanished.
  rust-idiomatic's load on M fell from about 40 to 13 ms once its byte vectors used `serde_bytes`. An `env`
  wrapper inside timed builds added about 2 ms to everyone. Every one of these was a harness or implementation
  mistake, not a language property.
- **Benchmarks fail silently.**
  - CI's first run was green while every macOS time column was empty: Homebrew's hyperfine 2.0 changed its
    JSON format, and the parse error inside `$(...)` didn't stop the script.
  - `COLD=1` had never worked on Linux: with `-N`, hyperfine 1.x runs `--prepare` without a shell.
  - Under `pipefail`, a `sed q` probe randomly turned multi-line tool output into "unknown".

  The fixes: assert that every column is filled, run every mode in CI at least once, and record `env.txt`.
- **Fix the metric before the experiment.** The kill criterion named "memory", and the target table meant
  build RAM. The metric that matters for a resident server is serving memory. Reporting both readings kept
  the verdict honest when a second platform disagreed on the first.
- **Warm and cold tell different stories.** Warm load is 10–25× worse for Goose; cold, storage dominates and
  the gap is 1–2×. Serving memory doesn't depend on cache state, which is part of why it's the better
  deciding metric.
- **A young compiler shows up fast.** A 384-line port, written in about 20 minutes, found goose#177. A
  minimal repro and its control (`spike/bug_from_bytes_append*.goose`) made it fileable.

## Where Goose could fit

symidx looked like a strong fit for Goose and failed against a well-built Rust. [docs/GOOSE_OPPORTUNITIES.md](docs/GOOSE_OPPORTUNITIES.md)
applies that lesson to 11 candidates, scored against the best Rust a competent team would write, with sources
and a 1–2 day falsification test each. Only three are strong. All of them share one shape: parse many small
variable-size records, transform them, emit, drop everything at once.

| Rank | Candidate | Composite (of 20) | Verdict |
|---|---|---|---|
| 1 | Request-scoped API/RPC transform kernels | 13 | **falsified** by experiment 2 |
| 2 | Log and telemetry parsing and transformation | 13 | **falsified** by experiment 2 |
| 3 | Memory-safe parsers for untrusted input, shipped as C | 11 | strong on demand, blocked on embedding |
| 4 | Genomics record processing | 11 | main argument gone (experiment 2) |
| 5 | Batch dev-tool front-ends | 11 | plausible |
| 6 | Markup rendering | 10 | plausible |
| 7–11 | ETL, policy evaluation, graph analytics, search segment building, game frame data | 6–10 | speculative |

Poor fits: serving large read-mostly images (until something like goose#221 exists), long-lived mutable
shared state, libraries for multithreaded hosts, WebAssembly and microcontrollers, flat numeric kernels.

## Next: improving Goose

The goal is products on Goose that compete with `serde` + arenas and Protobuf arenas, Vector and Fluent Bit, and Wuffs and Rust with `cbindgen`. Results and the plan:
[docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md); the gaps in detail: [docs/GOOSE_IMPROVEMENT_PLAN.md](docs/GOOSE_IMPROVEMENT_PLAN.md).

- **Done: the real tools.** Goose logxform against Fluent Bit and Vector ([experiment 4](experiments/04-vs-tools/REPORT.md)): a clear win on one core.
- **Done: cheap fixes** ([experiment 5](experiments/05-goose-fixes/PLAN.md)), and verified loading with new layouts ([experiment 3](experiments/03-goose-patches/PLAN.md)). They stay on local branches.
- **Waiting: embedding.** Asked on [goose#63](https://github.com/aardappel/goose/issues/63#issuecomment-6620530555).
- **Next: the six-core gap.** Measuring queue waits and copy volume first.

For outside review: [AUDIT.md](AUDIT.md) (scope, reproduction, limitations, questions) and
[CLAIMS.md](CLAIMS.md) (every headline claim with its evidence).

## Reproducing

From a clean checkout, on Linux x86-64 or macOS on Apple Silicon. CI runs the same steps on every push.

```
git clone https://github.com/artsensiva/symidx && cd symidx
# tools: Linux  sudo apt install git python3 hyperfine time clang cpio
#        macOS  brew install hyperfine   (clang, cpio and git come with the Xcode command-line tools)
#        both   a Rust toolchain (rustup), and universal-ctags only for the baselines
goose/fetch-toolchain.sh          # pinned Goose v2026.3, sha256-checked against goose/toolchain.sha256
goose/build.sh                    # builds goose/symidx with clang
cargo build --release --locked --manifest-path rust-idiomatic/Cargo.toml
cargo build --release --locked --manifest-path rust-expert/Cargo.toml
corpus/make.sh                    # clones pinned Django and CPython, builds S, M, L (~2.5 GB); or: corpus/make.sh S M
bench/check-sums.sh S M L         # correctness: every implementation against bench/ref-checksums.txt
bench/check-machine.sh            # read-only readiness check; prints the commands to fix what it finds
bench/run.sh S M L                # the main benchmark; results in bench/results/<timestamp>/
COLD=1 bench/run.sh M             # cold cache (passwordless sudo for drop_caches or purge only)
bench/baselines/run.sh M L        # ctags/readtags and SQLite baselines
```

`bench/run.sh` options: `IMPLS="goose rust-expert"`, `RUNS=10`, `COLD=1`, `PIN=2,3` (Linux `taskset`; all
three implementations size their worker pools from the affinity), `OUT=<dir>`.

## Project structure

```
goose/                 Goose implementation, C directory walker, pinned toolchain fetch + hashes
rust-idiomatic/        Rust: serde + bincode
rust-expert/           Rust: arenas + rkyv over mmap, streaming build, SYMIDX_VALIDATE=lazy experiment
bench/                 run.sh, lib.sh (portable helpers, env.txt), check-sums.sh, check-machine.sh,
                       ref.py + ref-checksums.txt, SPEC.md, REPORT.md
bench/baselines/       ctags/readtags and SQLite baselines
corpus/make.sh         pinned corpora S, M, L
spike/                 Goose spike programs, load-layout experiments, bug repro, upstream issue texts
docs/                  GOOSE_LOGXFORM_REPORT.md (latest results), PHASE2.md (draft plan), GOOSE_OPPORTUNITIES.md,
                       GOOSE_IMPROVEMENT_PLAN.md
AUDIT.md, CLAIMS.md    brief for an independent audit; every headline claim with its evidence
experiments/02-logxform/  experiment 2: SPEC (pre-registered), REPORT, ref.py, goose/, rust-arena/,
                       rust-idiomatic/, run.sh, check-sums.sh, corpus/fetch.sh (Loghub), test/ (edge cases), data/
experiments/03-goose-patches/  huge pages, from_file, index layouts, Rust stream mode; measure.py
experiments/04-vs-tools/  Goose logxform against Fluent Bit and Vector: SPEC, REPORT, configs, data/
experiments/05-goose-fixes/  single-thread fixes, the fairness check, the consolidated run; data/
.github/workflows/     CI: build, checksums, warm and cold benchmarks on Linux and macOS
CLAUDE.md, DEVLOG.md   project brief and time log;  CHANGELOG.md  releases
```

## Upstream contributions

- [goose#177](https://github.com/aardappel/goose/issues/177): `from_bytes` rejects valid index types into a
  global grown with `append`, because the verifier reads a stale length. Filed with a minimal repro and a
  control. Workaround: grow pinned arrays with `push`. Open.
- [goose#221](https://github.com/aardappel/goose/issues/221): a feature request for a verified, zero-copy view
  over foreign bytes (such as an mmap), motivated by serving memory, with this project's warm and cold
  numbers. Open. Text kept in `spike/ISSUE_zero_copy_view.md`.
- [goose#63](https://github.com/aardappel/goose/issues/63#issuecomment-6620530555): a comment on the `.so` issue asking how exported calls should
  handle threads and failed checks in a host. Awaiting a reply. Text kept in `spike/COMMENT_63.md`.

## Status

- **Phase 1 (this experiment): complete.** Released as [v1.0](https://github.com/artsensiva/symidx/releases/tag/v1.0)
  (verdict, cross-platform confirmation) and v1.1 (opportunity analysis, this README).
  [`v0.1-experiment`](https://github.com/artsensiva/symidx/tree/v0.1-experiment) marks the state of the first report.
- **Open item:** rust-expert's higher build RAM on the macOS CI VM, not investigated.
- **Experiment 2 (logxform): complete**, released as v1.2: kill criterion not met
  ([experiments/02-logxform/REPORT.md](experiments/02-logxform/REPORT.md)). Open item: macOS RSS. That ended the search for a ≥ 1.3× win over tuned Rust, not work on Goose.
- **Experiments 3–5: complete, not released.** See [docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md). Next: the six-core gap, then embedding once upstream has answered.
- **Phase 2: draft, not started, pending decision.** [docs/PHASE2.md](docs/PHASE2.md) covers an instant-start
  code navigation index for AI coding agents, as an MCP server in Rust, built on rust-expert's design.

## Known Goose issues

- `from_bytes` rejects valid index types into an array grown with `append` (goose#177).
- `from_bytes` always copies into fresh memory: load pays page faults plus a verify walk, and serving holds
  two copies of the image at once (goose#221).
- `varint` is signed (zigzag), so an image can carry negative line numbers; the loader checks `line >= 1`.
- `os.goose` has no `lstat`, and `list_dir`/`is_dir` follow symlinks: the walk is a small C sidecar.
- Globals pinned by index types can't be cleared or reassigned, so one process loads one image.
- The default `cc` may be a wrapper (here, `zig cc`). Build with `--cc clang`; `goose/build.sh` does.

## Further reading

- [bench/REPORT.md](bench/REPORT.md): methodology, full results, kill-criterion verdict, recommendation.
- [bench/SPEC.md](bench/SPEC.md): exact parsing rules, string storage, image validation, output format.
- [docs/GOOSE_OPPORTUNITIES.md](docs/GOOSE_OPPORTUNITIES.md): where Goose could fit, ranked, with sources.
- [spike/FINDINGS.md](spike/FINDINGS.md): Goose spike and load profile.
- [CLAUDE.md](CLAUDE.md): goals, metrics and targets, the Goose design. [DEVLOG.md](DEVLOG.md): time per session.
  [CHANGELOG.md](CHANGELOG.md): releases.

## License

MIT, see [LICENSE](LICENSE). Goose itself is Apache-2.0; the corpora (CPython, Django) are cloned at build
time and not redistributed here.
