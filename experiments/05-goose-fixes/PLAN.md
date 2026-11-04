# Experiment 5: cheap Goose fixes for single-thread speed

Pre-registered 2026-11-04 before these fixes were built or measured (step 2 of the product plan). Compiler branch
`step2-fixes` in `toolchain/goose-src`, from `patch2-from-file`; local only. The target and kill rule are
gap 4's in [docs/GOOSE_IMPROVEMENT_PLAN.md](../../docs/GOOSE_IMPROVEMENT_PLAN.md), written before this work.

## Correction to the earlier diagnosis

Experiment 2's report says `json::format_string` "scans each string twice", and that this costs the +0.13 s in
rendering. That's wrong, as an outside audit pointed out. Goose's `plain` then `append` is one scan and one
copy, and rust-arena's `put_str` is the same: a byte-by-byte scan, then `extend_from_slice`. So there's no double
scan to remove, and the rendering gap's cause is unknown. F2 below is a different idea, and could beat Rust's scan.

## Fixes

- **F1, `find_any` on a single byte goes to `memchr`.** A check in `gs_find_any`, which is in each program's own
  translation unit, so it can inline. glibc dispatches `memchr` to AVX2 on this CPU. Profile: the newline scan costs
  +0.06 s of 7.27 s (0.8%).
- **F2, `json::plain` without an early exit.** Both sides scan with a byte loop that returns at the first escape, which
  compilers can't vectorize. A loop that ORs the checks can be vectorized. Strings needing escapes get slower, but they
  are rare. Profile: rendering costs +0.13 s (1.8%), with no known cause.
- **F3, in-place `a, n, ok = from_file(...)`.** Assigning to an existing resizable now reads straight into it, instead of
  building a temporary and copying it. Arguments are evaluated first, so `x, n, ok = from_file(p, x.len)` still sees the old
  length. This doesn't affect logxform. It's for experiment 3's layout A, which can't avoid a pinned global.

## Measurement

