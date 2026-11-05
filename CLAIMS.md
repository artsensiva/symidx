# Claims and their evidence

Every headline claim in [README.md](README.md), [bench/REPORT.md](bench/REPORT.md) (Phase 1) and
[experiments/02-logxform/REPORT.md](experiments/02-logxform/REPORT.md) (experiment 2), with where it's stated
and what supports it. MB of RAM = 1024² bytes; MB of image or input = 10⁶ bytes. "Local" is the reference
machine (i5-8400T, 6 cores, `powersave`). Raw data: Phase 1 in `bench/results/20261101-132456/`,
`bench/results/local-warm-final/` and the linked CI runs; experiment 2 in `experiments/02-logxform/data/`.

## Phase 1: symidx

| # | Claim | Stated in | Evidence |
|---|---|---|---|
| P1 | Verdict: build the large project in Rust | README TL;DR; REPORT "Verdict" | follows from P2 and P3, against the kill criterion "no ≥ 1.3× memory win over rust-expert" |
| P2 | Goose's serving memory is 2.0–3.1× worse than rust-expert's on every platform, warm and cold | README TL;DR, "Hypothesis"; REPORT "Verdict", "Cross-platform and cold-cache confirmation" | selective serving RSS, Goose / rust-expert: local M 11.4 / 5.6 MB (2.0×); L 116 / 44 MB (2.6×); CI Linux warm 11.3 / 5.6 (2.0×), cold 11.3 / 4.1 (2.7×); CI macOS 10.6 / 3.5 (3.1×). Full-index serving: M 12.3 / 6.7 (1.8×), L 122 / 45 (2.7×) |
| P3 | Goose loads 10–25× slower warm, 1–2× cold | README TL;DR; REPORT "Verdict" | load, Goose / rust-expert: local M 12.2 / 1.3 ms (9.4×; 9.5× in the re-run), L 134 / 5.3 ms (25×); CI Linux warm 10.8 / 1.0 (10.5×), cold 18.4 / 9.3 (2.0×); CI macOS warm 9.4 / 2.9 (3.3×), cold 121.8 / 119.7 (parity) |
| P4 | The reason is that `from_bytes` copies the image; rkyv maps it | README TL;DR, "Lessons"; REPORT "What belongs to Goose" | load profile (REPORT "Goose load"; `spike/FINDINGS.md`): on M, `read_file` 2.2 ms + `from_bytes` 5.8 ms (half of it page faults) + validation 2.0 ms; L `read_file` alone 27 ms, against rust-expert's 5.3 ms total |
| P5 | Literal reading (build RAM): parity on Linux; met on the macOS VM in 3 of 4 runs, low confidence | README "Hypothesis"; REPORT "Criterion refinement" | build RAM, Goose / rust-expert: M 14.6 / 14.1 MB, L 111 / 106 MB (local); macOS CI rust-expert 17.9–20.8 MB vs Goose 13.9 MB on M (1.28–1.50×) over four runs |
| P6 | Goose's image is 1.12–1.20× smaller than rust-expert's | README "Lessons"; REPORT "Verdict" | M 3.00 / 3.62 MB (1.20×), L 39.3 / 43.9 MB (1.12×) |
| P7 | The compact layout gives 5–15× smaller indexes than ctags | README TL;DR, "Market baselines" | rust-expert vs ctags: M 3.62 vs 20.1 MB (5.6×), L 43.9 vs 652 MB (14.9×) (`bench/results/baselines-20261101-132720/`) |
| P8 | …10–17× faster builds than ctags | same | M 74 ms vs 1.23 s (16.6×), L 4.84 vs 51.8 s (10.7×) |
| P9 | …with lookups as fast or faster | same | selective `Model` query: M 1.3 vs 1.3 ms, L 5.9 vs 13.8 ms (readtags) |
| P10 | Fairness audits reversed results: an early "2.9× less build RAM" for Goose disappeared | README "Lessons"; REPORT "What belongs to Goose" | rust-expert batch vs streaming build RAM: M 26.8 → 14.1 MB, L 388 → 106 MB (results table, rust-expert-batch rows) |
| P11 | rust-idiomatic's M load fell from about 40 to 13 ms with `serde_bytes` | README "Lessons" | DEVLOG, 2026-11-01 "rust-idiomatic v1". The 40 ms version wasn't kept as a result row; the final run's figure is 18.6 ms |
| P12 | Segmented validation cuts rust-expert's L selective RSS 3.5× | REPORT "Experiment: segmented validation" | L `find Model`: 43.3 → 12.4 MB, 9.8 → 2.9 ms; not SPEC-conforming, so an experiment only |
| P13 | A 384-line port, written in about 20 minutes, found goose#177 | README "Lessons"; REPORT "Development time" | DEVLOG Goose rows (11 + 3 + 6 minutes); `spike/bug_from_bytes_append*.goose`; https://github.com/aardappel/goose/issues/177 |
| P14 | Against rust-idiomatic, Goose meets most targets on M | REPORT "Results" | 2.0× less build RAM (14.6 vs 29.5 MB), 1.6× smaller image (3.00 vs 4.82 MB), 1.5× faster load (12.2 vs 18.6 ms) |

