**Independent second review of symidx — 4 November 2026**

Reviewed project commit `73316a9126f907b44362e705179d3fc545bbae8f` on `main`; local Goose branch `step2-fixes`, commit `e83645c`, based on v2026.3. This report answers the eight second-review questions and the original five-part request.

**Decision**

The research is useful, and its main narrow conclusion survives independent inspection: Goose has not demonstrated a substantial inherent advantage over competent Rust on these workloads. The newer single-thread optimization is real and brings the tested implementations close together. The large advantage over the configured logging tools is a promising specialization result, not evidence that Goose is the better implementation language.

I found a reproducible silent miscompilation in F3, the local in-place `from_file` optimization. It affects release and debug builds while the existing loader tests still pass. Do not distribute F3 as a trusted improvement until this is fixed. This finding does not implicate upstream v2026.3 or invalidate F2's log-processing speedup: F3 is a local compiler change, and logxform does not use it.

My recommendation is to stop the broad “compete with arenas, Protobuf, Vector, Fluent Bit, Wuffs and Rust libraries” program. Those are different markets and contracts. Permit one bounded Goose product trial around one actual user's task. Do not fund a permanent compiler fork on the evidence here.

**Evidence labels and scope**

“Verified” below means source/data inspection or an explicitly identified execution during this review. “Inference” means an explanation consistent with evidence but not isolated experimentally. “Judgment” means my recommendation or engineering estimate.

I read the brief, consolidated report, experiment 6 plan, claims and raw data in the requested order. I saved [provisional findings](./provisional-findings.md) before reopening either earlier review. Earlier conversation had exposed those reviews, so this is not a blinded assessment. The attached Bash snapshot path was unavailable; that did not prevent inspection of the actual checkout.

No repository or toolchain files were changed, no commits or pushes were made, and nothing was posted. Generated sources, compiler cache, binaries and results are in this directory. Final Git status matched the initial status: only the two pre-existing untracked review documents; the Goose checkout remained clean.

I inspected the local compiler changes, rebuilt targeted tests using the supplied compiler, independently recalculated key CSV aggregates, ran 18 interleaved benchmark executions, and checked output hashes. I did not rerun the hour-long tool matrices, the complete compiler suite, the original index benchmarks, CI, macOS, cold-cache tests, or Windows tests. I did not build the proposed experiment 6 design. I did not alter system profiling permissions; `perf_event_paranoid` was 4. The benchmark history's governor setting was not independently available through this session's sysfs.

**1. Experimental audit: findings in priority order**

**Finding 1 — F3 silently changes valid program behavior. Severity: release blocker for the patch.**

Verified by source inspection, generated C and execution. The pending destination reset is stored in compiler-wide mutable fields at [codegen.h:1247](/home/artem/symidx/toolchain/goose-src/src/codegen.h:1247), assigned in [codegen_stmts.h:61](/home/artem/symidx/toolchain/goose-src/src/codegen_stmts.h:61), and consumed by whichever nested loader reaches [codegen_builtins.h:1391](/home/artem/symidx/toolchain/goose-src/src/codegen_builtins.h:1391). Argument generation at lines 1370–1371 can generate another loader first.

The [reproducer](./nested.goose) creates a frame containing `NEW`, initializes the destination to `OLD`, then assigns the frame through `from_file(path, offset())`. The inlined `offset()` itself calls `from_file` and appends `X` to the outer destination before returning zero. The outer assignment should overwrite that intermediate append. Instead:

| Execution | Output |
|---|---|
| Patched compiler, release | `XNE 4 true` |
| Patched compiler, debug | `XNE 4 true` |
| Equivalent control, evaluate `offset()` before the assignment | `NEW 4 true` |

The inner load consumes the outer reset before argument evaluation finishes. The subsequent append changes the top; the outer load writes at the wrong position. The loader reports success. See [debug log](./nested-debug.log), [control log](./control.log), and the generated C in [temporary compiler output](./cache/build/prog/nested-c08cf3b8/nested.c).

**Bias/impact:** the favorable F3 performance numbers concern a compiler transformation that is not semantically sound. This is a correctness problem, not a demonstrated memory-corruption exploit. It does not prove that the benchmark's own outputs were wrong.

**Concrete fix:** make destination/reset state specific to the exact call, capture it before recursively generating arguments, and perform the reset only after those arguments finish. Do not merely save and restore the ambient fields around nested generation: a nested call must never consume its parent's pending reset. Restrict the optimization to explicitly proven assignment shapes; add nested/inlined argument, side-effect, rejected-load and non-inlined differential cases. Until then disable F3 or use the non-in-place loader. I have not implemented a fix.

An initial suspicion about an ordinary declaration followed by an unrelated assignment did not reproduce. Inspection showed that the relevant `results` flag is specifically set by [ParseMultiAssign](/home/artem/symidx/toolchain/goose-src/src/parser.h:1792). That is not a separate finding.

**Finding 2 — the “product goes ahead” conclusion crosses an evidentiary gap. Severity: high strategic impact.**

The [report summary](/home/artem/symidx/docs/GOOSE_LOGXFORM_REPORT.md:12) and [product plan](/home/artem/symidx/docs/GOOSE_LOGXFORM_REPORT.md:248) turn a large win over configured tools into progress toward a product. Yet the same comparison gives almost the same win to specialized Rust. [CLAIMS G4–G6](/home/artem/symidx/CLAIMS.md:57) acknowledges this.

