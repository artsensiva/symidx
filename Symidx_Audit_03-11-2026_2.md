My assessment is that **the research is useful, but both the project’s negative conclusions and the attached audit’s optimism go beyond the evidence**.

The research establishes that Goose has no demonstrated large performance advantage in these two implementations. The attached audit correctly identifies possible improvements, but it does not establish that they will be cheap, sufficient, or commercially worthwhile.

**My recommendation is to allow one short, tightly bounded Goose product experiment—not commit to a multi-feature compiler fork.** Your preference for Goose is a legitimate reason to investigate it. It is not necessary to prove that Goose beats Rust everywhere.

Both versions follow below. This remains a read-only assessment; I have not changed files or rerun benchmarks.

---

**Full version — final research report**

**1. Assessment of the attached audit**

`Symidx_Audit_03-11-2026.md` is a useful strategy note, but I would not use it unchanged to authorize several months of compiler development.

Its strongest points are:

- Optimized Rust already captures many advantages attributed to Goose’s memory model.
- Integration into existing applications is a serious obstacle.
- Vector and protobuf are ecosystems, not just fast processing loops.
- Upstream acceptance matters before maintaining a fork.
- Each proposed improvement needs a measurable target and a stopping rule.

However, several statements need correction.

| Attached audit’s position                                        | My assessment                                                                                                                                                        |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Every measured deficit has been traced to a missing feature.     | **Unproven.** Copying and integration restrictions are observable. Their contribution to the entire performance gap has not been isolated.                           |
| AI authorship makes compiler contributions unusually cheap.      | **Unsupported.** AI may accelerate implementation. It does not establish the cost of verifying memory safety, maintaining compatibility or debugging miscompilation. |
| Experiment 2 has not been profiled.                              | **Inconsistent with the included repository.** Phase timing and an ablation are recorded. Hardware-counter profiling remains missing.                                |
| Build flags should be tested next.                               | **Already done**, although stronger experimental controls are needed.                                                                                                |
| Zero-copy loading should close the gap to parity.                | **Too confident.** A substantial validation/index-building pass remains.                                                                                             |
| Goose cannot be used as a library without new embedding support. | **Too absolute.** It supports restricted embedding. Arbitrary concurrent calls and robust failure containment are the missing capabilities.                          |
| Experiment 2 essentially compares Goose with bumpalo.            | True of the original Rust version, but **the final competitor uses reusable vectors and compact spans**, not bumpalo.                                                |
| Goose’s advantage over bumpalo is safety.                        | A possible **ergonomics** advantage is more defensible. Safe Rust with bumpalo already provides memory-safety guarantees.                                            |
| Implement three language features before building a product.     | **Wrong order for a small product team.** Product requirements should determine which feature, if any, is necessary.                                                 |

The profiling and flag results are explicitly present in `the experiment 2 report`. Its best tested Goose configuration achieves 250.6 MB/s against Rust’s 260.3 MB/s: a throughput ratio of **0.96**. The final representation change is documented in `amendment A1`.

Two competitor-specific claims also need refinement.

