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
| E13 | Candidates 1 and 2 of the opportunity analysis are falsified; 4 and 7 lose their main argument | docs/GOOSE_OPPORTUNITIES.md "Outcome"; README | follows from E2–E5 and the shared mechanism argument in GOOSE_OPPORTUNITIES §5 |