**Verified:** this is a fixed-format batch transformer compared with Fluent Bit using Lua and Vector using VRL and their event/sink infrastructure. It does not supply their operational features. **Inference:** specialization explains much of the difference, but the experiment does not isolate every component's contribution. **Judgment:** the clear-win rule justifies a customer-facing validation experiment; it does not justify a Goose-specific product or compiler program.

**Direction of bias:** favors the custom tool as a replacement for the whole logging product, and favors Goose if the custom Rust result is omitted from the decision.

**Fix:** define the intended deployment and required guarantees first. Compare the complete workflow against the best practical native/configured competitor and the equivalent Rust implementation. Require a measured benefit that survives integration and one realistic maintenance change.

**Finding 3 — experiment 6's causal diagnosis is stronger than its instrumentation. Severity: high for choosing the next engineering task.**

The [decision rule](/home/artem/symidx/experiments/06-parallelism/PLAN.md:25) asks whether main is busy at least 80% of the time. The [conclusion](/home/artem/symidx/experiments/06-parallelism/PLAN.md:70) treats it as established. However, [worker instrumentation](/home/artem/symidx/experiments/06-parallelism/timed/logxform.goose:465) measures elapsed time around `qget`, processing and `qput`; [main instrumentation](/home/artem/symidx/experiments/06-parallelism/timed/logxform.goose:508) does the same around receive.

Elapsed time includes execution, descheduling, locks and blocking. `qget` time includes receiver copying. It is not pure idle time. Summing worker processing intervals does not produce CPU time. Main's send interval can contain blocking, so labeling all non-receive time “busy CPU” is unwarranted. There are six workers plus main on six cores, before desktop activity.

In the first committed six-worker stage run, `qget` intervals sum to 3.677 s over approximately 14.04 worker-wall-seconds, about 26%, not a measured one-third idle fraction. The second is similar. The plan discloses that its displayed stage table came from earlier runs, but the claim table cites the committed repeat as if it directly established the prose. [Recorded stages]( /home/artem/symidx/experiments/06-parallelism/data/stages.txt)

**Verified:** scaling flattens, queue copying exists, total CPU and RSS rise, and main's measured stages are expensive. **Inference:** coordinator work and copy traffic are credible bottlenecks. Cache/bandwidth pressure, reduced all-core clock, scheduler interference and contention remain competing explanations for increased processing intervals.

**Bias/impact:** overconfidence favors the proposed input redesign and an optimistic speed forecast; it could spend weeks on the wrong limiting resource.

**Fix:** collect thread CPU time separately from monotonic wall time, queue occupancy and blocked duration; compare four workers with six; record clocks and scheduling interference where available. Use an ablation or process-sharding control before changing language semantics. User/system CPU accounting suggests page-fault handling is not the whole penalty, but does not isolate its indirect effects on caches or scheduling.

**Finding 4 — correctness gates do not consistently enforce their own contract. Severity: high assurance impact, uncertain performance bias.**

The [experiment 5 script](/home/artem/symidx/experiments/05-goose-fixes/run.sh:3) lacks `set -e`; several checksum mismatches only print `BAD`. Its compiler-suite comparison checks section totals, not identical failing test identities. The [consolidated script](/home/artem/symidx/experiments/05-goose-fixes/consolidated.sh:5) and [experiment 6 script](/home/artem/symidx/experiments/06-parallelism/run.sh:3) can continue after failed measurement commands. This does not show the committed runs failed; it makes future green-looking runs unreliable.

The tools' [checker](/home/artem/symidx/experiments/04-vs-tools/check.py:14) normalizes any falsy `kv` to `{}`, ignores extra top-level fields and fails only on multiset differences, not order. That exceeds the documented relaxation accepting an empty list for an empty map. [The tools specification](/home/artem/symidx/experiments/04-vs-tools/SPEC.md:17) deliberately relaxes ordering; that must remain a visible product difference.

Two missing final Fluent Bit records are disclosed and immaterial to these speed ratios, but demonstrate a different EOF contract. The measured M workload and edge-case set were not fully checked for the tools. The native programs have stronger checksum coverage.

**Fix:** fail closed on every check; compare failing test IDs and diagnostics, not totals; validate the complete schema and ordered output when required; run the same malformed/edge suite and measured corpus against every admitted competitor. Baseline failures need explanations, not a presumption that all 31 are environmental.

**Finding 5 — precise small speed claims exceed the statistical design. Severity: medium, direction can favor either language.**

The [measurement harness](/home/artem/symidx/experiments/03-goose-patches/measure.py:13) does measure process wall time and obtains CPU/RSS from GNU time. Randomized command order per round is a genuine improvement over the old grouped hyperfine repetitions. I found no arithmetic reversal in its paired ratio calculation.

Limitations remain:

- Wall and CPU/RSS come from different launches, so their quotient is not that process's utilization.
- A round containing multi-minute tools gives weak temporal pairing for short programs.
- Execution timestamps and actual randomized order are not saved in the CSV.
- Three or five observations cannot support a general-purpose 95% confidence claim. With three values, resampled medians mostly produce the observed extremes; more bootstrap resamples do not create more independent evidence.
- Neutral rebuilds are useful robustness checks, not independent machines or workload replications. They do not isolate code-layout effects from temporal noise.
- The newest fixes were not rechecked across the earlier native/LTO/PGO matrix. “Tuned Rust” here is a particular tuned baseline, not the best achievable Rust.