Note on P11: the claim rests on a development-log observation, not a recorded benchmark row.

## Experiment 2: logxform

| # | Claim | Stated in | Evidence |
|---|---|---|---|
| E1 | The SPEC was pre-registered before any implementation | REPORT header; README; AUDIT | `git log`: SPEC commit `6280357` at 17:35, the first implementation (`9423aaf`) at 17:41, pushed before it |
| E2 | Kill criterion not met: 0.88× single-thread throughput, 1.07× peak RSS (M, local, after the audit) | README TL;DR; REPORT "Verdict" | `data/local-post/summary.csv`: goose 216.2 MB/s and 36,888 KiB; rust-arena 246.5 MB/s and 39,288 KiB (RUNS=10, median of 3 for RSS) |
| E3 | Not ambiguous: far from the 1.25–1.35 band, and CI Linux agrees | REPORT "Verdict" | `data/ci-41694111883-ubuntu-24.04/summary.csv`: 413.7 / 445.2 MB/s (0.93), 39,164 / 36,616 KiB (1.07) |
| E4 | Before the audit (rust-arena v1) the verdict is the same | REPORT "Verdict", "Results" | `data/local-pre/summary.csv` (binaries from `318650e`): 226.0 / 252.4 MB/s (0.90), 44,352 / 36,708 KiB (1.21) |
| E5 | The code-layout spread doesn't change it | REPORT "Results" | `data/local-layout/`: Goose 7.24–7.34 s, rust-arena 6.81–7.43 s over three neutral rebuilds each; throughput ratio 0.93–1.03; RSS 36.7–36.8 vs 39.0–39.1 MB |
| E6 | Goose beat rust-idiomatic 2.2× in throughput and 2.7× in RSS | README; REPORT "Verdict" | `data/local-post/summary.csv`: 216.2 vs 100.4 MB/s; 36,888 vs 100,540 KiB |
| E7 | On the macOS CI VM, Goose used 1.9× less RSS (uninvestigated) | README; REPORT "Verdict", "Open items" | `data/ci-41694111883-macos-26/summary.csv`: 35,888 vs 68,576 KiB; rust-idiomatic 546,672 KiB against 105,704 on CI Linux (5.2×) |
| E8 | Streaming works: L's RSS stays at M's | REPORT "Results" | `data/local-post-L/summary.csv`: goose 36,700, rust-arena 39,272 KiB (M: 36,888, 39,288) |
| E9 | rust-arena scales better with threads: 4.7× against 3.0× at 6 threads | REPORT "Results" | `data/local-post/summary.csv` M: rust-arena 1168.2 / 246.5; goose 655.5 / 216.2 |
| E10 | The audit's record-layout fix moved rust-arena's RSS 43.3 → 38.4 MB | REPORT "Results", "Fairness audit" | `data/local-pre` 44,352 KiB vs `data/local-post` 39,288 KiB |
| E11 | All three implementations match the reference on S, M, L and the edge corpus, at 1 and 4 threads, locally and in CI | REPORT "What was tested" | `check-sums.sh` output; CI runs 41694111883 and 41699929723 (the "logxform checksums" steps); `ref-checksums.txt` |
| E12 | Build flags (-O3/-march=native, LTO, PGO) don't change the verdict | REPORT "Amendment row: build flags" | `data/flags/summary.csv`: Goose ÷ rust-arena 1.00 (base), 0.88 (native), 0.85 (+LTO), 1.01 (+PGO); best against best 0.96 |
| E13 | Candidates 1 and 2 of the opportunity analysis are falsified; 4 and 7 lose their main argument (only as "≥ 1.3× over tuned Rust"; see G1–G6) | docs/GOOSE_OPPORTUNITIES.md "Outcome"; README | follows from E2–E5 and the shared mechanism argument in GOOSE_OPPORTUNITIES §5 |

