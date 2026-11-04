# Changelog

## Unreleased (2026-11-04)

Goose patches, a comparison with the real tools, a new product goal, and an independent review. See [docs/GOOSE_LOGXFORM_REPORT.md](docs/GOOSE_LOGXFORM_REPORT.md).

- **Pilot, sessions 1 and 2:** logXform of Goose, Rust, Python, Fluent Bit and Vector, end to end on the same workflow, with [results](experiments/07-pilot/RESULTS.md), [build notes](experiments/07-pilot/BUILD.md), and the Fluent Bit and Vector pipelines. Rust is about 2–3% faster on HDFS, and session 2's larger wall-time gap is mostly run order. The change request and delivery checks are still to come.
- **Pilot change request:** a new format and hex redaction in all five programs, [measured](experiments/07-pilot/RESULTS.md). logXform of Goose didn't beat Rust on change effort, and the scan cost it 31% on HDFS against Rust's 6%. A follow-up using Goose's own `find_pair` cut Goose's cost to 9%, but the registered result stands.
- **Pilot safety section, most of it:** 20,000 malformed-input cases with no differences from the reference. Sanitizers clean, except by-design misaligned accesses in Goose's generated C. Redaction misses IPs inside SSH host names. Goose stops with an error when input fills its 2 GiB data stack, and Rust doesn't.
- **Planned** [experiment 8](experiments/08-pipebench/PLAN.md), a third-party benchmark, and added a report-only operational safety section to the pilot (SPEC, A5).
- **Renamed** our log processor from "Goose logxform" to "logXform of Goose". File names, CSV labels, the verbatim reviews and experiment 4's frozen SPEC keep their old wording.
- **Fixed** a miscompilation in local patch F3, found by the [independent review](Symidx_Audit_04-11-2026.md), with a differential regression test.
- **Corrected** overclaims the review found: "the product goes ahead", experiment 6's causal diagnosis and its 79% and 26% figures, the cold-cache claim, and the view's status.
- **Made checks fail closed:** scripts stop on failure; `check.py` is strict and tested; Goose's suite is compared by failing test name; tools are checked on the edge corpus, S and M; `measure.py` records order, timestamps, load and hashes.
- **Added** a native Fluent Bit configuration, per-format results and ceilings. Among Fluent Bit's own configurations, native parsing (10.5 MB/s) is slower than Lua (13.5 MB/s), and logXform of Goose (215 MB/s) stays far ahead of both.
- **Upstream:** goose#177 is fixed on master and closed; goose#221 got a first analysis and a reply.
- **Added** the three reviews, verbatim, and the [pilot's spec](experiments/07-pilot/SPEC.md), committed before any pilot code. Compiler work is paused.

- **Added** the report, and experiments 3 (`from_file`, huge pages, index layouts), 4 (logXform of Goose against Fluent Bit and Vector) and 5 (single-thread fixes,
  fairness check, consolidated run), with their data.
- **Results:** on one core, about 20× Fluent Bit and 42× Vector, with less CPU and memory; 1.10× tuned Rust, 1.03× with Rust given the same scan; 0.62× at six threads. The index's L memory is 1.16× rust-expert's, from 2.7×.
- **Compiler patches stay local** (`toolchain/goose-src`, gitignored): results needing them can't yet be reproduced from this repository.
- **Fixed** `measure.py`'s peak RSS, which had a floor at the Python process's own 13 MB; it now also records CPU time.
- **Corrected** the claim that `json::format_string` scans twice, in experiment 2's report, the improvement plan and the README.
- **Added** experiment 6: six threads stall at 0.62× tuned Rust, with candidate causes and a proposed fix, on hold.
- **Updated** `AUDIT.md` for a new outside review, including findings from the previous one that are still open.
- **Upstream:** a comment on [goose#63](https://github.com/aardappel/goose/issues/63#issuecomment-6620530555) about threads and failed checks in hosts.

## v1.2.1 (2026-11-03)

Audit preparation and the first step of the Goose improvement track. No verdict changes.

- **Added** `AUDIT.md`, a brief for an independent auditor: scope, both experiments, reproducing from a
  clean checkout, known limitations, and questions.
- **Added** `CLAIMS.md`: every headline claim in the README and both reports, with its evidence. It flags
  two soft spots:
  - "10–25× slower load" is 9.4–9.5× on local M;
  - the `serde_bytes` 40 → 13 ms figure comes from the development log, not a recorded result.
- **Added** to experiment 2:
  - a build-flag row (`flags/`; -O3/-march=native, LTO, PGO; best against best 0.96×);
  - a phase-timed profile of the single-thread gap (parsing, rendering, newline scan; record copies cost
    nothing extra).
- **Added** `docs/GOOSE_IMPROVEMENT_PLAN.md`: four gaps with root causes, evidence, effort, benchmarks,
  pre-registered targets and kill criteria, and the order of work.
- **Added** `spike/COMMENT_221.md`, a draft comment for goose#221 offering to prototype a verified view.
  Not posted.
- The release carries a repomix bundle of the repository (no corpora, toolchain or results) and `AUDIT.md`.

## v1.2 (2026-11-03)

Experiment 2, logxform. **Verdict: kill criterion not met; the Goose track ends.**

- **Added** `experiments/02-logxform/`, a pre-registered test of the top two candidates in
  `docs/GOOSE_OPPORTUNITIES.md`:
  - `SPEC.md`: the task, corpus, metrics, fairness rules and kill criterion, committed before any code,
    plus one amendment after the audit (A1);
  - a sha256-pinned Loghub corpus (`corpus/fetch.sh`), a Python reference, recorded checksums, and an
    edge-case corpus;
  - three implementations: `goose/`, `rust-arena/` and `rust-idiomatic/`;
  - `run.sh` and `check-sums.sh`;
  - `REPORT.md`, with results, the fairness audit and the verdict, and committed `data/`.
- **Result** (M, after the audit): Goose reached 0.88× rust-arena's single-thread throughput and used
  1.07× less peak RSS; the criterion needed ≥ 1.3×. CI Linux agrees. On the macOS CI VM, Goose used 1.9×
  less RSS (open item).
- **Changed** `docs/GOOSE_OPPORTUNITIES.md`: candidates 1 and 2 are falsified, and 4 and 7 lose their main
  argument. README, DEVLOG.
- **CI:**
  - actions on Node 24 (checkout v7, cache v6, upload-artifact v7);
  - runners pinned to `ubuntu-24.04` and `macos-26`;
  - logxform checksums on S and M, and a short M benchmark.

## v1.1 (2026-11-03)

Documentation release. No code, harness or benchmark changes: every number is the same as in v1.0.

- **Added** `docs/GOOSE_OPPORTUNITIES.md`, an evidence-based analysis of where Goose could be a strong fit:
  - 11 candidates, each scored on fit, win, commercial viability and adoption risk;
  - each one scored against the best Rust, with a 1–2 day falsification test and cited sources;
  - three are strong: request-scoped API/RPC transform kernels, log and telemetry parsing, and memory-safe
    parsers shipped as C;
  - a ranked table, the recommended first experiment, and the poor fits.
- **Added** a CI status badge and this changelog.
- **Changed** the README, which now covers:
  - the hypothesis and how it was refined;
  - methodology: corpora, fairness and validation rules, environments;
  - results for local Linux, CI Linux and CI macOS, warm and cold;
  - lessons learned, reproducing from a clean checkout, project structure, upstream contributions, and
    "Where Goose could fit".
- **Changed** `.gitignore` to cover every spike binary (`goose build x.goose` writes `./x`) and every image file.
- **Changed** the status lines in CLAUDE.md and REPORT.md, which now point to the opportunity analysis.

## v1.0 (2026-11-03)

Phase 1 complete. **Verdict: Rust.** Goose's serving memory is 2.0–3.1× worse than rust-expert's on every
platform measured, warm and cold. Load is 10–25× slower warm and 1–2× slower cold.

- **Three implementations** with byte-identical output: `goose/`, `rust-idiomatic/` and `rust-expert/`
  (streaming, plus the batch first version).
- **Harness and checks:**
  - `bench/run.sh`, plus the ctags/readtags and SQLite baselines;
  - `bench/check-sums.sh` against the recorded `bench/ref-checksums.txt`;
  - `bench/check-machine.sh`;
  - an `env.txt` with every result;
  - `PIN=` core pinning, `COLD=1` on Linux (`drop_caches`) and macOS (`purge`), and `OUT=`.
- **Portability:** Linux and macOS (Apple Silicon); a sha256-pinned Goose toolchain fetch.
- **CI:** builds, checksums on S and M, and warm and cold benchmarks on ubuntu-latest and macos-latest.
- **Report** (`bench/REPORT.md`):
  - the verdict, with a criterion-refinement note giving the literal (build RAM) and refined (serving
    memory) readings side by side;
  - cross-platform and cold-cache confirmation;
  - the segmented-validation experiment;
  - the open item, macOS build RAM.
- **Upstream:** goose#177 (bug, `from_bytes` with `append`) and goose#221 (a verified zero-copy view, a feature request).
- **Fixed in the harness** before release:
  - hyperfine 2.x JSON exports were not read, which left columns empty;
  - `COLD=1` never ran on Linux, because hyperfine 1.x with `-N` runs `--prepare` without a shell;
  - env probes broke under `pipefail`;
  - an `env` exec sat inside timed builds.

## v0.1-experiment (2026-11-01)

The state of the first report: the kill criterion was triggered and the recommendation was Rust, on one
Linux machine with a warm cache.