**logxform, M corpus, `-t 1`, one core, base configuration:** base, F1, F2, F1+F2 and rust-arena, three neutral rebuilds
of each (only the usage string differs, as in experiment 2's layout check), `measure.py`'s random-order rounds: each
command once for wall time, once under GNU time. Output checked against `ref-checksums.txt` on S and M.

**symidx layout A, F3:** patch 2 with and without F3, against rust-expert, as in experiment 3's round 2. Checksums
against `bench/ref-checksums.txt`, `patch2/corrupt.py`, and `test_from_file` plus new aliasing cases.

Goose's own `test/run_tests.py` on the patched compiler, compared with base.

## Targets

- **Gap 4 target:** F1+F2 at least 1.0× rust-arena's single-thread throughput, median over the three rebuilds.
- **Gap 4 kill:** below 0.95× after these fixes. Then stop there: a compiler change wouldn't be justified by what's left.
- Between 0.95× and 1.0× is neither: report it, and it doesn't block the product.
- **F3:** layout A's L serving RSS at most 60 MB (from 80 MB; one groups copy is about 30 MB, minus what remains), byte-identical
  output, no new test failures.

The profile suggests about 7% at most in total, and these two fixes address about 2.6% of that directly.

## Fairness check on F2 (added after the first results, before this measurement)

The first run has F1+F2 at about 1.12× rust-arena, almost all from F2. F2 isn't specific to Goose: rust-arena's `put_str` has the same
early-exit scan, and the same integer-arithmetic loop would vectorize there too. So **rust-arena-fair** adds that loop
as a check before its existing code, and nothing else. The gap 4 target stays judged against rust-arena as registered, but the honest
comparison is against rust-arena-fair, and the report gives both. Same method: three neutral rebuilds of each, 5 rounds,
`-t 1` on M, plus 3 rounds at `-t 6`. Output checked against the reference on S and the edge corpus.

## Results (added after measuring)

*Units: in this document's tables, "MB" of RSS is KiB ÷ 1000, a slip. Divide by 1.024 for this repo's MB (1024² bytes), as the [report](../../docs/GOOSE_LOGXFORM_REPORT.md) does. Ratios aren't affected.*

**logxform, M, `-t 1`, one core, three neutral rebuilds of each, 5 rounds.** Raw: `data/`. Throughput is from the median of
the rebuilds' medians. Output matches the reference on S, M (F1, F2, F1+F2) and the edge corpus, at 1 and 4 threads.

| First run (load average 2–3) | Throughput | Peak RSS | Against rust-arena |
|---|---|---|---|
| base | 235.7 MB/s | 36.0 MiB | 0.995× |
| F1 | 233.6 MB/s | 36.0 MiB | 0.986× |
| F2 | 262.7 MB/s | 36.0 MiB | 1.109× |
| F1+F2 | 265.7 MB/s | 36.0 MiB | **1.122×** |
| rust-arena | 236.9 MB/s | 38.4 MiB | — |

| Fairness run (load average up to 9.6) | Throughput | Peak RSS |
|---|---|---|
| F1+F2 | 231.4 MB/s | 36.0 MiB |
| rust-arena-fair | 222.8 MB/s | 38.5 MiB |
| rust-arena | 210.7 MB/s | 38.3 MiB |

In that run, F1+F2 ÷ rust-arena is 1.098 and F1+F2 ÷ rust-arena-fair is **1.039**, by round 1.018, 1.036, 1.028, 0.967, 1.045.
rust-arena-fair ÷ rust-arena is 1.057. All three were affected by the load; the ratios are paired, but one round is
below 1, so this run doesn't separate F1+F2 from rust-arena-fair with any confidence.

**Verdicts.**
- **Gap 4 target (≥ 1.0× rust-arena): met**, 1.12× and 1.10×. Not killed.
- **With Rust given the same scan: about 1.04×, on a loaded machine.** That's parity to a small lead, not a demonstrated win.
- **Diagnosis.** F2 gave far more than the 2.6% the profile implied for F1 and F2. F1 had no measurable effect, so the newline scan
  wasn't the cost the profile suggested. Goose gained more from F2 (about 11%) than Rust did (about 6%), not explained here.
- `plain`'s rewrite: `test_plain.goose` checks all 256 byte values in all positions of lengths 0–80 (829,521 strings) in
  release and `--debug` builds.

**`-t 6`, 3 rounds, on the loaded machine: inconclusive.** F1+F2 417.8 MB/s and base 452.5 MB/s, against rust-arena 761.6
and rust-arena-fair 823.1. F1+F2 stays at about 0.5×, which is the queue-copy gap, step 4's subject.

**symidx layout A, F3, 30 and 20 rounds, against rust-expert.**

| | base | patch 2 | patch 2 + F3 | rust-expert |
|---|---|---|---|---|
| load M | 12.09 ms | 9.57 ms | 6.74 ms | 1.35 ms |
| `find Model` RSS M | 11.6 MB | 8.6 MB | 5.9 MB (1.36×) | 4.3 MB |
| load L | 142.8 ms | 100.9 ms | 79.4 ms (12.4×) | 6.4 ms |
| `find Model` RSS L | 118.9 MB | 80.4 MB | 51.0 MB (1.16×) | 44.1 MB |

**F3 target (L serving RSS ≤ 60 MB): met.** With it, layout A also meets all of patch 2's targets: L load under 90 ms, RSS ≤ 1.6× on M and
≤ 1.9× on L. Layout A keeps Goose's image advantage (39.3 MB against 43.9 MB), which `fixed` gave up. The improvement plan's gap 1
stretch (≤ 1.2× RSS, ≤ 2× load on M and L) still isn't met. Output matches the reference on S, M and L, 428 corrupted images give no
crash or disagreement, and `test_from_file` passes, with new aliasing cases, in release and `--debug`.

Goose's own test suite on `step2-fixes`: same section totals as base, including the same 31 failures, which also occur on the
unmodified compiler.

## Consolidated run (added after measuring)

`consolidated.sh`, one session, `data/consolidated/`, load in `load.txt`. CPU time recorded from here on. Summarized in [docs/GOOSE_LOGXFORM_REPORT.md](../../docs/GOOSE_LOGXFORM_REPORT.md).

- **`-t 1`, three rebuilds, 5 rounds, load average about 3.5–4.5:** F1+F2 240.1 MB/s, rust-arena-fair 233.2, rust-arena 218.7. F1+F2 ÷ rust-arena-fair **1.029** (1.023–1.035 by round), ÷ rust-arena **1.098**. This supersedes the noisy fairness run above.
- **`-t 6`, three rebuilds, 3 rounds, load up to 9.7:** F1+F2 490.8 MB/s, base 468.6, rust-arena 859.1, rust-arena-fair 828.4. F1+F2 ÷ rust-arena 0.57.
- **All six programs, one process per file, 3 rounds:** see the report. In this harness F1+F2 ÷ rust-arena-fair is 0.99, with rounds from 0.82 to 1.04. The all-cores stage was disturbed.

## After the independent review (added 2026-11-04)

**F3 had a miscompilation** ([review](../../Symidx_Audit_04-11-2026.md), finding 1). A `from_file` nested in another's arguments took its parent's pending reset, giving wrong data reported as success. It's fixed, and it applied only to plain variables after I restored a check I had dropped while debugging. `check_f3.sh` compares each program built with and without F3 at `-O0`, `-O1`, `-O2` and `--debug`, and `test_f3_differential.goose` fails in two cases on the old code. So the F3 row above came from an unsound patch.

**Re-measured on the fixed compiler** (`data/f3-fixed/`, load average about 10, so its timings are noisy): L serving RSS is 50,954 KiB, unchanged. Load on L is 87.7 ms there, against 79.4 ms in the earlier, quieter run. Output matches on S, M and L, and 428 corrupted images give no crash or disagreement.

**Goose's test suite, compared by failing test name** (`compare_tests.py`): base and fixed compiler are identical, with 4,647 passing and 1 failing. That one clears `GOOSE_STDLIB`, and an out-of-tree compiler can't find the standard library (upstream's #209). The 31 failures reported above came from running without that variable set, so the earlier "environmental" reading turned out right, but it had been presumed. Native-toolchain tests are skipped (`cmake` isn't on the path), and 27 JIT tests are skipped by the suite itself.

**Compiler work is now paused.**

