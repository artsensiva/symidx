# Independent audit brief

For an outside reviewer of this repository. Written 2026-11-03 at v1.2.1. Every headline number is
traced to its source in [CLAIMS.md](CLAIMS.md).

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
  implementations in one hyperfine invocation and interleaves RSS runs, to spread drift. CI runners are
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
- **Local compiler patches.** Experiments 3 and 5 use Goose patches kept on local branches. Those results can't be reproduced from this repository alone, and the patches themselves can't be audited until they're published.
- **Experiments 4 and 5 weren't committed before they ran.** Their specs were written first; that order rests on the session's record.

## Questions for the auditor

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