**Fix:** preserve order, timestamps, binary hashes and per-run load; use short alternating paired blocks over separate sessions; treat rebuild/session as grouping factors; report the distribution and uncertainty honestly. For a 1.3× claim, require a predeclared lower confidence bound above 1.3 across the intended workloads. For an engineering choice near parity, decide using product constraints rather than declaring a 3% language winner.

**Finding 6 — several original methodological defects remain substantive. Severity: medium to high for generalization.**

| Issue and evidence | Direction/impact | Concrete correction |
|---|---|---|
| Phase 1 changed primary memory metric from build to serving during the experiment: [report:28](/home/artem/symidx/bench/REPORT.md:28). | Favors the eventual Rust verdict relative to the original macOS build-memory result; not a clean preregistered test. | Keep original and revised decisions separate; preregister the next product metric. |
| “Serving memory” is peak RSS of load plus one query: [report:98](/home/artem/symidx/bench/REPORT.md:98). | Can overstate steady-state cost of Goose's transient copies. It remains relevant to startup memory limits. | Measure post-load/post-query retained memory and PSS/private/shared pages, plus peak separately. |
| Both implementations filter before retaining records: [Goose:395](/home/artem/symidx/experiments/02-logxform/goose/logxform.goose:395), [Rust:524](/home/artem/symidx/experiments/02-logxform/rust-arena/src/main.rs:524), contrary to [SPEC:28](/home/artem/symidx/experiments/02-logxform/SPEC.md:28). | Removes allocation/materialization of about 41% of lines. Relative bias unknown; it changes the hypothesized allocation workload. | Amend explicitly or measure both required and optimized sequences. Prefer optimized behavior for a product, but do not call it the original test. |
| HDFS dominates roughly 95% of log bytes; L repeats M. Phase 1 L repeats M 31 times. [Log corpus](/home/artem/symidx/experiments/02-logxform/SPEC.md:155), [index corpus](/home/artem/symidx/bench/REPORT.md:90). | Weighting favors properties of one log family and repeated names. | Publish per-format results; add held-out schemas, escape-heavy messages, long lines, skew and filter-selectivity variation. |
| The reference accepts `async class`, which the [specification:21](/home/artem/symidx/bench/SPEC.md:21) rejects; see [reference:21](/home/artem/symidx/bench/ref.py:21). | Shared bug, rather than a clear language bias. Hash agreement is insufficient as the only oracle. | Independent adversarial conformance cases and a corrected oracle. |
| Log cold-cache measurements are absent; the [report:126](/home/artem/symidx/experiments/02-logxform/REPORT.md:126) asserts the verdict would not change. | Sequential reads alone do not prove equal overlap, readahead, CPU/I/O interaction or rankings. | State “not measured”; test only if cold-file processing matters to the chosen product. |
| The macOS memory result is real in recorded data but its allocator explanation is untested: [report:21](/home/artem/symidx/experiments/02-logxform/REPORT.md:21). | Could hide a useful Goose niche or an ordinary Rust buffer/allocator fix. | Repeat on relevant Apple hardware; instrument buffer capacities and memory footprint; test ordinary reuse/allocator choices with equal behavior. |
| Experiments 4–5 lack committed pre-run specifications: [brief:104](/home/artem/symidx/AUDIT.md:104). | Leaves room for selection bias; no evidence of fabrication. | Call these prospective-in-session exploratory experiments; timestamp the next frozen protocol externally or in a commit before execution. |

The change from fat `bumpalo` records to compact Rust spans was a fair correction for a “best practical implementation” question, although it changes the original component comparison. Both versions failed the original Linux 1.3× threshold. Allowing Rust its normal libraries is also fair for product selection. A separate matched-primitive experiment is needed for claims about the language itself.

The Rust mmap path assumes stable backing storage after validation: [mapping](/home/artem/symidx/rust-expert/src/main.rs:349). Goose's owned verified bytes avoid that continuing dependency. That is a meaningful contract difference. It does not make Goose immune to inconsistent snapshots during concurrent file modification; it means the final owned bytes can be validated and no longer change underneath later reads. Give Rust an immutable artifact/snapshot contract or charge the cost of an owned copy when comparing equal guarantees.

**What the raw data supports**

I recalculated medians from the key CSVs; [arithmetic output](./arithmetic.json) records them. These headline values agree with their stated aggregation methods to rounding:

| Claim | Independent check | Assessment |
|---|---|---|
| G1–G3, configured tools on one core | Goose median 6.5908 s; Fluent Bit 130.0618 s; Vector 283.0315 s. RSS 36.05, 39.64, 96.21 MiB. | The quoted approximately 19.75×/41.88× are medians of round-paired ratios, not necessarily ratios of these marginal medians. No contradiction. CPU ratios also broadly support the large configured-workload gap. |
| G5–G6, neutral builds, one process | Median of build medians: Goose 6.8994 s, Rust 7.5739 s, same-scan Rust 7.1023 s. | Approximately 1.098× and 1.029×. “Parity to a small lead” is appropriate; “Goose wins” would be too strong. |
| G7/G12, six workers | Goose 2.4602 s / 513.70 MiB; Rust 1.5310 s / 366.20 MiB. | 0.622× throughput and 1.403× RSS; flattening from four to six is visible. |
| G8, F2 | Approximately 235.7 → 262.7 MB/s. | About 11.4% more throughput, not 11.4 percentage points of a universal language advantage. |
| G9, index F3 | L selective peak about 116.1 → 78.5 → 49.8 MiB; Rust 43.0 MiB. | 1.16× is correct for the benchmark. Qualification: F3 is now known to miscompile another valid program. |
| G10, fixed layout | L load approximately 29.2 ms versus 6.4 ms; selective RSS 46.9 versus 44.6 MiB. | Approximately 4.5× load time and 1.05× peak memory. Fixing copying did not establish load parity. |
| G13–G14, bottleneck and page faults | Stage timings and one CPU-accounting run. | Plausible explanatory evidence, not the strength of causal conclusion implied by the headlines. |

