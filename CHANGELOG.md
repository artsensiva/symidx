# Changelog

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
