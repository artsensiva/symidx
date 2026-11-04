# Independent audit brief

For an outside reviewer of this repository. Written 2026-11-03 at v1.2.1, updated 2026-11-04 for a second review. Every headline number is
traced to its source in [CLAIMS.md](CLAIMS.md).

**Start here for the second review:** [docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md) has the results, changes and plan, and [experiments/06-parallelism/PLAN.md](experiments/06-parallelism/PLAN.md) has the newest work. The
project's aim has changed since the first review. It's no longer only to test Goose against Rust. The owner wants to build products on Goose that compete with `serde` + arenas and Protobuf arenas, Vector and Fluent Bit, and Wuffs and Rust with `cbindgen`. The owner prefers Goose,
so be alert to bias in that direction, and don't soften findings on that account. Questions for this review are in "Questions for the second review", below.

## Scope

symidx tests one question twice: does the Goose language
([aardappel/goose](https://github.com/aardappel/goose), v2026.3) beat well-written Rust on memory and speed
for workloads that suit its design? Goose's design: variable-size records stored inline, data stacks
instead of `malloc`, O(1) teardown, share-nothing threads, a validating loader. In scope:

- the two experiments, their pre-registration, harnesses, implementations and verdicts;
- whether the comparisons are fair, and whether the verdicts follow from the data;
- the plan to improve Goose ([docs/GOOSE_IMPROVEMENT_PLAN.md](docs/GOOSE_IMPROVEMENT_PLAN.md)) and the
  Phase 2 draft ([docs/PHASE2.md](docs/PHASE2.md)).

Out of scope: Goose's compiler itself, and the market analysis in docs/GOOSE_OPPORTUNITIES.md beyond its
use as the source of the hypotheses.

All implementations, harnesses and documents were written by one AI agent working for the project owner.
That is the main reason for this audit.

## The two experiments

| | Phase 1: symidx ([bench/REPORT.md](bench/REPORT.md)) | Experiment 2: logxform ([experiments/02-logxform/REPORT.md](experiments/02-logxform/REPORT.md)) |
|---|---|---|
| Workload | build a symbol index of Python sources, save an image, load it, answer prefix queries | parse three real log formats into variable-size records per 65,536-line batch, transform, render NDJSON, drop |
| Corpus | Django + CPython, pinned tags; S, M (1.6M lines), L (M × 31) | Loghub, Zenodo 8196385, sha256-pinned; S (149 MB), M (1.66 GB), L (M × 4) |
| Implementations | goose, rust-idiomatic (serde/bincode), rust-expert (arenas + rkyv over mmap) | goose, rust-arena (compact spans, per-batch arenas), rust-idiomatic (Strings + serde_json) |
| Correctness | sha256 of output against a Python reference, every corpus | the same, plus a synthetic edge-case corpus |
| Kill criterion | ≥ 1.3× memory win over rust-expert | ≥ 1.3× over rust-arena, single-thread throughput or `-t 1` peak RSS, M, warm, reference machine |
| Pre-registered | no: criterion refined mid-experiment (below) | yes: SPEC committed before any code (`6280357`); one amendment (A1) |
| Fairness audit | by the same agent | by a separate agent given only SPEC and sources; 10 findings, fixed in both directions |
| Verdict | Rust: serving memory 2.0–3.1× worse for Goose | not met: 0.88× throughput, 1.07× RSS (local Linux); CI Linux agrees |

Later work, not covered by the table above: experiments 3–5 and [docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md), with claims G1–G11 in [CLAIMS.md](CLAIMS.md).

Later work: experiment 3 (`from_file`, huge pages, index layouts), 4 (Goose logxform against Fluent Bit and Vector), 5 (single-thread fixes, fairness check, a same-session run) and 6 (the six-thread stall), with claims G1–G14 in [CLAIMS.md](CLAIMS.md).

## Reproducing from a clean checkout

Linux x86-64 or macOS on Apple Silicon. CI (`.github/workflows/bench.yml`, ubuntu-24.04 and macos-26) runs
these steps on every push.

```
git clone https://github.com/artsensiva/symidx && cd symidx
# tools: Linux  sudo apt install git python3 hyperfine time clang cpio unzip curl
#        macOS  brew install hyperfine
#        both   a Rust toolchain (rustup)
goose/fetch-toolchain.sh                      # pinned Goose v2026.3, sha256-checked

# Phase 1
goose/build.sh
cargo build --release --locked --manifest-path rust-idiomatic/Cargo.toml
cargo build --release --locked --manifest-path rust-expert/Cargo.toml
corpus/make.sh S M                            # pinned Django and CPython clones; L adds ~2.5 GB
bench/check-sums.sh S M
bench/run.sh S M                              # bench/results/<timestamp>/summary.csv, env.txt

# Experiment 2
experiments/02-logxform/corpus/fetch.sh       # ~190 MB of archives, ~1.7 GB extracted
experiments/02-logxform/goose/build.sh
cargo build --release --locked --manifest-path experiments/02-logxform/rust-arena/Cargo.toml
cargo build --release --locked --manifest-path experiments/02-logxform/rust-idiomatic/Cargo.toml
REF=1 experiments/02-logxform/check-sums.sh S M
experiments/02-logxform/run.sh S M            # experiments/02-logxform/results/<timestamp>/
experiments/02-logxform/flags/build.sh && experiments/02-logxform/flags/measure.sh   # build-flag row
```

Expected: every checksum line says `ok`, and every summary row ends in `yes`. Committed results are in
`bench/results/` (Phase 1, referenced from its report) and `experiments/02-logxform/data/`.

## Known limitations

- **Cold cache.** Phase 1 measured it only in CI, since the reference machine has no passwordless sudo.
  Experiment 2 didn't measure it at all; its input is read once, sequentially, identically by everyone.
- **Noisy machines.** The reference machine is a desktop: i5-8400T, 6 cores, `powersave` governor, a load
  average of 1.8–4 from desktop apps, and 2–6 GB of free RAM. Experiment 2's harness puts all
  implementations in one hyperfine invocation and interleaves RSS runs. *Correction:* one invocation doesn't spread timing drift, since hyperfine finishes one command's runs before the next. Experiments 3–6 use `measure.py`, which randomizes order in each round. CI runners are
  shared VMs: compare only within one run. No result comes from a dedicated quiet machine.
- **Code-layout sensitivity.** rust-arena's single-thread time moves ±5–7% across rebuilds that change only
  a string. Experiment 2 reports a spread over three neutral rebuilds of each implementation.
- **The macOS allocator effect.** On the macOS CI VM, the malloc-based programs show much higher peak RSS
  than on Linux (rust-arena 1.9× Goose, rust-idiomatic 5.2× its Linux value), while Goose's RSS is the same
  on both. Phase 1 saw a similar macOS-only gap in build RAM. Neither was investigated. Per the
  pre-registration, macOS doesn't decide.
- **Phase 1's criterion refinement.** The kill criterion said "memory"; the target table meant build RAM.
  Serving memory became the primary metric mid-experiment. The report gives both readings: build RAM is at
  parity on Linux and 1.28–1.50× better for Goose on the macOS VM; serving memory is 2.0–3.1× worse for
  Goose everywhere. The verdict rests on the refined reading.
- **Experiment 2's amendment A1.** After the audit, rust-arena's records changed from fat pointers in
  `bumpalo` to u32 spans in reused `Vec`s. Both readings fail the criterion (RSS ratio 1.21 before, 1.07
  after).
- **One author.** Every implementation was written by the same agent in minutes, so "development time" is
  agent effort, not human hours. Goose expertise is limited to its docs and samples; a Goose expert might
  write faster Goose.
- **Goose v2026.3 only,** built with clang 21. No other version or C compiler was compared.
- **Local compiler patches.** Experiments 3, 5 and 6 use Goose patches kept on local branches. Those results can't be reproduced from this repository alone. The owner may give a reviewer the patches separately; if you don't have them, say what you couldn't check.
- **Experiments 4 and 5 weren't committed before they ran.** Their specs were written first; that order rests on the session's record.

## Findings from the first review: status

An outside review of v1.2.1 raised these. They're listed so that you can check them, and so that what's still open is plain.

| Finding | Status |
|---|---|
| hyperfine doesn't interleave runs, so implementation and time are confounded | Fixed from experiment 3 on (`measure.py`). Experiment 2's own numbers still have it |
| "Code-layout effect" isn't isolated: one binary varies 6.37–8.00 s | Partly: neutral rebuilds and within-binary spread are reported. Noise from the machine remains, and no run is on a quiet dedicated machine |
| "Scans twice" was wrong for `json::format_string` | Fixed: corrected, and F2 is a different fix |
| Zero-copy forecast was too confident, given the 33.5 ms validation pass | Confirmed: the view target was missed, and the pass remains on layout A |
| **"Serving memory" is a startup peak (load plus one query), not what a server retains** | **Open.** No steady-state measurement exists |
| **Implementations filter before keeping records, while experiment 2's SPEC requires building every record first** | **Open.** Confirmed in both Goose (`logxform.goose`, `process`) and rust-arena (`main.rs`, line 524). Both deviate alike, and about 41% of lines are dropped. Relative bias unknown |
| **`bench/SPEC.md` rejects `async class`; `bench/ref.py` and the implementations accept it** | **Open.** Checksums agree, because they share the behaviour |
| **Corpus is narrow: HDFS is about 95% of experiment 2's bytes, and L repeats M** | **Open.** No result breaks down by format |
| **`io.c` writes at the data stack top without a reservation check** | **Open, reasoned about only.** Same pattern as the runtime's `gs_bld_append`, relying on the guard gap. `from_file` and `read_file_range` rely on it too |
| **rust-expert's mmap assumes the file doesn't change** | **Open, by design.** The Goose loaders don't assume this, an untested advantage |
| Phase 1 changed its primary metric mid-experiment | Disclosed; nothing further |
| The jump from "this test failed" to "these products are falsified" | Addressed: `docs/GOOSE_OPPORTUNITIES.md` has a note, and the report separates the two |
| Build-order: product first, not language features first | Partly adopted: the tools were measured before compiler work, but no user or customer has been consulted |

## Questions for the second review

Report findings with file and line, the direction of any bias, an impact estimate and a concrete fix. Separate what you verified from what you infer, and say what you couldn't check.

1. **Are the results sound?** Do the tables in the report follow from `experiments/*/data/`? Is `measure.py` correct? What should we distrust because of noise, few rounds, or one machine?
2. **Is the comparison with Fluent Bit and Vector fair?** Look at `experiments/04-vs-tools/`: configs, one process per file, the sinks, `/dev/null`, a Lua filter where a native one might exist. A specialist in either tool may see what the author can't. How much of 20× and 42× would survive? Was the "clear win" rule well set?
3. **Are the interpretations right?** Is "parity to a small lead" the honest reading of Goose against tuned Rust? Is "most of the win comes from specialization" right? Is any claim stronger than its evidence, or weaker? Why might F2 help Goose (11–13%) more than Rust (6–7%)?
4. **The hard question: why Goose at all?** Tuned Rust is about level on one core and much faster on six, with far larger ecosystems. What could justify building these products on Goose, given that a fixed-purpose Rust tool gets the same win? What evidence would settle it, and is the project collecting it?
5. **Is the plan right?** Consider the order (the six-core gap, embedding, a Fluent Bit plugin), the choice of a log parser as the first product, and the targets and kill rules. Which step should be cut or moved up? What's missing? Is a private compiler fork survivable?
6. **The proposed design** in `experiments/06-parallelism/PLAN.md`: workers read their own input. Will it close the gap? Is the 1.6–2.0 s estimate reasonable? Is ownership transfer the better route, and is anything simpler being missed? What's the explanation for workers' `process` time growing with threads?
7. **If you've been given the compiler patches:** are `from_file`, in-place assignment and `json::plain` sound? Consider aliasing, failure paths, the guard-gap reliance, and overflow in `plain`.
8. **Cheapest next experiment.** What single measurement would most change the project's decisions?

## Questions for the auditor (first review)
1. **Methodology flaws.** Do the harnesses measure what the reports claim: whole-process time, peak RSS and
   checksums? Is anything exec'd inside a timed command? Are warm-up and cache state handled correctly? Is
   the ambiguity rule in experiment 2's SPEC sound, and was it applied as written?
2. **Unfair comparisons.** Is any implementation handicapped or advantaged? Look at allocation patterns,
   I/O, parsing work, threads, build flags, and the libraries allowed (`memchr` against Goose's
   `find_any`). Is amendment A1 legitimate, or post-hoc strengthening of the competitor? Was Phase 1's
   switch from build RAM to serving memory justified?
3. **Untested Goose strengths.** Which strengths weren't measured?
   - development cost and safety, such as the validating loader and having no lifetimes;
   - deep trees and other recursive variable-size data;
   - workloads where `malloc` fragmentation dominates;
   - the macOS RSS behaviour.

   Would any of these plausibly reverse a verdict?
4. **Phase 2 risks.** [docs/PHASE2.md](docs/PHASE2.md) plans an instant-start code index in Rust on
   rust-expert's design. What would make that a mistake? And would the improvement plan, if it succeeds,
   change the language choice?
5. **Next steps.** Is the improvement plan's order right: profiling, then contacting upstream, then the
   zero-copy view, embedding, parallelism? Are its targets and kill criteria well-chosen? What is the
   cheapest experiment that would most change our conclusions?

Please report findings with file and line, the direction of any bias, an impact estimate, and a concrete
fix, as the experiment 2 audit did (its REPORT, "Fairness audit").
