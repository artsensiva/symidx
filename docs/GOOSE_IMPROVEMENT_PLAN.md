# Goose improvement plan

2026-11-03, after Phase 1 ([bench/REPORT.md](../bench/REPORT.md)) and experiment 2
([experiments/02-logxform/REPORT.md](../experiments/02-logxform/REPORT.md)). Goose v2026.3.

Both experiments ended with "use Rust". This plan asks the next question: which Goose gaps decided those
verdicts, and could they be closed? It has four gaps, each with its root cause, evidence, feasibility,
the benchmark that measures it, and a target and kill criterion **pre-registered here**, before any work.
No compiler change is made by this plan as written. Every step that touches Goose itself starts by asking
upstream (step 2).

**Expectation, stated up front.** Closing all four would make Goose *competitive* with good Rust on these
workloads, not 1.3× better. Both experiments found that the large wins come from memory layout, which
Rust can use too. A reason to choose Goose after this plan would be parity on performance plus lower
development cost and safety (a free verified loader, no lifetimes, no `unsafe`), not speed.

## Status, 2026-11-04

Results: [GOOSE_LOGXFORM_REPORT.md](GOOSE_LOGXFORM_REPORT.md). The product goal changed the order: embedding now comes before the view, because every planned product needs it, and the
six-core gap comes next since embedding is waiting on upstream. Targets below are unchanged.

| Gap | State | Against its target |
|---|---|---|
| 1. View | `from_file` and layouts, locally | RSS 1.16× on L and 1.36× on M with layout A, 1.05× and 1.24× with `fixed`; load 2.5–12×. Not met (≤ 1.2×, ≤ 2×) |
| 2. Embedding | Asked on [goose#63](https://github.com/aardappel/goose/issues/63#issuecomment-6620530555) | Not started |
| 3. Parallelism | About 0.57× at `-t 6` | Not met (≥ 0.9×); next |
| 4. Codegen | F2 locally | **Met:** 1.10× and 1.12× (≥ 1.0×). 1.03× with Rust given the same scan |

## The four gaps

### 1. Zero-copy verified view (serving memory, load time)

- **Root cause.** `from_bytes` returns "a verified copy" (`docs/design/serialization.md` §5).
  Verification is "one or two linear passes over the payload … the same order as the copy that follows
  it" (§6). So a load reads the file, verifies, and then copies into fresh data-stack memory. `bytes_of`
  is the only view, and it exists only over Goose's own arrays, not over foreign bytes such as an mmap.
- **Evidence.** In Phase 1, Goose's serving RSS is 2.0–3.1× rust-expert's (rkyv over mmap), and its warm
  load 10–25× slower. Load profile on M: `read_file` 2.2 ms, `from_bytes` 5.8 ms (half of it first-touch
  page faults), validation 2.0 ms (REPORT "Goose load"). On L, `read_file` alone takes 27 ms against
  rust-expert's 5.3 ms total. Requested upstream as [goose#221](https://github.com/aardappel/goose/issues/221).
- **Feasibility: good, effort medium (an estimated 1–2 weeks for a prototype).** The verifier already
  exists apart from the copy. A `view_bytes<T>(b: u8[:]) -> const T[:], bool` could run the same walk and
  return a read-only view rooted at `b`, as `bytes_of`'s result is rooted at its array. The open design
  questions are upstream's to answer:
  - the view's lifetime when `b` is an mmap the program didn't allocate;
  - variable-size elements, which can't be indexed (an offset array, as symidx's `group_at`, still works);
  - the bitmap scratch, which needs one bit per payload byte.
- **Benchmark.** Phase 1: `bench/run.sh M L`, columns `load_ms`, `serve_sel_kb`, `serve_full_kb`, with a
  goose variant that loads through the view over `mmap` (a C sidecar, as `walk.c` is).
- **Target.** On M and L, local Linux, warm, the Goose serving RSS (selective) is ≤ 1.2× rust-expert's,
  and warm load is ≤ 2× rust-expert's.
- **Kill.** Serving RSS > 1.5× rust-expert's on L with the view, or upstream declines the design. Either
  ends this gap's work. A prototype that misses the target gets no tuning beyond one profiling pass.

### 2. Embedding in a host (library mode)

- **Root cause.** A `--standalone` library has one runtime per process: "Exported functions are not
  thread-safe: call them from the thread that called `goose_init`" (`docs/reference.md` §24, spec §7.11).
  A failed bounds check aborts the process. `thread_spawn_contained` turns aborts into an error for
  *workers* (§22), but not for exported calls.
- **Evidence.** Neither experiment measured it: no benchmark exists. But it caps the opportunities that
  are left. In docs/GOOSE_OPPORTUNITIES.md, candidates 2 (a Fluent Bit plugin), 3 (parsers shipped as C)
  and 8 (policy engines in Go or Java hosts) all name it as the blocker.
- **Feasibility: uncertain, effort large (weeks, mostly upstream design).** Workers already get their own
  data stacks and globals at spawn (§22), so a runtime per calling thread has a model to follow. Whether
  exported functions can attach to any thread, and return an error instead of aborting, depends on
  runtime internals that only upstream can judge.