## Experiments 3–5 and docs/GOOSE_LOGXFORM_REPORT.md

"Consolidated" is `experiments/05-goose-fixes/data/consolidated/`. Results marked † need the local Goose patches, which aren't published.

| # | Claim | Stated in | Evidence |
|---|---|---|---|
| G1 | logXform of Goose on one core is about 20× and 42× Fluent Bit's and Vector's throughput, with a Lua filter and VRL. A native Fluent Bit parser is slower, so this stands against configurations tried; a C or Wasm filter isn't tested † | README; report "Summary" | `all-one-core.csv`: paired medians 19.75× and 41.88×; 251.3, 12.7, 5.9 MB/s. Release Goose in `experiments/04-vs-tools/data/`: 15.9× and 38.9× |
| G2 | …with 19× and 43× less CPU per GB † | same | `all-one-core.csv`: 3.9, 74.0, 173.4 CPU-s per GB; paired 19.18 and 43.46 |
| G3 | …and less memory, 1.10× and 2.67× † | same | `all-one-core.csv`: 36.1, 39.6, 96.2 MiB |
| G4 | Most of that win is from being fixed-purpose, since tuned Rust wins by about as much | report "Analysis" | `all-one-core.csv`: rust-arena 225.3, rust-arena-fair 254.8 MB/s |
| G5 | 1.10× tuned Rust on one core † | README; report | `fair-t1.csv`: 1.098, rounds 1.090–1.109. First run in `data/log-t1.csv`: 1.122 |
| G6 | 1.03× once Rust has the same scan; parity to a small lead † | same | `fair-t1.csv`: 1.029, rounds 1.023–1.035. Per-file harness in `all-one-core.csv`: 0.99, rounds 0.82–1.04 |
| G7 | 0.62× tuned Rust and 1.4× its memory at six threads † | same | `experiments/06-parallelism/data/scaling.csv`: 673 and 1,082 MB/s, 514 and 366 MiB, load average about 1–3. Noisier: `fair-t6.csv`, 0.57× |
| G8 | One library loop gave about 11% † | report "Summary" | `data/log-t1.csv`: base 235.7, F2 262.7 MB/s; rounds 0.884–0.911 in time |
| G9 | `from_file` took the index's L memory to 1.16× rust-expert's, from 2.6–2.7× † | same | `data/sel-L.csv`: base 116.1, patch 2 78.5, F3 49.8, rust-expert 43.0 MiB. F3 miscompiled other programs until fixed; `data/f3-fixed/` re-measures RSS unchanged |
| G10 | `fixed` reaches 1.05× rust-expert's L memory, and load 4.5× † | report "The symbol index" | `experiments/03-goose-patches/data/round2/`: 46.9 and 44.6 MiB; 29.2 and 6.4 ms |
| G11 | Huge pages depend on the task † | report "Analysis" | `experiments/03-goose-patches/PLAN.md` round 2; `data/round2-with-copy/log-t1.csv` |
| G12 | logXform of Goose stops improving at 4 threads; Rust doesn't † | report "Scaling" | `experiments/06-parallelism/data/scaling.csv`: 665 to 673 MB/s from 4 to 6; Rust 903 to 1,082 |
| G13 | The main thread is a credible bottleneck, not established (revised after review) † | report "Analysis" | `experiments/06-parallelism/data/stages.txt`: elapsed stages other than receiving 79% at 6 threads; worker `qget` 26%, including copying. Elapsed time isn't CPU time |
| G14 | Page faults alone don't explain the CPU growth; indirect cache effects aren't isolated † | same | PLAN tables: 255,167 and 93,802 minor faults, 1.05 and 0.54 s sys, 10.37 and 7.44 s user at `-t 6`, single run |
| G15 | Vector matches the reference on the full M corpus; Fluent Bit does except for final lines with no newline | report "How it was tested" | `experiments/04-vs-tools/data/correctness.txt`, by the strict `check.py` |
| G16 | F3's bug is fixed; base and patched compilers fail the same tests by name | report "Changes implemented" | `experiments/05-goose-fixes/check_f3.sh`, `compare_tests.py`, `data/suite-comparison.txt`. Tests, not a proof |
| G17 | A native Fluent Bit config doesn't narrow the gap † | report "Analysis" | `experiments/04-vs-tools/data/native/`: CPU per GB 3.8 (Goose), 71.6 (Lua), 93.2 (native), summing per-format medians; `data/correctness.txt` |
| G18 | Pilot, two sessions, one core: Rust is about 2–3% faster than logXform of Goose on HDFS, as a diagnostic shows; 0.84× as measured in session 2 is mostly run order, and stands as a near miss. Both are at least 6× the best alternative on CPU per GB, per format | [RESULTS](experiments/07-pilot/RESULTS.md) | `experiments/07-pilot/data/session1/`, `session2/`, `wall-check/`, `summarize.py`; correctness in `check_oracle.py` and `data/oracle-*.txt` |

