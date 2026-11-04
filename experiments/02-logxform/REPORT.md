# Experiment 2, logxform: Goose vs Rust for build–transform–render–drop log processing

2026-11-03. Pre-registered in [SPEC.md](SPEC.md) (commit `6280357`, before any implementation), one
amendment after the fairness audit (A1). Data: `results/` as listed under each table (summary.csv and
env.txt of every local run are committed in `data/`); CI runs as linked.

## Verdict

**The kill criterion is not met. The Goose track ends.** On M, warm cache, on the reference machine, after
the fairness audit, Goose is **1.14× slower** than rust-arena single-threaded and uses **1.07× less** peak
RSS at `-t 1`. The criterion needed ≥ 1.30× on either. The result isn't ambiguous by the pre-registered
rule: both ratios are far from the 1.25–1.35 band, and CI Linux agrees (0.93× and 1.07×).

| Reading (M, local Linux, warm) | Throughput, Goose ÷ rust-arena | Peak RSS `-t 1`, rust-arena ÷ Goose | Criterion (≥ 1.30 on either) |
|---|---|---|---|
| **Pre-registered: rust-arena v2, after the audit** | 216.2 / 246.5 MB/s = **0.88** | 38.4 / 36.0 MB = **1.07** | **not met** |
| Before the audit: rust-arena v1 (fat pointers in `bumpalo`, amendment A1) | 226.0 / 252.4 MB/s = 0.90 | 43.3 / 35.8 MB = 1.21 | not met |
| Code-layout spread: 3 neutral rebuilds each (audit 3) | 0.93–1.03 | 1.06–1.07 | not met |

Both readings of amendment A1 give the same verdict. So do S, L, CI Linux and multi-thread runs. The one
qualification is the **macOS CI VM**: there Goose is 1.15× faster single-threaded and uses **1.91× less**
RSS (35.0 vs 67.0 MB). This looks like the system allocator retaining freed memory: rust-idiomatic's RSS is
5.2× its CI Linux value there (534 vs 103 MB), while Goose, which never calls `malloc` for its data, has the
same RSS on both systems. This isn't investigated (see "Open items"), and per the SPEC macOS doesn't decide.

What the experiment says: on the workload shape behind Goose's best upstream benchmarks, a competent
arena-style Rust implementation matches or beats idiomatic Goose. Goose's inline variable-size records
cost a copy of every kept message, while Rust borrows. Goose's batch teardown is O(1), but so is clearing
reused `Vec`s. Against idiomatic Rust (owned `String`s, `serde_json`), Goose would have passed easily:
2.15× the throughput and 2.7× less RSS. That repeats Phase 1's lesson: the win belongs to the memory
layout, which Rust can use too, not to the language.

## What was tested

The top two candidates of [docs/GOOSE_OPPORTUNITIES.md](../../docs/GOOSE_OPPORTUNITIES.md), request-scoped
transform kernels (1) and log and telemetry processing (2), rest on one mechanism: parse many small
variable-size records, transform them, render, and drop everything at once. That is the shape of Goose's
largest upstream wins (`records`, `respond`). One benchmark tests both:

- **Task** (SPEC "Task"): read three real log formats (HDFS, OpenSSH syslog, Apache error log) in 1 MiB
  blocks and batches of 65,536 lines. Parse every line of a batch into a record with variable-size fields
  (timestamp, level, component, message, a key-value list). Then filter by per-component minimum level,
  normalize timestamps to RFC 3339, redact IPv4 addresses, extract `key=value` pairs, derive a syslog
  severity. Render NDJSON, write the batch, drop it.
- **Corpus**: Loghub (Zenodo 8196385), sha256-pinned by `corpus/fetch.sh`. S = 149 MB (Apache, SSH, the first
  500k lines of HDFS), **M = 1.66 GB (Apache, SSH, full HDFS; the decision corpus)**, L = M × 4 (6.6 GB, by
  repeating the arguments). M has 11.9M lines; 59% are kept, 41% dropped by the filter, 4,478 malformed.