- **Benchmark (new).** A C host calls the experiment 2 kernel, one batch per call, from N host threads at
  once, plus a malformed-input case that triggers a bounds check.
- **Target.** Calls from 4 host threads at once give results byte-identical to `-t 4`, at ≥ 0.9× its
  throughput. A failed check in one call returns an error to the host, and the process survives.
- **Kill.** Upstream rejects calls from any thread or contained exported calls, or the prototype needs
  host-side locking around every call.

### 3. Parallelism (multi-thread throughput and memory)

- **Root cause.** Threads share nothing. Every value that crosses a queue "must be flat" and goes across as
  "one copy" (§22). In practice it's three: built on the sender's stack, copied into a heap node by
  `qput`, and copied out by `qget`. The audit of experiment 2 confirmed this (finding 7). Results come
  back the same way.
- **Evidence.** In experiment 2 at `-t 6` on M, rust-arena runs at 1168 MB/s and Goose at 656 MB/s (0.56×).
  rust-arena scales 4.7× from one thread to six, and Goose 3.0×. Goose holds 488 MB of RSS against 361 MB.
  rust-arena moves and recycles buffers instead of copying them.
- **Feasibility: medium to hard, effort medium.** Two possible designs, both upstream's call:
  - transfer a message's storage to the receiver instead of copying it (a queue of owned regions);
  - a read-only shared input region that workers can view (overlaps with gap 1's view).

  The no-shared-mutable-memory rule can stay in both.
- **Benchmark.** Experiment 2: `experiments/02-logxform/run.sh M`, columns `mt_mbps`, `mt_rss_kb`.
- **Target.** At `-t 6` on M, local Linux, Goose reaches ≥ 0.9× rust-arena's throughput, with RSS ≤ 1.1×.
- **Kill.** Below 0.75× throughput after a prototype of the chosen design, or no design acceptable upstream.

### 4. Single-thread code generation

- **Root cause** (experiment 2 REPORT, "Profile of the single-thread gap"). Of the 5–14% single-thread gap
  on M:
  - parsing costs 1.19× rust-arena's: scalar loops that keep bounds checks (21 of 83 index and 44 of 65
    slice checks are kept, `--bce-lines`), and parsers that fill a struct through a reference instead of
    returning one;
  - rendering costs 1.08×, cause unknown (*corrected in experiment 5:* this said `json::format_string` scans twice, but
    Rust's renderer also scans and then copies);
  - the newline scan costs 1.13×: the runtime's `find_any` tests 16 bytes at a time, and it lives in a
    separately compiled runtime object, so it can't be inlined;
  - building inline records, copies included, is *not* slower (0.97×).
- **Evidence from build flags** (experiment 2 REPORT, "Amendment row"). `-O3 -march=native` and LTO don't
  help Goose (0.88× and 0.85× against Rust's matching configuration). PGO does: +7%, to 1.01× against
  Rust PGO. The best of each against each other is 0.96×. So the gap is in what the C compiler is given,
  not in how hard it optimizes.
- **Feasibility: good, effort small (days).** The fixes are library-level and need no language change:
  - a vectorizable scan in `json::plain` (experiment 5: done locally, about 11%; the same loop gives Rust about 6%);
  - `find_any` with AVX2 dispatch, as `memchr` does, compiled into the program (or in a header) so it
    can inline (experiment 5: done locally through `memchr`, no measurable gain);
  - finer bounds-check elimination in counted byte loops, a compiler change, so upstream's call.
- **Benchmark.** Experiment 2: `run.sh M` (`st_mbps`) and `flags/measure.sh` (the base row).
- **Target.** Goose ≥ 1.0× rust-arena single-threaded on M, base configuration, median over three neutral
  rebuilds of each (the layout-spread method).
- **Kill.** Below 0.95× after the library-level fixes. Stop there: a compiler change wouldn't be justified
  by the remaining gap.

## Order

1. **Profiling: done.** The phase split and the build-flag test are in the experiment 2 report. They fix
   gap 4's root causes and show that copies aren't the problem.
2. **Contact upstream.** Post the drafted comment on goose#221 (`spike/COMMENT_221.md`, not yet posted; the
   project owner decides). It offers to prototype a verified view against symidx's benchmark. Report the
   gap 4 findings at the same time, as concrete, measured suggestions (a vectorizable `json::plain`; experiment 5 found no
   measurable gain from sending `find_any` to `memchr`). Nothing after this step starts without an answer.
3. **View (gap 1).** It has the largest measured deficit (2–3× serving memory), the most tractable design
   (the verifier exists), and an existing benchmark.
4. **Embedding (gap 2).** It unblocks the most remaining opportunities, but it needs upstream design work
   first and a new benchmark.
5. **Parallelism (gap 3).** It matters only once Goose is embedded or serving, and it may reuse gap 1's
   view for shared input.

Gap 4's library-level fixes can go with step 2, as small pull requests, if upstream wants them.

## What would change the language decision

Phase 2 ([docs/PHASE2.md](PHASE2.md)) is planned in Rust. This plan reopens that decision only if gap 1
meets its target **and** gap 4 reaches parity. Then Goose would match rust-expert's serving memory and
load, keep its smaller image (1.12–1.20×) and its free verified loader, and cost less to write. Gaps 2
and 3 decide other products, not Phase 2.