The relevant claim mapping is [CLAIMS:54](/home/artem/symidx/CLAIMS.md:54). I also checked the original experiment 2 summary figures: 216.2 versus 246.5 MB/s and 36,888 versus 39,288 KiB. The original test failed its Linux threshold. That does not prove the exact old 12–14% disadvantage is stable after code and library changes.

**Independent execution during this review**

I ran three interleaved rounds over M using the supplied `base-0`, `both-0`, `rust-0`, `rustfair-0` binaries; single-thread runs were pinned to CPU 3 and six-worker runs unpinned. Each launch recorded GNU-time wall, user, system and RSS together. Actual order, timestamps and load are preserved in [spotcheck.json](./spotcheck.json); runner source is [verify.js](./verify.js). One-minute load varied from approximately 2.76 to 5.50. This was a short stress/noise check, with one build per variant and no additional dedicated warm-up; it is not a replacement benchmark campaign.

| Program | Workers | Median wall | Median CPU | Median peak RSS |
|---|---:|---:|---:|---:|
| Release Goose | 1 | 8.43 s | 8.31 s | 35.98 MiB |
| Patched Goose | 1 | 7.65 s | 7.63 s | 36.05 MiB |
| Tuned Rust | 1 | 8.64 s | 8.53 s | 38.33 MiB |
| Same-scan Rust | 1 | 7.95 s | 7.92 s | 38.33 MiB |
| Patched Goose | 6 | 4.81 s | 14.25 s | 510.91 MiB |
| Same-scan Rust | 6 | 2.25 s | 8.82 s | 366.12 MiB |

Paired Goose/same-scan-Rust throughput ratios were **1.050, 0.999, 1.207** on one core and **0.534, 0.452, 0.486** on six. The outlying single-thread Rust run illustrates why a tiny advantage should not drive the decision. The six-worker direction and memory penalty reproduced, but these disturbed-session ratios must not be compared as absolute performance changes against the older session. All executions exited successfully and emitted the expected M record counts.

Separately, Goose and same-scan Rust at one and six workers produced the exact S reference SHA-256, `5bdaf7541e57d9a8a528d0082f3eb48ec821dcbda381233a6a713e0cf4b8d67f`. See [checksum results](./checksums.json). I did not hash M output during the timed runs.

**Fairness of the tools comparison, and what would survive**

The custom programs receive a fair common process-per-file wrapper. Switching Vector from console to file sink helped it; retaining the default Fluent Bit Lua protection was supported by the reported ablation. CPU-time results make “it is all startup/shutdown delay” untenable. The two dropped EOF records cannot explain the speed gap.