- **Correctness**: a Python reference (`ref.py`) defines the output. Every implementation matches its sha256
  and its summary line on S, M, L and a synthetic edge-case corpus (`test/`) that exercises the rules the
  real logs never hit (timestamp ranges, escapes, duplicate keys, redaction boundaries, CR handling), at
  `-t 1` and `-t 4`, locally and in CI on Linux and macOS (`check-sums.sh`).
- **Kill criterion** (pre-registered): Goose must beat rust-arena by ≥ 1.3× on single-thread throughput, or
  on peak RSS of the `-t 1` process, on M, warm cache, on the reference machine, after the fairness audit.
  A deciding ratio between 1.25 and 1.35, or CI Linux disagreeing, would have been ambiguous and sent back
  to the project owner.

## Implementations

| | Goose (`goose/`) | rust-arena (`rust-arena/`) | rust-idiomatic (`rust-idiomatic/`, context) |
|---|---|---|---|
| Records | inline variable-size values: `u8[varint]` component and message, `Pair[varint]` list, one resizable array per batch | v2: 36-byte records of u32 spans into the input or a per-batch byte arena, pairs 16 bytes; v1: fat pointers in `bumpalo` | `String` per field, `Vec<(String, String)>` |
| Batch release | the data stack's top goes back when `process` returns (one store) | `Vec::clear` on reused arenas | drop of a `Vec<Record>` and its `String`s |
| Rendering | hand-written, `json::format_string` from the stdlib | hand-written into a reused buffer | `serde` derive + `serde_json` |
| Newline search | runtime `find_any` (16 bytes at a time) | `memchr` | `BufRead::read_line` |
| Threads | workers via typed queues (values are copied in and out) | `crossbeam-channel`, buffers moved and recycled | `mpsc`, `Mutex<Receiver>` |
| Lines of code | 538 (+ 37 of C for `open`/`read`/`close`) | 650 | 435 |

All three are memory-safe: no `unsafe` in either Rust version, and none exists in Goose. Builds: Rust
release, fat LTO, one codegen unit, `panic = "abort"`, default target CPU; Goose `goose build` (`-O2`) with
clang 21.

## Results

Throughput is input MB (10^6 bytes) per second of mean wall time (hyperfine); RSS is the median of 3 runs,
MB = 1024² bytes. Every row matches the reference checksum and summary line.

**Local Linux, warm cache** (the reference machine: i5-8400T, 6 cores, `powersave`, desktop load average
1.8–4; `data/local-post/`, `data/local-post-L/`; RUNS=10 for S and M, 3 for L; `-t 6` for multi-thread):

| Impl | Corpus | Single-thread | Multi-thread (6) | RSS `-t 1` | RSS `-t 6` |
|---|---|---|---|---|---|
| goose | S | 171.8 MB/s | 319.9 MB/s | 33.7 MB | 394 MB |
| rust-arena | S | 184.1 MB/s | 589.3 MB/s | 35.9 MB | 321 MB |
| rust-idiomatic | S | 61.7 MB/s | 199.0 MB/s | 98.3 MB | 530 MB |
| goose | **M** | **216.2 MB/s** | 655.5 MB/s | **36.0 MB** | 488 MB |
| rust-arena | **M** | **246.5 MB/s** | 1168.2 MB/s | **38.4 MB** | 361 MB |
| rust-idiomatic | M | 100.4 MB/s | 368.0 MB/s | 98.2 MB | 580 MB |
| goose | L | 231.3 MB/s | 553.6 MB/s | 35.8 MB | 537 MB |
| rust-arena | L | 255.1 MB/s | 945.5 MB/s | 38.4 MB | 374 MB |

L confirms scaling: throughput holds, and RSS stays flat at the M value for both (streaming works).

**Before the audit** (M, same machine, RUNS=5; binaries from `318650e`; `data/local-pre/`):

| Impl | Single-thread | Multi-thread (6) | RSS `-t 1` | RSS `-t 6` |
|---|---|---|---|---|
| goose | 226.0 MB/s | 565.0 MB/s | 35.8 MB | 503 MB |
| rust-arena v1 | 252.4 MB/s | 1015.0 MB/s | 43.3 MB | 414 MB |
| rust-idiomatic | 94.7 MB/s | 327.2 MB/s | 98.0 MB | 575 MB |

