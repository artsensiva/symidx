# Goose logxform: results, changes and plan

2026-11-04. A consolidated report on experiments 2–5: how a fixed-purpose log processor written in
[Goose](https://github.com/aardappel/goose) compares with Fluent Bit, Vector and tuned Rust, what was changed in Goose to get
there, how it was tested, and what comes next. Detailed records: [experiments/](../experiments/).

**Goose logxform** is this project's name for the program in `experiments/02-logxform/goose/`. It is a benchmark
today, not a shipped product. The project is not affiliated with Goose's authors.

## Summary

- **Against Fluent Bit and Vector, on one core: about 20× and 42× the throughput, and 19× and 43× less CPU per
  gigabyte, with less memory** (1.10× and 2.67×). This met the decision rule set before the comparison, so the log product goes ahead.
- **Most of that win comes from being a fixed-purpose program, not from Goose.** Tuned Rust wins by about as much.
- **Against tuned Rust, on one core: parity to a small lead.** Goose logxform with the fixes below reaches 1.10× tuned Rust, and
  1.03× once Rust is given the same scan trick. A second run through a different harness put those two level.
- **On six cores it trails tuned Rust: about 0.57× the throughput and 1.3× the memory.** This is the largest measured gap, and the
  next work item.
- **The gains came cheaply.** One library loop gave about 11%. A small compiler change, `from_file`, took the symbol index's
  large-corpus memory from 2.7× rust-expert's to 1.16×.
- **logxform is not yet a product.** It reads finished files and writes to stdout. Nothing here measures the cost of following files,
  retries, sinks or backpressure.

## Results

All on one machine (i5-8400T, 6 cores, no hyperthreading, `powersave` governor, Ubuntu 26.04, warm page cache). The input is 1.66 GB of Loghub
logs (HDFS, SSH, Apache; 11.9M lines), of which 7.07M records are kept. Output is discarded (`/dev/null`). All runs below are from one session, in
random order within each round. Raw data: [`experiments/05-goose-fixes/data/consolidated/`](../experiments/05-goose-fixes/data/consolidated/).

### One core

3 rounds, load average about 2. Each program runs once per input file through the same wrapper. Multiples are medians of paired
rounds, and compare the other program with Goose logxform with fixes.

| | Throughput | Lines per second | Peak RSS | CPU per GB | Speed advantage over it | Its RSS ÷ ours | Its CPU ÷ ours |
|---|---|---|---|---|---|---|---|
| **Goose logxform, with fixes** | 251.3 MB/s | 1.80 M | 36.1 MiB | 3.9 s | — | — | — |
| Goose logxform, release | 237.0 MB/s | 1.70 M | 36.0 MiB | 4.2 s | 1.06× | 1.00 | 1.08 |
| Tuned Rust (rust-arena) | 225.3 MB/s | 1.62 M | 36.1 MiB | 4.2 s | 1.12× | 1.00 | 1.07 |
| Tuned Rust, same scan | 254.8 MB/s | 1.83 M | 36.2 MiB | 3.9 s | 0.99× | 1.00 | 1.00 |
| Fluent Bit 5.1.5 (Lua) | 12.7 MB/s | 0.09 M | 39.6 MiB | 74.0 s | **19.8×** | 1.10 | **19.2** |
| Vector 0.61.0 (VRL) | 5.9 MB/s | 0.04 M | 96.2 MiB | 173.4 s | **41.9×** | 2.67 | **43.5** |

The per-round spread in this table is wide for the fast programs: Goose logxform with fixes took 6.6, 7.7 and 6.6 s. The next table is the
better comparison among them.

### One core, Goose logxform against tuned Rust

5 rounds, three neutral rebuilds of each (only a usage string differs), one process over all input, load average 3.5–4.5. By round, each
ratio stayed within 0.02, so this is the most reliable comparison here.

| | Throughput | Peak RSS | CPU | Goose logxform with fixes, ÷ this |
|---|---|---|---|---|
| **Goose logxform, with fixes** | 240.1 MB/s | 36.0 MiB | 6.87 s | — |
| Tuned Rust, same scan | 233.2 MB/s | 38.5 MiB | 7.09 s | **1.029×** (1.023–1.035 by round) |
| Tuned Rust | 218.7 MB/s | 38.3 MiB | 7.56 s | **1.098×** (1.090–1.109 by round) |

### Six cores

This stage was disturbed by other work on the machine: the 15-minute load average was about 7, and Vector's runs ranged from 124 to 387 s. So
the medians aren't reliable, and the fastest run of each is shown beside them. Memory and CPU are less affected. Use these for scale, not exact ratios.

| | Median | Fastest run | Peak RSS | CPU per GB |
|---|---|---|---|---|
| **Goose logxform, with fixes** | 322 MB/s | 699 MB/s | 471 MiB | 6.4 s |
| Goose logxform, release | 312 MB/s | 517 MB/s | 473 MiB | 6.9 s |
| Tuned Rust | 495 MB/s | 902 MB/s | 349 MiB | 4.9 s |
| Tuned Rust, same scan | 498 MB/s | 866 MB/s | 349 MiB | 4.5 s |
| Fluent Bit | 10.4 MB/s | 15.1 MB/s | 42.9 MiB | 79.3 s |
| Vector | 4.5 MB/s | 13.4 MB/s | 205 MiB | 200 s |

A separate run gives the better Goose-against-Rust number: three rebuilds each, 3 rounds, `-t 6`. Goose logxform with fixes reached 490.8 MB/s and tuned Rust 859.1 MB/s
(**0.57×**), at 480 and 366 MiB, with load average up to 9.7. An earlier, quieter run of the tools alone
([experiment 4](../experiments/04-vs-tools/REPORT.md)) measured release Goose at 605 MB/s, Fluent Bit at 14.2 and Vector at 13.0.

### Size and effort

| | Executable | Download | Lines for this task |
|---|---|---|---|
| Goose logxform | 0.1 MB | — | 597 lines of Goose, including I/O and threads |
| Tuned Rust | 0.4 MB | — | 773 lines of Rust, plus crates |
| Fluent Bit | 76.6 MB | 64 MB | 113 lines of Lua and YAML |
| Vector | 161.1 MB | 59 MB | 122 lines of VRL and YAML |

The last column favours the tools, and that matters: they need about a fifth of the code because they already do the reading, buffering and output. Goose's executable
links the shared runtime statically but libc dynamically; both figures are for x86-64 Linux.

### The symbol index

The same changes applied to the earlier symbol-index experiment, against rust-expert (rkyv over mmap). `find Model` on L, 50M lines of Python. Rows come from two sessions, so
rust-expert appears twice.

| | L load | L serving RSS | M load | M serving RSS | L image |
|---|---|---|---|---|---|
| Layout A, release | 142.8 ms | 116.1 MiB | 12.09 ms | 11.3 MiB | 39.3 MB |
| Layout A, `from_file` | 100.9 ms | 78.5 MiB | 9.57 ms | 8.4 MiB | 39.3 MB |
| **Layout A, `from_file`, in place (F3)** | **79.4 ms** | **49.8 MiB** | 6.74 ms | 5.8 MiB | 39.3 MB |
| rust-expert, same session | 6.4 ms | 43.0 MiB | 1.35 ms | 4.2 MiB | 43.9 MB |
| Layout `fixed` | 29.2 ms | 46.9 MiB | 3.3 ms | 5.9 MiB | 44.5 MB |
| Layout `fixed`, huge pages | 16.2 ms | 47.8 MiB | 3.3 ms | 5.9 MiB | 44.5 MB |
| Layout `chunked`, verified at load | 22.4 ms | 15.4 MiB | 3.1 ms | 4.9 MiB | 44.5 MB |
| rust-expert, second session | 6.4 ms | 44.6 MiB | 1.3 ms | 4.8 MiB | 43.9 MB |
| Rust, verified at load with pages dropped | 9.4 ms | 13.1 MiB | 2.9 ms | 3.5 MiB | 43.9 MB |

Goose has moved from 2.6–2.7× rust-expert's memory to 1.05–1.16× on L. It still doesn't use less, and it still loads several times slower. By the rule set in the
improvement plan, the choice of Rust for that product doesn't reopen.

## Analysis

**Why the tools lose by so much on this task.** Both spend their time in a general-purpose scripting layer and per-record conversion. On a 70 MB slice, Vector took 0.9 s with no
transform, 3.0 s with VRL and no output, and 7.2 s with JSON output. Fluent Bit converts each record to a Lua table and back. logxform does none of that. This task is transform-heavy, which is the worst
case for those layers; a Fluent Bit filter written natively in C wasn't tried, and it would likely narrow the gap considerably.

**What the win isn't.** Tuned Rust does the same job at about the same speed, so a fixed-purpose Rust tool would beat these products by as much. What these numbers show is that Goose is
already well inside the range where a specialized tool pays off.

**Memory against Fluent Bit is close.** On one core it's 1.10×, so the argument there is CPU, not memory. Against Vector, memory is a real difference too.

**Goose against tuned Rust.** Across the runs in this project:

| Run | Goose ÷ tuned Rust, one core |
|---|---|
| Experiment 2, main run, release | 0.88× |
| Experiment 2, across rebuilds, release | 0.93–1.03× |
| Experiment 2, best build flags on each side | 0.96× |
| Experiment 5, first run, release | 0.995× |
| Experiment 5, first run, with fixes | 1.12× |
| Consolidated, with fixes | 1.10× |
| Consolidated, with fixes, against Rust with the same scan | 1.03× |
| Consolidated, per-file harness, same comparison | 0.99× |

Single numbers from a busy desktop have repeatedly moved by several percent. A fair summary is parity, with a possible small lead for Goose on this workload.

**Where the speed came from.** Replacing `json::plain`'s early-exit byte loop with a compare-free one that the C compiler vectorizes gave Goose about 11–13%, and Rust about 6–7% with the identical loop.
Why Goose gains more isn't known. Removing a loop's early exit was not the fix the profile suggested.

**The six-core gap.** Goose's threads share nothing, so each batch crosses a queue by copy, in both directions; tuned Rust moves and reuses buffers. The queue copies are the leading explanation, but neither their
share of the gap nor queue waiting has been measured. That's step 4's first job. The memory cost is optional in practice: Goose logxform at `-t 1` already outruns both tools at six cores.

**Huge pages depend on the task.** On layout A they add up to 33% memory on small indexes for no speed. On `fixed` they cost nothing on small indexes and make large loads about 43% faster. On log processing, they gave
no single-thread gain and about 7% more memory. A process-wide run-time switch handles this, but it's a local experiment, not a recommendation.

## Changes implemented

All Goose changes are on local branches of a clone of the `v2026.3` tag in `toolchain/goose-src` (gitignored). **They aren't published or sent upstream**, so results that need them can't currently be
reproduced from this repository alone. Benchmark code that uses them is in `experiments/`.

| Change | What it does | Where | Result | Status |
|---|---|---|---|---|
| Patch 1 | Asks for huge pages past each data stack's first 2 MB | runtime | Target failed: L load 36% faster, M memory +24% | Not adopted |
| `GOOSE_HUGE_AFTER` | The same, set per process at run time | runtime | Lets each task choose; an 8 MB threshold missed its target | Experiment |
| Patch 2, `from_file` | Reads a saved array straight into its own storage and verifies it there | compiler, runtime | L memory 2.7× → 1.8× rust-expert's | Keep |
| `os.read_file_range` | Reads part of a file straight into an array | stdlib, runtime | Needed by `from_file` users | Keep |
| F1, `find_any` | Single-byte searches go to `memchr` from the program's own code | runtime | No measurable gain | Drop |
| F2, `json::plain` | Compare-free loop that vectorizes | stdlib | About 11–13% in Goose logxform | Keep |
| F3, in-place assignment | `a, n, ok = from_file(...)` onto an existing array no longer copies | compiler | L memory 78 → 50 MiB | Keep |

Program and benchmark changes, none of them language changes:
- Layouts `fixed` and `chunked` for the index (`experiments/03-goose-patches/layout/`).
- `rust-arena-fair`: tuned Rust plus the same scan (`experiments/05-goose-fixes/rust-arena-fair.patch`).
- A Rust `stream` mode, so that a memory win from verifying without keeping isn't credited to Goose (`layout/rust-stream/`).
- Vector and Fluent Bit configurations (`experiments/04-vs-tools/`).

## Build configurations tested

| Program | Versions | Build or install | Run settings |
|---|---|---|---|
| Goose logxform, release | Goose v2026.3, clang 21.1.8 | `goose build --cc clang` (`-O2`) | `-t 1`, `-t 6` |
| Goose logxform, with fixes | The same, plus F1, F2, F3 | The same, from the local compiler | `-t 1`, `-t 6` |
| Goose variants, for F1 and F2 alone | The same | Three neutral rebuilds of each | `-t 1`, `-t 4` (correctness), `-t 6` |
| Tuned Rust | rustc 1.99.1 | `--release`, fat LTO, `codegen-units = 1`, `panic = "abort"` | `-t 1`, `-t 6` |
| Tuned Rust, same scan | The same | The same, plus `rust-arena-fair.patch` | `-t 1`, `-t 6` |
| Fluent Bit | 5.1.5, official Ubuntu package, sha256 checked | Unpacked without root | `tail`, `lua` filter, `stdout` in `json_lines`; `mem_buf_limit: 64M` |
| Vector | 0.61.0, official gnu tarball, sha256 checked | Unpacked | `stdin`, `remap`, `file` sink to `/dev/null`, JSON; `--threads 1` or `6` |

**Build flags, before the fixes** ([experiment 2](../experiments/02-logxform/REPORT.md)): Goose ÷ Rust at matching settings was 1.00 at base, 0.88 with `-O3 -march=native` / `target-cpu=native`, 0.85 with LTO added, and 1.01 with PGO added;
the best of each against each other was 0.96. Native code generation helps Rust more; PGO helps Goose more. These haven't been re-run with the fixes.

**Tool tuning, all recorded** (70 MB slice):

| Option tried | Result | Adopted |
|---|---|---|
| Vector `console` sink | 7.5 s, 171 MiB at 6 threads; 14.9 s, 95 MiB at 1 | No |
| Vector `file` sink | 7.2 s, 189 MiB at 6 threads; 12.4 s, 101 MiB at 1 | Yes, in Vector's favour |
| Fluent Bit `protected_mode` on or off | 6.0 s, 34–35 MiB both | Left at default |
| Fluent Bit `threaded: true` | 6.0 s, 137 MiB | No |

## How it was tested

**Correctness.**
- Every Goose build and the Rust fairness build match the SHA-256 of a Python reference's output, on the S corpus and an edge-case corpus, at 1 and 4 threads. M is also checked, for each Goose fix at one thread. Tuned Rust itself was checked in experiment 2.
- The tools can't produce byte-identical JSON (their key order differs), so `check.py` compares parsed records. Vector matches on S, including order. Fluent Bit matches except for 2 of 989,056 records: its `tail` drops a final line with no
  newline. M wasn't re-checked for the tools.
- `json::plain`'s rewrite: every byte value, in every position, in strings up to length 80 (829,521 strings), in release and `--debug` builds.
- `from_file`: 29 tests, covering rejection paths and aliasing with its own target, in release and `--debug`. The index variants match their reference on S, M and L.
- Corrupted images: 428 per variant (truncations and seeded byte flips). No crash, and all modes agree.
- Goose's own test suite, patched against unpatched: the same totals, including 31 failures that also occur on the unmodified compiler and look environmental. It wasn't re-run on the run-time huge-page branch.

**Measurement.**
- `measure.py` runs each program once per round in a fresh random order. Wall time comes from a direct run, and peak RSS and CPU from a second run under GNU time.
- Results are medians of paired rounds, with neutral rebuilds where differences are small, because a rebuild alone can shift speed.
- Targets and kill rules were written before each measurement. The experiment 4 and 5 specs were written first but not committed first, so that order rests on the session's record. Changes after results are recorded as amendments.
- For fairness, each trick found for Goose was applied to the Rust comparator, and the tools got a tuning pass.

**Mistakes found along the way, and corrected:**
- Peak RSS first came from `wait4`, which can't report less than the measuring Python process's own 13 MB. The first patch 1 numbers on M were invalid, and were replaced.
- `from_file` assigned to an existing variable still copied (found from an impossible RSS number), which led to F3.
- "`json::format_string` scans each string twice" was wrong, as an outside audit said. Both sides scan once and then copy. Corrected where it appeared.
- The profile suggested about 2.6% for F1 and F2 together. F1 gave nothing, and F2 about 11%.

## What this doesn't show

- **Everything a real pipeline does.** The tools offer many sources and sinks, buffering, retries, checkpoints, routing, reload and metrics. logxform has none of them. Adding them will cost some speed.
- **Other workloads.** This task is transform-heavy. A job that mostly forwards lines would narrow the gap, and so might native filters.
- **Other hardware or conditions.** One machine, warm cache, a busy desktop, 3–5 rounds. The tool ratios are large enough to survive that, but small ratios among Goose and Rust aren't general.
- **Protobuf, Wuffs or `cbindgen`.** The other competitors in the product plan have no measurements yet.
- **Development cost.** All code was written by one AI agent, so it says nothing about human effort. The agent knows Goose best, and a specialist might configure the tools better.
- **Independent review.** The report and code have had no outside check since these changes.

## Reproducing

```
goose/fetch-toolchain.sh                                        # pinned Goose v2026.3
experiments/02-logxform/corpus/fetch.sh                         # Loghub, about 1.7 GB
experiments/02-logxform/goose/build.sh                          # Goose logxform, release
cargo build --release --locked --manifest-path experiments/02-logxform/rust-arena/Cargo.toml
```

Vector and Fluent Bit go in `toolchain/vs/` as `experiments/04-vs-tools/SPEC.md` describes, and `experiments/04-vs-tools/matrix.sh` runs the comparison with release Goose.
`experiments/05-goose-fixes/run.sh` and `consolidated.sh` need the local compiler patches.

## Plan

The goal is products built on Goose that compete with `serde` + arenas and Protobuf arenas, Vector and Fluent Bit, and Wuffs and Rust with `cbindgen`. The first candidate is a log parser and filter, as a standalone tool and then
a Fluent Bit plugin.

| Step | Work | Estimated effort | Target, or stop if |
|---|---|---|---|
| 1. Done | Run the real tools on the same corpus | — | Clear win on one core: met |
| 2. Done | Cheap fixes | — | At least 1.0× tuned Rust, one core: met |
| **3. Waiting** | Embedding: calls from any host thread, errors returned instead of aborts. [Asked on goose#63](https://github.com/aardappel/goose/issues/63#issuecomment-6620530555) | 2–4 weeks, least certain | 4 host threads give byte-identical output at ≥ 0.9× of `-t 4`, and a failed check leaves the host running. Stop if every call needs host-side locking |
| **4. Next** | Six-core gap. First measure queue waits and copy volume, then design | 1–3 weeks | ≥ 0.9× tuned Rust at 6 threads. Stop below 0.75× after a prototype |
| 5. | Fluent Bit plugin pilot on real data, plus one realistic change request | 1–2 weeks | Stop if there's no benefit a user would notice |

Open decisions for the project owner:
- Whether to publish the compiler patches, or offer them upstream (F2 and F3 first).
- Whether to build on a private compiler if upstream declines embedding. That would mean maintaining a compiler indefinitely.
- Whether "Goose logxform" stays as a public product name, which should be checked with Goose's authors first.