Nevertheless, the [Lua pipeline](/home/artem/symidx/experiments/04-vs-tools/fluentbit/pipeline.yaml:17) and [VRL expression](/home/artem/symidx/experiments/04-vs-tools/vector/hdfs.vrl:3) measure particular configuration implementations: regex extraction, dynamic objects and key lookup, redaction passes, event conversion, serialization and sinks. Fluent Bit has a [native parser filter](https://docs.fluentbit.io/manual/data-pipeline/filters/parser); whether native parsing plus minimal residual Lua meets this exact transform contract efficiently remains untested. Vector's [remap documentation](https://vector.dev/docs/reference/configuration/transforms/remap/) is the appropriate configuration reference, not evidence that this one script is optimal.

I cannot defensibly predict “20× becomes 8×” or any other surviving factor. A substantial advantage over these configurations is robust to ordinary timing noise. A ≥1.5× end-to-end advantage over an expert-tuned, functionally matched deployment is still a hypothesis. Do not derive a real-sink throughput gain by subtracting the blackhole ablation: it changes work and can change bottlenecks.

The one-core clear-win rule is reasonable for a genuinely single-core edge deployment. Selecting it because Goose's multicore weakness is already known risks optimizing the evaluation for Goose. It must be anchored to a user's resource budget. The configured tools' delivery, restart, buffering and observability features need either equal implementation or an explicit statement that the customer does not require them.

**Skeptical readings in both directions**

A Goose skeptic can fairly say: portable algorithmic improvements shrink the lead; mature Rust already provides the useful layout; local compiler changes add reliability and maintenance costs; product value is not measured. A Rust skeptic can fairly say: the old exact single-thread deficit was unstable; Goose's owned loader offers a different immutability contract; the macOS footprint and potential authoring advantages remain underexplored; one narrow corpus cannot condemn the language.

Both are compatible with the evidence. Neither establishes a general 1.3× winner.

**2. Improvement-plan and patch review**

These effort ranges are my planning judgments for an experienced compiler/runtime engineer with upstream cooperation. They are not promises, and overlapping work should not be summed mechanically.

| Improvement | Diagnosis and likely benefit | Feasibility / effort | Decision |
|---|---|---|---|
| Verified zero-copy mmap view | Eliminating owned copies can reduce peak footprint and first-touch work. Verification, final semantic validation, offsets and lookup-index construction remain. No measured basis for promising parity. | Prototype 2–4 engineer-weeks; supported lifetime/immutability/resource design approximately 2–4 engineer-months. Harder if arbitrary foreign mutable memory must be accepted. | Defer unless the selected product needs mapped persistent data. `from_file` is a different feature. |
| Thread-safe embedding and error returns | A genuine integration restriction, not a measured throughput explanation. Existing restricted exports already work. | Narrow explicit-context prototype 2–6 weeks; robust cross-platform context/failure lifecycle plausibly 3–6 months. Upstream response time is separate. | Validate the customer's exact host contract first. Do not require arbitrary-thread support for an offline process product. |
| Workers read input ranges | Directly targets input queue copies and coordinator work without changing the language. Output copies and ordering remain. | Approximately 2–5 days for a diagnostic prototype; 1–3 weeks for robust boundary/order/resource tests. | Reasonable bounded experiment if multicore files are an actual requirement. Not a verified fix. |
| Shared immutable data / ownership transfer / parallel loops | Copy traffic is real. Shared input alone leaves output traffic; `par for` syntax is not the necessary remedy. | A narrow region-transfer prototype may take 3–6 weeks; sound supported memory-model/runtime work often 3–6+ months. | Do not start this program before application-level alternatives and a user need. |
| F2 vectorizable JSON scan | Confirmed useful in this corpus; overflow concern is unfounded for the expression as written. | Days to implement; days/weeks for broad library-performance and compatibility coverage. | Keep as a candidate isolated library patch after held-out tests. |
| F1 `memchr`, bounds-check/aliasing/codegen changes | F1 had no demonstrated end-to-end gain. Remaining causal attributions are incomplete. | Small library experiments: days. General alias proof/BCE changes: weeks to months depending on scope. | Drop unproductive F1 from a minimal patch set; optimize only measured costs. |
| Build flags / PGO / moves | Flag tests exist, but predate F2; exact best combinations remain unmeasured. Moves could help queues more than the measured single-thread record phase. | Flag checks 1–2 days; general moves are language work. | One controlled retest if a close performance decision actually matters; no open-ended tuning. |

The original plan's [view diagnosis](/home/artem/symidx/docs/GOOSE_IMPROVEMENT_PLAN.md:31) identifies real work, but overattributes the deficit to copying. The [later layout analysis](/home/artem/symidx/experiments/03-goose-patches/PLAN.md:107) explicitly shows substantial remaining validation. Its [codegen discussion](/home/artem/symidx/docs/GOOSE_IMPROVEMENT_PLAN.md:93) is also not a proof that bounds checks or aliasing are the dominant cause.

A claim that root tracking permits `restrict` needs a proof about all accesses for the relevant call/block lifetime, not just different starting variables. Wrong `restrict` creates undefined behavior. Likewise, a move or shared view must account for sibling objects in the same data-stack region, escaped references, queue lifetime, receiver failure and reclamation. The no-shared-mutable-memory principle can survive region transfer; implementing it soundly is still nontrivial.

**Patch-specific assessment**

- **`from_file`:** the separate owned-result design is plausible. The [typechecker](/home/artem/symidx/toolchain/goose-src/src/typecheck_builtins.h:188) reuses verifiability restrictions; the [runtime](/home/artem/symidx/toolchain/goose-src/src/runtime/runtime_os.h:204) checks a prefix against file size, reads exact payload length and closes the handle on normal failure paths. Payload verification precedes exposing the final length. These are good properties, not a proof of the entire verifier.
- **Aliasing:** the existing own-target pathname and old-length cases pass. They do not cover nested generation and side effects; F3 demonstrates the gap. Broader field/reference targets, inline expansions and failing argument expressions need differential tests. Foreign views must be rejected or correctly rooted across replacement.
- **Failure paths:** `from_file` returns an empty result and `next=-1` on ordinary rejection; `read_file_range` clips to EOF and can succeed with fewer than requested bytes. Range failure preserves the logical length although kernel-written unused bytes can remain in storage. Callers need explicit size budgets and must distinguish “short but successful” from their own exact-length requirement.
- **Guard gap:** POSIX [positioned reads](/home/artem/symidx/toolchain/goose-src/src/runtime/runtime_os.h:144) rely on a protected end gap, backed by [mmap/mprotect setup](/home/artem/symidx/toolchain/goose-src/src/runtime/runtime_impl.h:493). I built a bounded test with 1 MiB stack reservation and a 2 MiB payload. Both `read_file_range` and `from_file` returned failure with empty logical results, without a crash: [guard log](./guard.log). This supports the Linux mechanism for that case. It does not prove all reservation layouts, OOM paths, concurrent truncation or Windows behavior. Windows uses `fread` and reserved-on-demand pages, so the comment about kernel `EFAULT` is not a portable argument. Add explicit runtime reservation/commit checks or a documented, tested platform contract.
- **Integer safety:** in [json::plain:30](/home/artem/symidx/toolchain/goose-src/stdlib/json.goose:30), `x` is a byte widened to `u32`; the largest `+255` result is 510, and `x+224` is at most 479. Each shifted predicate is zero or one, and bitwise AND never accumulates magnitude. There is no overflow problem. I rebuilt and ran its 829,521-string test successfully: [test log](./test-plain.log). This is not UTF-8 validation; the byte-escaping helper's role should not be confused with complete JSON validity for arbitrary invalid Unicode input.
- **F2 performance:** a whole-loop reduction is easier to vectorize than early exit. Different prior code generation, string-length distributions, inlining and code layout can explain different Goose/Rust gains. The data does not isolate which. The profile's 0.13 s renderer *difference* was never an upper bound on optimizing Goose's full 1.72 s renderer. Escaped strings now pay a full preliminary scan, so escape-heavy and long-string workloads are necessary before generalizing.
- **Huge-page branches:** the substantive patch asks for huge pages beyond the initial 2 MiB; the environment-switch branch parses a threshold and issues `madvise`. These are performance hints, not a demonstrated safety defect. They can increase RSS and latency variability. Unaligned/invalid thresholds and ignored `madvise` errors can silently make a requested configuration ineffective; validate/align inputs and record actual huge-page residency. The report already shows no general log-workload gain. I inspected these diffs but did not rebuild or rerun the branches.

**Proposed workers-own-input design**

The proposal is plausible, but “removes every input copy” at [PLAN:78](/home/artem/symidx/experiments/06-parallelism/PLAN.md:78) is too broad: it removes input queue transfers, not kernel-to-user reads or kept-record construction. Line scanning moves to workers; main can avoid a full scan only if it finds boundaries near coarse offsets rather than rediscovering every 65,536-line batch.

Use bounded byte-size jobs with correct newline alignment, maximum-line handling, exact-once coverage and a stable input snapshot. Opening by path independently also requires a file replacement policy. Preserve ordered output with a byte budget, not just a count of jobs: one unusually expensive early job can accumulate later results. Input and output expansion must both be bounded. File-only gains do not solve a live-stream plugin's input path.

The 1.6–2.0 s estimate is a reasonable hypothesis to test, not a planning commitment. Against the committed 1.531 s Rust baseline it implies approximately 0.96–0.77× throughput; meeting 0.9× requires at most about 1.70 s. Most of that forecast interval therefore does not pass the target. Rust must receive the same partitioning opportunity; beating yesterday's architecture is a different claim.

An easier diagnostic is independent single-thread processes on balanced file shards, including output ordering/merge cost and aggregate memory. Simply assigning Apache, SSH and HDFS to three processes is not a balanced test because HDFS dominates. If independent workers scale but typed queues do not, the runtime/coordination explanation strengthens. If they also stall, examine bandwidth, clocks and external interference before adding ownership transfer.

**What the plan missed**

The largest omission is a demonstrated product and authoring advantage. Technically it also lacks a complete host-context contract: initialization/destruction, multiple instances, return-buffer ownership, callbacks/reentrancy, cancellation, resource ceilings and the state after a trapped error. Malformed-input errors can often be returned explicitly today; containing arbitrary runtime failures is a different requirement. `longjmp`-style recovery must not leave host locks, C++ destructors, C resources or Goose state inconsistent. Process isolation may satisfy the customer's need more cheaply.

For the index product, [Phase 2](/home/artem/symidx/docs/PHASE2.md:22) adds resolution accuracy, incremental updates and index replacement that Phase 1 did not test. Tiny load times will not rescue inaccurate references. Put the user/accuracy checkpoint before broad language coverage; compare the real workflow with an LSP/SCIP-based alternative before implementing a large resolver.

**3. Competitive feasibility, separately**

All times below are judgments for narrow pilots, not delivery promises or predictions of a 1.3× result. None of the unmeasured competitors has been beaten by this repository.

| Competitor | What must be beaten | Goose requirements | Realistic opportunity and horizon |
|---|---|---|---|
| **bumpalo / serde plus arenas** | Whole parse–transform–render cost, representation size, integration and maintenance; not merely pointer-bump speed. Final `rust-arena` uses reusable vectors/spans, so it is not a direct bumpalo test. | Existing Goose can test a standalone workload. Embedding only if a host library is required. | A general 1.3× allocation-primitive win is not a credible thesis. Compact variable-size records and easier authoring may win for particular data; a 1–2 week workload/maintenance pilot can test this. Safe Rust already provides memory safety; the proposed edge is ergonomics, not automatically stronger safety. |
| **Protobuf C++ arenas** | Wire compatibility, schemas, unknown fields, presence, repeated/maps/oneofs, evolution, resource limits, generated APIs and decode/encode performance. | A real codec and conformance suite; embedding and ownership policy for host use. Goose's native serializer is not a Protobuf replacement. | A restricted schema transform or domain gateway is plausible in 1–3 months. General replacement is a multi-year ecosystem undertaking for a small team, with no evidence of a 1.3× advantage. |
| **upb** | A small fast C implementation with conformance, reflection options and no global runtime state, plus actual application integration. | Same wire/conformance work; small/reentrant explicit context; reliable errors and resource behavior. | Simplicity of a narrow public integration wrapper could differentiate; outperforming its core generically is unestablished. A specific codec pilot could take 1–3 months; broad parity is much larger. Its own C API/ABI is explicitly unstable, so do not mistake it for a frictionless universal library incumbent. |
| **Vector** | Useful event processing plus sources/sinks, backpressure, retries, delivery semantics, configuration, operations and support. | None for a standalone fixed converter; substantial networking/runtime/library ecosystem for a platform; host boundary for an embedded component. | A ≥1.3× gain over a particular expensive VRL workflow is plausible today, but is also plausible in Rust. Validate a converter in 1–2 weeks. A broad Vector replacement is not a sensible near-term small-team goal. |
| **Fluent Bit** | Efficient collection/forwarding and native parsing/filtering, not just this Lua script. A plugin must preserve integration, batching and operational contracts. | Potentially thread-affine exports only if the actual host model permits; otherwise explicit contexts/error containment. A subprocess is another deployment. | Native replacement of an expensive Lua transform could plausibly exceed 1.3× end-to-end when that transform dominates. A standalone pilot is weeks; hardened embedding may take months. No evidence yet that Goose is preferable to a Rust/C implementation. |
| **Wuffs** | A specific codec's throughput and its safety, bounded-memory, incremental and caller-managed I/O contract. | Reliable C interface; suitable caller-buffer/state design; recovery/resource contract; proofs or a clearly different safety promise. General mmap or parallel-loop features are not automatically needed. | An underserved format parser with easier authoring is plausible as a 1–3 month prototype. Broad replacement of mature codecs or matching its contract is not a small short-term project. No basis for promising 1.3×. |
| **Rust libraries via cbindgen** | The library's functionality and reliable C ABI, ownership, thread safety, error model, supported targets and distribution. cbindgen itself just generates headers. | Existing restricted exports can cover narrow cases; general use needs the context/error work above. | C-source distribution without asking consumers to build Rust is a plausible customer-specific edge. Demonstrate that requirement and integration in weeks; reliable general library support may take months. No generic performance advantage follows from the language boundary. |

Primary documentation supports these distinctions: [bumpalo](https://docs.rs/bumpalo/latest/bumpalo/) provides bump allocation and is not itself a shared-thread allocator; [Protobuf arena documentation](https://protobuf.dev/reference/cpp/arenas/) describes thread-safe allocation but separately synchronized reset; [upb](https://github.com/protocolbuffers/protobuf/tree/main/upb) describes its compatibility, small runtime and unstable C ABI; [Wuffs](https://github.com/google/wuffs) describes compile-time checks and a hermetic, caller-managed memory/I/O model; [cbindgen](https://github.com/mozilla/cbindgen) generates headers for an already-designed Rust C API. These are capability references, not independent benchmark evidence.

A Goose native `varint` does not imply Protobuf wire compatibility. Tagged fields and integer encodings still need implementation. Variable-size records do not make random field access impossible: offsets or fixed metadata can provide it, at a cost. Likewise “Goose has half of Wuffs” is not a measurable readiness claim. Equivalent safety must be demonstrated against the same threat and resource model.

**4. Strategy and assessment of the earlier reviews**

Improving Goose can be worthwhile as language research. It is not currently established as the cheaper route to these products. A small upstreamable library patch such as F2 has a manageable maintenance surface. A private fork carrying ownership semantics, foreign views, embedding recovery and codegen changes creates another product to maintain.

The operational costs are compiler expertise, rebasing, regression triage, target support, security response, documentation and customer trust. Hiring people able to debug the whole stack is a different problem from hiring application developers. Upstream acceptance helps but is not a maintenance SLA, and dependence on one designer remains a business risk. A fork is defensible only with an explicit research budget, competent ownership and a demonstrated product return.

The compiler's [README:609](/home/artem/symidx/toolchain/goose-src/README.md:609) confirms extensive AI authorship. That is neither proof of unsoundness nor evidence that sound compiler engineering is unusually cheap. The independently reproduced local F3 defect, shared-author correctness oracle and incomplete failure comparison are concrete reasons to demand stronger assurance. Human-authored compiler changes need the same discipline.

**A niche available today:** a bounded, standalone batch converter, migration tool or sanitizer for a specific format and deployment. It can exploit compact records, a small executable and one configuration without requiring arbitrary-thread embedding or a new sharing model. Isolated worker processes can contain failures. These are possible product advantages; superiority in developer time, safety or maintenance has not been measured. A customer must actually prefer that workflow over existing commands and a specialized Rust equivalent.

**Earlier review 1:** [Symidx_Audit_03-11-2026.md](/home/artem/symidx/Symidx_Audit_03-11-2026.md:1) correctly identifies integration and ecosystem obstacles. I disagree with “every deficit” being traced to a missing feature, AI making contributions unusually cheap, zero-copy implying parity, or implementing several features before a product trial. The final Rust comparator is not bumpalo; safe Rust already has safety guarantees; restricted Goose embedding already exists. Its profiling/build-flag recommendations were partly stale even before the newest work.

**Earlier review 2:** [Symidx_Audit_03-11-2026_2.md](/home/artem/symidx/Symidx_Audit_03-11-2026_2.md:1) is substantially better calibrated: bounded product experiment, no broad fork, measured versus inferred claims, transient versus retained memory, corpus limitations and compiler-assurance costs. I agree with that direction. I would now move targeted patch soundness ahead of another broad replication and would investigate Apple memory only if Apple is a target customer platform. The new confirmed F3 defect and the misuse of elapsed queue timings deserve stronger priority than either earlier review could assign.

**Accuracy of the brief's status table:** [AUDIT:110](/home/artem/symidx/AUDIT.md:110) is mostly accurate and unusually candid. Interleaving improved; the scan explanation was corrected; retained memory, early filtering, corpus concentration, shared `async class` behavior and customer validation remain open. Three qualifications:

1. “The view target was missed” conflates direct owned reads/layout changes with a verified mmap view. The latter has not been built; its forecast is unproven, not experimentally refuted by a view implementation.
2. The guard-gap row was correctly “reasoned about only” at the reviewed commit. This review adds one successful Linux boundary rejection test, not a complete soundness certification.
3. Broad opportunity-falsification language has been narrowed, but replacing it with a positive product decision based on the configured-tools win repeats part of the same inferential leap in the other direction.

The most neglected earlier recommendation is still to measure an actual user's benefit and one realistic change request. More compiler features cannot answer that question.

**5. Ranked action plan, cost and stopping criteria**

| Rank | Action | Rationale and approximate cost | Kill or redirect criterion |
|---|---|---|---|
| **1** | Quarantine F3; fix call-local state and independently review loader semantics. | Silent wrong-code is a release blocker. Approximately 1–3 days for a narrow fix and regression coverage; broader compiler assurance is additional. Keep F2 separable. | No shipping F3 until nested/inlined/side-effect cases pass in debug/release and failing-test identities are understood. If a local sound fix is unclear, remove F3 and accept the copy cost. |
| **2** | Select one user workflow and conduct a matched end-to-end pilot using existing Goose plus equivalent Rust/native configuration. | This decides whether there is a product and whether Goose's preference has a tangible benefit. About 2–5 days for a tightly scoped pilot, up to 1–2 weeks with the user's realistic change. | Stop the Goose-specific product thesis if it offers neither ≥1.3× relevant end-to-end gain nor a predeclared decisive simplicity/deployment/maintenance benefit. No major compiler prerequisite before the first demonstration. |
| **3** | Repair the evidence contract and harness gates for that pilot. | Make failures fatal; exact semantic comparisons; log ordering/timestamps/hashes; retain peak and steady memory separately. About 1–2 days, alongside rank 2. | No public speed/safety headline with an unresolved correctness mismatch or unreported feature reduction. |
| **4** | If file-parallel throughput matters, run process-sharding control and then the worker-range prototype with matched Rust. | Cheapest way to test coordinator/copy hypothesis before memory-model work. Roughly 1 day for the control, 2–5 days prototype, up to 1–3 weeks robust validation. | At the capped effort, <0.75× matched Rust closes this optimization route; 0.75–0.9× requires an explicit customer benefit to proceed, not automatic escalation to language redesign. Require RSS ≤1.1× if that budget is real. |
| **5** | Only for a validated host-library need, specify and prototype explicit contexts/errors with upstream design review. | Removes a demonstrated deployment blocker, not an assumed universal one. 2–6 weeks prototype, supported work potentially months. | Stop if required isolation/lifecycle guarantees cannot be met, upstream rejects essential design and no fork budget exists, or supported delivery exceeds the product's value. A blanket ban on any lock is too crude; measure the actual host workload. |
| **6** | Investigate platform-specific footprint or mapped views only if the chosen customer needs them. | Apple memory and instant-load indexes remain interesting but are separate product hypotheses. Apple diagnostic 1–2 days; view effort as above. | Stop if ordinary competitor tuning removes the benefit or the target deployment does not value it. Do not let these become detours. |

Replace the current “stop below 0.75, then try a harder language feature” pattern with a total effort cap and a decision owner. Otherwise a kill rule merely starts the next project. A marginal benchmark miss must not silently redefine success after the result.

**Short version for non-specialists**

The research shows that Goose can run a specialized log-processing tool quickly. It does not show that choosing Goose gives an advantage over a well-built Rust version. Both custom programs can be much faster than the particular general-purpose logging configurations tested.

I found a real error in one local compiler improvement: it can return the wrong data while saying the load succeeded. The normal tests missed it. Fix or remove that patch before relying on it. A separate JSON optimization passed its checks and appears useful.

The biggest risk is spending months improving a programming language before discovering whether anyone wants the product. Competing with all the named tools at once is not a realistic small-team plan. A narrow tool for one customer's repetitive task could be realistic today.

Spend a short, fixed period showing one useful workflow with existing Goose. Compare it with the practical alternatives, including installation, reliability and a later change request. Continue because users value the result and the team can maintain it—not because the benchmark has been adjusted until Goose wins.

**The three things I would do next**

1. **Fix or disable F3 and add the demonstrated nested-call regression.** Keep the independent JSON optimization separate.
2. **Run one real-user workflow against expert-configured/native tooling and the equivalent Rust tool, including one maintenance change.** Choose the product and deployment before more language work.
3. **If that workflow genuinely needs multicore file processing, test balanced independent processes, then worker-owned input ranges.** Stop at the agreed budget if the benefit does not survive matched comparison.

**The one measurement most likely to change the decision:** the end-to-end advantage of a Goose implementation on that real user's complete workflow, against the best practical alternative, after including integration and one required change. A ≥1.3× useful performance gain or a decisive predeclared delivery/maintenance advantage could justify the Goose path. Another few percent on the current HDFS-heavy micro-workload would not.