The audit's fixes moved RSS in rust-arena's favour (43.3 → 38.4 MB) and multi-thread throughput in both
directions: Goose's from 565 to 656 MB/s (reorder buffer), and rust-arena's from 1015 to 1168 MB/s (no
zero-fill). Single-thread times differ by about 4% between the two sessions for every implementation. That
is the machine, since Goose's `-t 1` code path barely changed.

**Code-layout spread** (audit finding 3; M, `-t 1`, one hyperfine invocation, RUNS=5; `data/local-layout/`):
Goose 7.24–7.34 s, rust-arena 6.81–7.43 s (two of the three rust-arena builds had a standard deviation of
0.5–0.6 s). The throughput ratio stays between 0.93 and 1.03 across all nine pairings. RSS doesn't vary:
36.7–36.8 MB against 39.0–39.1 MB.

**CI** ([run 41694111883](https://github.com/artsensiva/symidx/actions/runs/41694111883), M, warm,
RUNS=3; `data/ci-41694111883-*/`). Shared runners: compare within a row only.

| Environment | Goose ST | rust-arena ST | ratio | Goose RSS | rust-arena RSS | ratio | MT (Goose / rust-arena) |
|---|---|---|---|---|---|---|---|
| CI Linux (ubuntu-24.04, EPYC 9V74, 4 vCPU) | 413.7 MB/s | 445.2 MB/s | 0.93 | 35.8 MB | 38.2 MB | 1.07 | 814 / 976 MB/s |
| CI macOS (macos-26, M1 virtual, 3 vCPU; low confidence) | 262.4 MB/s | 228.6 MB/s | 1.15 | 35.0 MB | 67.0 MB | 1.91 | 618 / 676 MB/s |

rust-idiomatic: 150.6 MB/s and 103 MB on CI Linux, 87.4 MB/s and 534 MB on CI macOS.

**Multi-thread.** rust-arena scales better: 4.7× its single-thread rate at `-t 6`, against Goose's 3.0×.
Goose also holds more memory with 6 workers (488 vs 361 MB). Both follow from the language: Goose workers
share nothing, so every batch is copied into a typed queue and out of it, and every rendered output too.
rust-arena moves buffers through channels and recycles them.

**Cold cache** isn't measured: the reference machine has no passwordless sudo, and CI runs logxform warm
only. The verdict wouldn't change: the input is read once, in sequence, identically by all three.

## Fairness audit

Run by a separate agent that was given only the SPEC, the sources and the harness, not results or
interpretation (2026-11-03, 18:59–19:24). Its findings, and what was done:

| # | Finding | Biases | Impact (auditor's estimate) | Action |
|---|---|---|---|---|
| 1 | rust-arena v1 records are fat pointers: 64-byte record, 32-byte pair, all in the arena; about twice what a memory-minded borrowing layout needs | against rust-arena (RSS) | high on `-t 1` RSS: on S, 43.3 → 36.6 MB in the auditor's span prototype | **fixed**: rust-arena v2, u32 spans (SPEC amendment A1); both versions reported |
| 2 | rust-arena allocates a new input buffer per file; freeing the old one raises glibc's mmap threshold, so later large buffers stay resident | against rust-arena (RSS) | low with v1, 8 MB with compact records | **fixed**: one buffer reused across files, as Goose does |
| 3 | rust-arena's time moves ±5–7% with code layout alone (a changed usage string); Goose's doesn't; Rust links through `zig cc` here and through `cc` in CI | either way, random | medium on the throughput ratio | **measured**: three neutral rebuilds of each, below |
| 4 | Goose's `drop_front` copies the carried bytes twice | against Goose (time) | low, about 3% | **fixed**: in-place shift |
| 5 | Goose copies a kept message twice (redaction scratch, then the record), and pairs twice | against Goose (time) | ≤ 1–2% | **disclosed**: one copy is inherent to inline records |
| 6 | rust-arena `-t N` zero-fills 1 MiB before every read on the main thread | against rust-arena (MT) | medium on MT, none on `-t 1` | **fixed**: recycled buffers keep their length |
| 7 | Goose MT: every batch is copied into and out of the typed queues (inherent); the reorder buffer copied pending outputs twice after every in-order write (avoidable) | against Goose (MT) | medium on MT | **fixed** the avoidable part: clear when drained, compact only when dead bytes outweigh live |
| 8 | the harness timed implementations one after another, always Goose first, so drift lands on one | either way | low to medium | **fixed**: one hyperfine invocation per mode for all implementations, RSS rounds interleaved |
| 9 | `io.c` lets `read(2)` write at the data stack's top, past the resizable's length, then bumps the length (what `gs_bld_append` does, minus a copy, with no reservation check) | for Goose (saves a copy) | none measurable | **disclosed** |
| 10 | rust-idiomatic: `is_ipv4` collects a `Vec` per digit run; `read_line` validates UTF-8 | against rust-idiomatic | context only | **fixed** `is_ipv4`; the rest is idiomatic |

Checked and found fair by the auditor: build flags on both sides (`-O3` vs `-O2` on Goose's C made no
difference: 875 vs 871 ms), read sizes and syscall counts (75 reads of 1 MiB each on HDFS_head500k for
both), one write per batch on both (Rust's `LineWriter` passes a batch ending in `\n` through whole), no
huge pages on either side, identical algorithms for every parsing and transform rule, and conformance of
both to the processing model (records materialized before rendering, 2N in-flight bound, N workers plus
the main thread).

## Amendment row: build flags (added after v1.2; doesn't change the verdict)

Does a different build configuration close the single-thread gap? `flags/build.sh` builds four
configurations of each, and `flags/measure.sh` times all eight in one hyperfine invocation (M, `-t 1`, warm,
RUNS=5, load average 1.6; every variant matches the S checksum; `data/flags/`):
- Goose's configurations recompile its generated C together with the runtime source and `io.c`.
- No LTO-capable linker is installed (no lld or gold), so Goose's LTO is done by hand with clang 21's own
  LLVM: bitcode per file, `llvm-link`, then whole-program `-O3` codegen.
- Rust already has fat LTO, so its "lto" row equals "native".
- PGO trains on S for both.
- All four Rust builds link with system clang, because the default `cc` here, a zig wrapper, breaks PGO
  links. That makes this Rust "base" 5% slower than the main run's: code layout again.

| Configuration | Goose | rust-arena | Ratio |
|---|---|---|---|
| base (Goose `-O2`; Rust release + fat LTO) | 233.7 MB/s | 234.3 MB/s | 1.00 |
| -O3 -march=native / `-C target-cpu=native` | 228.9 MB/s | 260.3 MB/s | 0.88 |
| + LTO (whole program incl. Goose's runtime) | 220.9 MB/s | 259.6 MB/s | 0.85 |
| + PGO | 250.6 MB/s | 248.2 MB/s | 1.01 |

The best of each against each other: 250.6 / 260.3 = **0.96**. Native code generation helps Rust (+11%)
and not Goose (−2%); PGO helps Goose (+7%) and not Rust. No configuration comes near 1.3×.

## Profile of the single-thread gap

perf couldn't be used: `kernel.perf_event_paranoid` reads 4 from this session's shell, and valgrind isn't
installed. So the gap was split with phase timers instead. These are copies of both programs with timers
around each per-batch phase (`data/profile/`), run alternately 3 times on M at `-t 1`. Then an ablation
that stops after parsing and the filter, building no records, splits the record phase.

| Phase (M, `-t 1`, median of 3) | Goose | rust-arena | Goose ÷ Rust |
|---|---|---|---|
| read(2) + newline scan for batching | 0.49 s | 0.43 s | 1.13 |
| parse + filter (ablation, no records) | 1.80 s | 1.51 s | 1.19 |
| build records: redact, pairs, copies, push | 3.24 s | 3.34 s | 0.97 |
| render NDJSON | 1.72 s | 1.59 s | 1.08 |
| carry + write | 0.02 s | 0.01 s | — |
| total (timed builds) | 7.27 s | 6.89 s | 1.055 |

Where Goose spends its extra time:
- **Parsing (+0.29 s, most of the gap).** The field checks are scalar byte loops on both sides. Goose
  keeps bounds checks in them: `--bce-lines` reports 21 of 83 index checks and 44 of 65 slice checks kept,
  concentrated in the redaction, pair and line loops. Its parsers also fill a `Head` through a reference,
  where Rust returns an `Option` that inlines and partly folds away. Caveat: in the ablation the unused
  parse results may be eliminated differently by the two compilers.
- **Rendering (+0.13 s).** *Corrected in experiment 5:* this said `json::format_string` scans each string twice while
  Rust scans once. That's wrong: both scan once and then copy, so the cause of this gap is unknown. Both scans are
  early-exit byte loops, and replacing them with a vectorizable loop gained about 11% in Goose and 6% in Rust.
- **Newline scan (+0.06 s).** Goose's runtime `find_any` tests 16 bytes at a time, and it sits in a
  separately compiled runtime object, so it can't be inlined. `memchr` dispatches to AVX2.
- **Not a cost: copies.** Building inline records, which copies every kept message and its pairs about
  twice, is as fast as rust-arena's span bookkeeping (0.97×).
- **Vectorization.** clang vectorizes 2 of the 96 loops in Goose's generated C. The other 94 are
  early-exit byte loops that neither compiler vectorizes; the Rust side relies on `memchr` for the one
  hot loop that benefits.

This session's gap (5.5%) is smaller than the main run's (14%). That's within the code-layout spread above.

## What this means for docs/GOOSE_OPPORTUNITIES.md

- **1 (request-scoped transform kernels)** and **2 (log and telemetry processing)**: falsified by their
  shared test. The workload had exactly their shape (variable-size records, built per batch, transformed,
  rendered, dropped), and arena-style Rust was faster and at least as lean.
- **4 (genomics records)** and **7 (ETL)** lose their main argument: they rested on the same mechanism with
  a weaker market or a stronger incumbent.
- What survives is not a performance claim. Goose was the shortest of the three implementations, and it
  compiled and matched the reference on its first run, with memory safety and no lifetimes to annotate.
  Rust needed borrowing and offset spans to reach that layout. That's a development-cost argument, and
  this experiment didn't measure it beyond the minutes below.

## Open items

- **macOS RSS.** rust-arena uses 1.9× Goose's RSS on the macOS CI VM, against 1.07× on Linux, and
  rust-idiomatic 5.2× its CI Linux value. Plausible causes, not tested: macOS's allocator keeping freed pages
  resident, and `realloc` copying where glibc remaps when the output buffer grows. Pre-sizing the output
  buffer would test the second. Phase 1 saw a similar macOS-only gap in build RAM.
- Cold cache, and a dedicated quiet machine with the `performance` governor, weren't run.

## Development time

All three versions were written by the same AI agent, so the minutes compare versions with each other,
not with human hours (from commit times; see DEVLOG.md):

| Version | Minutes | Notes |
|---|---|---|
| goose | 4 | 3 compile fixes (a namespace call, implicit copies), then correct on S at `-t 1` and `-t 6` on its first run |
| rust-arena v1 | 5 | correct on its first run; one sizing fix (kv capacity) before commit |
| rust-arena v2 (after the audit) | 6 | |
| rust-idiomatic | 4 | a missing timestamp range check, found by the edge-case corpus |
| SPEC, corpus, reference | 12 | |
| fairness audit (separate agent) | 25 | |

## Reproducing

```
goose/fetch-toolchain.sh                                  # pinned Goose v2026.3
experiments/02-logxform/corpus/fetch.sh                   # Loghub archives (~190 MB), sha256-checked
experiments/02-logxform/goose/build.sh
cargo build --release --locked --manifest-path experiments/02-logxform/rust-arena/Cargo.toml
cargo build --release --locked --manifest-path experiments/02-logxform/rust-idiomatic/Cargo.toml
REF=1 experiments/02-logxform/check-sums.sh S M           # correctness (ref.py takes ~2 min on M)
experiments/02-logxform/run.sh S M                        # results/<timestamp>/summary.csv, env.txt
```