## Experiment 9

Evidence is in `experiments/09-logxform-v2/results/i5-8400t/`. One machine, not independent.

| # | Claim | Where | Evidence |
|---|---|---|---|
| L1 | Goose and Rust servers are close: median throughput within 3% on 10 of 13 tests, no overall winner | report "Goose and Rust" | `round-*/*_performance.logxform-*.json` |
| L2 | Both handle about 5 to 23 times as many lines per core as the better tool; size unconfirmed | report "PipeBench, 3 rounds" and "Why these numbers need care" | `round-*/*_performance.*.json` |
| L3 | Both lose on memory to Vector on `tcp_to_tcp` and `regex_mask`, and to both tools on the two disk tests | report "Peak memory" | same |
| L4 | Two batch marks were missed: 12.9% against 10%, and 0.897× against 0.9× | report "Batch tool marks" | `batch-hdfs.csv`, `batch-bgl.csv`, `batch.log` |
| L5 | In shipped configs Goose and Rust passed 66 of 66 correctness runs, Vector 23 of 33, Fluent Bit 21 of 33; this doesn't show ours are more correct | report "Correctness on the tools" | `round-*/*_correctness.*.json` |
| L6 | Most of Fluent Bit's loss in three failing tests comes from the shipped configs (development runs, 2 samples each) | same | `investigation/outcomes.txt`, `investigation/set1.sh`, `investigation/set2.sh` |
| L7 | Vector's lost lines on `tcp_to_tcp_persistent` never reached a sink (development runs, 2 samples); cause unknown | same | `investigation/outcomes.txt` |