**Protobuf:** Goose’s native variable-length integer representation does not automatically provide protobuf compatibility. The repository documents Goose’s `varint` as signed ZigZag encoding; protobuf distinguishes ordinary integer varints from ZigZag-encoded signed fields and adds tags, lengths and other wire rules. Variable-size arrays also do not make protobuf implementation fundamentally impossible: a decoder can construct fixed metadata, offsets or another indexed representation. These are design choices and costs, not categorical barriers. `Goose findings`, [protobuf encoding specification](https://protobuf.dev/programming-guides/encoding/)

**Wuffs:** saying Goose has “half of Wuffs’ design” is not a meaningful readiness measure. Wuffs combines specific compile-time guarantees with caller-managed memory and I/O. Goose need not reproduce every Wuffs feature to build a useful parser, but matching Wuffs’s deployment and safety contract requires substantially more than bounds-check elimination. [Wuffs documentation](https://github.com/google/wuffs)

**My judgment:** retain the attached audit’s integration concerns and upstream-first discipline. Replace its confident performance forecasts and “compiler features first” sequence.

**2. What the research actually establishes**

I distinguish three levels of confidence.

| Conclusion                                                                                                  | Confidence                                | Reason                                                                                                          |
| ----------------------------------------------------------------------------------------------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| The current Rust symbol-index implementation loads substantially faster on the tested warm-cache workloads. | High for the tested implementations       | The measured differences are large and the loading architectures differ clearly.                                |
| Goose failed experiment 2’s specified Linux threshold.                                                      | High as a description of recorded results | Neither throughput nor memory approached the required advantage.                                                |
| Goose has a stable 12–14% single-thread disadvantage.                                                       | Low to moderate                           | Different sessions and builds range from a noticeable deficit to approximate parity.                            |
| Goose has a substantial multithreaded limitation in this pipeline.                                          | Moderate to high                          | A large deficit is recorded, and queue copying is observable. Its precise causes remain incompletely separated. |
| Goose offers a valuable macOS memory advantage.                                                             | Promising, unconfirmed                    | The result is substantial, but allocator behavior, buffer growth and machine effects remain unresolved.         |
| Goose cannot compete in request processing, telemetry or ETL.                                               | Unsupported                               | The experiments cover too little of those categories.                                                           |
| Goose is cheaper to develop and maintain.                                                                   | Unsupported                               | Human productivity and maintenance were not measured.                                                           |

The central measurements remain:

- **Symbol index, M:** Goose uses 14.6 MiB versus Rust’s 14.1 MiB during building. Selective load/query peak memory is 11.4 versus 5.6 MiB. `Phase 1 results`
- **Log transformation, M, local Linux:** Goose processes 216.2 MB/s versus 246.5 MB/s, with 36,888 versus 39,288 KiB peak RSS. `Recorded results`
- **Log transformation, six workers:** Goose reaches 655.5 MB/s versus 1168.2 MB/s. `Recorded results`
- **macOS CI:** Goose’s recorded peak memory is approximately 1.91× lower, with 1.15× higher single-thread throughput. `Cross-platform results`

For clarity, a throughput ratio of 0.88 means approximately **12% lower throughput**, corresponding to approximately **14% longer processing time**. A 1.3× memory advantage means using approximately **23% less memory**, not 30% less.

The research deserves credit for preserving inconvenient results, correcting Rust implementations, reporting amendments and linking claims to evidence. Those practices make an independent review possible.

Its main weakness is the jump from **“this hypothesis did not pass this test”** to **“these product opportunities are falsified.”**

**3. Experimental weaknesses that affect the decision**

The following issues should be corrected before treating small differences as decisive.

**Timing order still allows drift.** The experiment 2 harness puts implementations into one hyperfine invocation, but that does not interleave individual timing runs. The recorded local version executes each command’s repetitions together. Consequently, implementation and elapsed time remain confounded. RSS rounds are interleaved correctly. `Harness`, [hyperfine 1.19 scheduler](https://github.com/sharkdp/hyperfine/blob/v1.19.0/src/benchmark/scheduler.rs)

**The claimed code-layout effect is not isolated.** In `the raw neutral-build measurements`, one unchanged Rust executable varies from about 6.37 to 8.00 seconds. That is substantial within-binary variation. Code layout may matter, but temporal interference is a competing explanation.

**“Serving memory” measures a startup peak.** The Phase 1 harness measures maximum RSS over loading and one query. That is useful for startup resource requirements, but does not establish how much memory a persistent server retains afterward. The distinction particularly matters for a copy-based loader. `Memory measurement`

**The implementations do not follow the strict materialization sequence.** The specification requires building the batch’s records before transforming them. Both Goose and optimized Rust filter before retaining records, and transform each retained record while processing its line. Since approximately 41% of lines are dropped, this materially changes the intended allocation experiment. Relative bias is unknown. `Specification`, `Goose processing`, `Rust processing`

**The corpus is narrower than its description suggests.** HDFS contributes approximately 95.3% of experiment 2’s input bytes. Its larger corpus repeats the same files. Phase 1’s larger corpus similarly repeats the smaller repository collection. These are useful scale checks, but weak tests of diversity. `Log corpus`, `Index corpus construction`

**Checksums establish agreement, not complete correctness.** For example, the Phase 1 specification rejects `async class`, but the reference and implementations accept it. Shared authorship makes shared misunderstandings possible. `Specification`, `Reference parser`

**Safety claims need boundary conditions.** Goose’s input adapter directly writes into runtime storage without a reservation check. Rust’s mmap loader assumes the mapped file cannot change. Neither condition should disappear behind a blanket “memory-safe” label. `Goose C adapter`, `Rust mapping contract`

**Pre-registration was imperfect.** Phase 1 changed its primary memory metric mid-experiment. Experiment 2 disclosed a representation amendment; importantly, both the original and amended comparisons failed its threshold. `Criterion refinement`, `A1`

These issues weaken precise ratios and broad extrapolations. They do not reveal a hidden, demonstrated 1.3× Linux advantage for Goose.

**4. Which Goose improvements are justified?**

The distinction is between a plausible prototype and a supported language feature. My estimates below are planning judgments, not measurements.

| Improvement                                       | Evidence and realistic benefit                                                                 | Prototype effort      | Supported implementation                             |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------- | --------------------- | ---------------------------------------------------- |
| Verified view over immutable mapped bytes         | Could substantially reduce load copying and startup peak memory. Load parity remains unproven. | 1–3 engineer-weeks    | Roughly 2–4 engineer-months                          |
| Independent embedding contexts and defined errors | Removes important integration restrictions. No measured speed gain is established.             | 2–4 weeks             | Roughly 3–6 months                                   |
| Shared immutable input or transferable regions    | Could reduce queue copying and memory pressure. Exact throughput recovery is unknown.          | 3–6 weeks             | Roughly 3–6 months                                   |
| Targeted library/code-generation changes          | Plausible modest improvements; strong evidence for a 30% overall win is absent.                | Days to several weeks | Depends heavily on whether language semantics change |

These estimates overlap and must not simply be added. They assume relevant expertise and upstream cooperation.

**Zero-copy loading**

The diagnosis is partly correct: loading a file and copying its contents creates avoidable work.

However, `the existing profile` records **33.5 ms** for L’s final validation and lookup-index construction alone. Rust’s full measured load is **5.3 ms**.

If that remaining pass stayed at its measured cost, eliminating all other work would still miss the proposed ≤10.6 ms target. A different mapping/layout may change that pass’s behavior, so this is a constraint on the forecast—not a prediction of the prototype’s exact result.

A sound feature also needs ownership of the mapping, immutable backing bytes, safe derived references, bounded validation and a policy for replacing files.

**Embedding**

The attachment’s absolute claim that Goose cannot be embedded is incorrect. Existing exports can be called under their documented restrictions. The real issue is whether those restrictions fit a customer’s host application. [Goose export documentation](https://github.com/aardappel/goose/blob/master/docs/reference.md#export-fn)

For a general library, explicit contexts would need to address:

- Independent simultaneous instances.
- Thread affinity or safe migration.
- Returned-buffer ownership.
- Reentrancy and callbacks.
- Cleanup after failures.
- Memory limits and repeated initialization.

Malformed input can often be handled with explicit validation and an error return already. Recovering from an internal runtime check failure requires a stronger guarantee about the context’s state.

**Parallelism**

The copying mechanism is a credible optimization target. It does not follow that adding `par for` is the necessary solution.

For the existing batch pipeline, a narrower change—transferring one independently owned input/output region—could be enough. Shared input alone would leave output copying and reordering costs.

Measure copy volume, coordinator utilization and queue waits before selecting the design. Otherwise the team risks adding a language feature that does not remove the dominant bottleneck.

**Single-thread optimization**

The phase measurements suggest parity is more plausible than a large lead.

The recorded parse, rendering and batching differences sum to approximately 0.48 seconds out of Goose’s 7.27 seconds. Matching Rust in those phases would imply roughly a 7% speedup, assuming the measurements and decomposition are valid. `Phase results`

Two proposed explanations require particular caution:

- **Aliasing:** knowledge of where references originate is not automatically sufficient to emit C `restrict`. That requires a valid non-aliasing guarantee for the relevant accesses.
- **JSON passes:** both implementations scan plain strings and then copy them. Goose’s preliminary scan can add work on the escaping path, but the source does not establish the simple “two passes versus one” explanation. `Goose formatter`, `Rust formatter`

The profile also does not isolate copying by itself. Similar total record-building times mean copying is not demonstrated to be the dominant single-thread disadvantage; they do not mean copying costs nothing.

**5. Final competitive assessment**

| Competitor                | Plausible Goose opportunity                                                                                               | What is not justified                                                                                   |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **bumpalo**               | Easier construction of compact, heterogeneous data; potentially less representation overhead in a particular application. | A general safety superiority claim or a presumed 1.3× advantage in the allocation primitive.            |
| **protobuf / upb**        | A specialized schema transformer, restricted codec, or integration package with a clearly defined customer benefit.       | Treating native serialization or varints as a shortcut to protobuf compatibility and maturity.          |
| **Vector**                | A small fixed-purpose converter or filter with simpler deployment and configuration.                                      | Building a comparable general observability platform as a small near-term language experiment.          |
| **Wuffs**                 | A parser for an underserved format, with easier authoring and acceptable resource behavior.                               | Assuming similar syntax or bounds-check features establish equivalent safety and deployment properties. |
| **Rust through cbindgen** | Rebuildable C-source distribution for customers who cannot introduce Rust into their build process.                       | Expecting generated headers alone to establish integration parity or a performance advantage.           |

The incumbents already solve much of the allocation problem. For example, upb supports standard protobuf features and conformance, optional reflection and a design without global state. A new implementation must address that functional contract, not just decoding speed. [upb documentation](https://github.com/protocolbuffers/protobuf/tree/main/upb)

A Goose product can beat a general tool by specializing. That advantage belongs to the product design and could often be reproduced in Rust. It is still commercially useful if customers value the result.

**My preferred first candidate is a narrow converter or parser with one output contract and one deployment environment.** Start as a standalone tool if possible. Select a C-library form only when a real host application requires it.

I would not select “replace Wuffs” as the initial product definition. Select a format, a user and a concrete integration problem.

**6. Strategy and investment decision**

There are two valid goals, with different success criteria:

| Goal                                          | Appropriate success criterion                                                        |
| --------------------------------------------- | ------------------------------------------------------------------------------------ |
| Build a useful product while preferring Goose | Customer value, acceptable performance, manageable maintenance and delivery cost     |
| Improve Goose as a language                   | Sound feature design, useful benchmarks, upstream adoption and long-term maintenance |

A language project can be worthwhile even without a commercial product. But it should have an explicit research budget rather than being presented as the cheapest route to shipping one.

Your preference for Goose can justify a small performance tradeoff. For example, a product that is slightly slower but materially simpler to maintain may be the better choice. The repository has not yet demonstrated that simplicity benefit.

Conversely, matching Rust’s benchmark performance after several months of compiler work would not automatically justify the investment. Maintenance, tooling, dependencies, hiring and user trust remain.

AI assistance can reduce coding effort. It cannot substitute for understanding why a memory-model change is sound. A small team should avoid becoming the only group capable of diagnosing its own compiler/runtime failures.

**My investment recommendation:** fund a short validation phase. Defer a multi-feature fork. Continue only if one product benefit survives comparison with a competent alternative.

**7. Ranked plan of action**

These are proposed future actions; none has been performed as part of this read-only review.

| Priority | Action                                                                          | Deliverable                                                                                                                      | Estimated effort                            | Stop or redirect when                                                                                           |
| -------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **1**    | Correct and freeze the experimental contract.                                   | A concise statement of what each benchmark measures, explicit amendments, immutable baseline versions and raw-data requirements. | ½–1 day                                     | Do not proceed with new headline claims until correctness and measurement definitions are consistent.           |
| **2**    | Run one controlled Linux replication.                                           | Randomized paired timings, startup peak and steady-state memory, full raw results.                                               | 1–2 days                                    | Close the existing Linux performance hypothesis if a material advantage remains unsupported.                    |
| **3**    | Investigate the macOS memory result if Apple deployment matters.                | Goose versus ordinary Rust buffer tuning on the same quiet machine, with capacity and footprint measurements.                    | 1–2 days                                    | Stop that niche hypothesis if routine Rust tuning removes the advantage or replication fails.                   |
| **4**    | Select one actual workflow and build the smallest useful Goose/Rust comparison. | Equivalent behavior, a real user task, integration demonstration and one maintenance change.                                     | 1–2 weeks                                   | Stop if there is no user-valued benefit or if substantial compiler work is required before demonstrating value. |
| **5**    | Discuss the one essential missing feature with upstream.                        | A narrow design proposal, explicit ownership/safety requirements and agreement on maintenance.                                   | 1–3 days preparation; response time unknown | Stop the upstream-dependent path if acceptance is unavailable and maintaining a fork is not explicitly funded.  |
| **6**    | Prototype only that feature.                                                    | Tested patch and measured product impact against unchanged baselines.                                                            | Use the estimates above                     | Stop at the pre-agreed effort cap if it misses its target or requires weaker safety guarantees.                 |
| **7**    | Harden a product that has passed those gates.                                   | Compatibility tests, fuzzing, resource limits, reproducible releases and a support plan.                                         | Several months                              | Redirect if reliability or support costs erase the demonstrated benefit.                                        |

For a performance claim, I would replace the current ambiguity band with a clearer proposed rule:

- Use paired repeated measurements and report uncertainty.
- Proceed with a “≥1.3×” claim only when the evidence supports that threshold.
- If uncertainty crosses the threshold, allow one predefined replication.
- If the result remains inconclusive, record “not demonstrated” rather than selecting the favorable run.

For a non-performance claim, define the benefit before testing: installation without a Rust toolchain, fewer integration steps, lower total implementation-and-maintenance effort, or support for an otherwise unsupported workflow.

The cheapest unresolved **benchmark** question remains the Apple-memory result. The most important unresolved **business** question is whether anyone needs the proposed product. The Apple experiment should not become another detour if the intended customers run Linux.

**A practical first-month schedule**

- **Week 1:** correct the measurement issues, replicate the central Linux result, and investigate Apple memory only if relevant.
- **Week 2:** implement one narrow user workflow using existing Goose capabilities; compare its behavior and costs with Rust.
- **Week 3:** exercise malformed inputs, a realistic change request and the intended integration. Request upstream feedback on one blocker if needed.
- **Week 4:** choose among shipping a small Goose pilot, funding one bounded compiler prototype, or moving the product to a better-supported implementation.

Do not automatically schedule zero-copy, embedding and parallel loops in sequence. An offline transformer may need none. A C parser may need embedding but no mmap. An index may need mapped views and replacement semantics but no new parallel-loop syntax.

---

**Short version — for non-specialists**

**Goose could be used to build a good product. The research does not show that it is generally faster or cheaper than Rust.**

The tests compared two tasks: opening a code index and processing logs. Well-optimized Rust performed as well as or better than Goose on the main Linux tests. That is useful evidence, but two tasks cannot decide the future of an entire programming language.

The attached audit is right that Goose can be improved. It is too confident that the improvements will be straightforward and close all the gaps. It also recommends some tests that have already been done.

Three things matter most:

1. **Fixing Goose could become a separate project.** A quick prototype might take weeks; making it dependable for customers could take months.
2. **Established competitors offer much more than speed.** They provide compatibility, integrations, documentation and years of practical experience.
3. **A small, useful product does not need to beat Rust everywhere.** It could win by being easier to install, easier to use, cheaper to maintain or particularly good at one task.

**What I recommend**

Spend approximately one month answering a concrete question:

> Can we build one useful product in Goose, with acceptable speed and reliability, without first rebuilding important parts of the language?

During that month:

- Recheck the most important measurements under better conditions.
- Investigate the promising Apple-memory result if Apple users matter.
- Build one small real-world tool.
- Compare the complete experience, including installation and a later change.
- Improve the compiler only if one specific missing feature blocks an otherwise convincing product.

**Continue with Goose if** the small product works well and offers a clear benefit. A slight speed disadvantage can be acceptable if the product is substantially simpler or solves a problem alternatives do not.

**Stop or change direction if** the project needs several compiler features before users can try it, the advantage disappears after ordinary competitor tuning, or maintenance becomes too dependent on one person.

**My final recommendation:** give Goose a limited, practical trial. Do not commit to a broad fork or a replacement for Vector, protobuf or Wuffs on the evidence available today.
