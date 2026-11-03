# Where Goose could be a strong fit: an evidence-based opportunity analysis

2026-11-03. Written after symidx Phase 1 ([bench/REPORT.md](../bench/REPORT.md)). Goose v2026.3.

> **Outcome (experiment 2, 2026-11-03): candidates 1 and 2 are falsified; 4 and 7 lose their main
> argument. The Goose track ends.** The shared test recommended in section 5 was run as
> [experiments/02-logxform](../experiments/02-logxform/REPORT.md): Loghub HDFS, OpenSSH and Apache logs
> (1.66 GB) parsed into variable-size records per 65,536-line batch, filtered, normalized, redacted,
> rendered as NDJSON and dropped, pre-registered with a kill criterion of ≥ 1.3× over arena Rust. After a
> fairness audit, Goose reached 0.88× rust-arena's single-thread throughput and used 1.07× less peak RSS on
> the reference machine (CI Linux: 0.93× and 1.07×). It beat idiomatic Rust by 2.2× and 2.7×, which, as in
> Phase 1, is the memory layout's win, and Rust can use that layout too. The one qualification is the
> macOS CI VM, where Goose used 1.9× less RSS, probably through the system allocator; uninvestigated. The
> analysis below is kept as it was written, before the test.

**Bottom line, up front.** None of these candidates is proven. Three are strong enough to deserve a cheap
experiment (ranks 1–3), three are plausible but weaker, and the rest are speculative. That's fewer than ten
genuinely strong candidates, and the list says so instead of padding. The best candidates share one shape:
**parse many small variable-size records, transform them, emit a result, and drop everything at once.**
That's the shape of Goose's largest measured wins. It's also the opposite of symidx, which looked like a
strong fit and failed.

## 1. What we actually know about Goose

Two kinds of evidence are kept apart below. Upstream numbers are the Goose project's own benchmark suite
on one machine: 16 benchmarks, whole-process time, losses published [S1][S2]. They haven't been reproduced
independently. symidx numbers are ours.

### Measured strengths

| Property | Evidence | Source |
|---|---|---|
| Variable-size records stored at their own size (variable-mode enums, inline text) | `records`: 2.02–2.26× faster than Rust on 3.98× less memory; `interp` (a tree): 1.29–1.41× faster on 2.04× less memory; `sexp`: 2.43× less memory than a Rust arena | upstream [S2] |
| Request-scoped data built in place | `respond`: an inline DTO takes 507/491 ms against Rust's DTO at 1,338 ms; the streaming variants are 454/400 against 540 ms | upstream [S2] |
| No allocator, O(1) teardown (a scope's data stack is reset with one store) | `bintrees`: 206/204 ms against Rust's arena at 235 ms and C++'s arena at 393/407 ms; per-node allocation rows exceed 3 s | upstream [S1][S2] |
| Index types plus check-free kernels | CSR BFS 1.12–1.32× ahead of Rust and C++ | upstream [S2] |
| Compact images from inline varint records | 1.12–1.20× smaller than the best Rust layout (rkyv) | symidx [R] |
| A validating loader for untrusted bytes, for free | `from_bytes` checks structure, every index type and every bound type; the Rust version needs bytecheck plus a hand-written pass | symidx [R] |
| Plain C out, C in | One C file per program; `--standalone` plus `export fn` builds a library for a C host | upstream [S3] |

### Measured or documented weaknesses

| Weakness | Evidence | Source |
|---|---|---|
| `from_bytes` always copies | 2.0–3.1× the serving memory and 10–25× slower warm load than rkyv over mmap (1–2× cold) | symidx [R] |
| No zero-copy view over foreign memory | requested upstream as goose#221 | [S4] |
| Data stacks need address-space reservation | no microcontrollers; WebAssembly is a design proposal, not implemented | [S5] |
| No move for resizable values; pinned globals can't be cleared | one image per process in symidx; large assignments copy | symidx [R] |
| Library mode: one runtime per process, exported functions are not thread-safe and must be called from the thread that called `goose_init` | blocks embedding in multithreaded hosts | [S3] |
| A failed bounds check aborts the process | memory-safe, but a library would take its host down | [S3] |
| Recursion can't keep growable data across a recursive call; no function pointers, escaping closures or dynamic dispatch; whole-program compilation only | recursive-descent parsers need pools; plugin architectures don't fit | [S1] |
| Losses and ties upstream | `calc` loses to the Rust arena (481/491 vs 436 ms); `lru` and `scene` lose under MSVC and tie under clang; flat numeric kernels show no language advantage | upstream [S2] |
| A young compiler, a tiny ecosystem | goose#177 found in a 20-minute port | [S6] |

### The symidx lesson, applied

symidx's hypothesis ("variable-size records, checked indices and loading without parsing make an
instant-start index") was plausible on paper. It failed for two reasons:
- **The decisive cost was loading and serving a large image**, where Goose's copy-on-load loses to mmap.
- **A well-built Rust version** (interning, arenas, streaming) erased the representation advantage.
  symidx's build phase was the closest thing to a record-processing workload: Goose was 1.43× *slower* than
  rust-expert there, and at parity on RAM.

So every candidate below is scored against **the best Rust a competent team would write**, arenas included,
and not against idiomatic Rust. Workloads are favoured when dominated by building and processing many small
variable-size records, allocation churn and teardown. They're penalized when dominated by loading large
images or by long-lived mutable shared state.

## 2. Scoring

Four scores from 1 to 5:
- **Fit:** how well the workload matches the measured strengths and avoids the weaknesses.
- **Win:** the expected size of the advantage over the strongest competitor.
- **Commercial:** demand and willingness to pay.
- **Risk:** adoption risk, where **5 is riskiest**.

Composite = Fit + Win + Commercial + (6 − Risk), out of 20. The composite is a sorting aid, not a measurement.

## 3. Candidates

### 1. Request-scoped API and RPC transform kernels

Services that decode a request (JSON or a binary RPC message), build a response object from small
variable-size fields, render it, and discard everything: API gateways, BFF layers, GraphQL resolvers'
response shaping, feed and search-result rendering. This is the closest real-world match to upstream's
`respond` and `records` benchmarks, the largest Goose wins on record. The demand signal is that the
incumbents already work around allocation here: protobuf's C++ arenas exist because allocation and
deallocation are a large share of message-handling CPU, and they're aimed at request-scoped work. Goose
does that by default, with no lifetime annotations. The realistic product is not a whole server: Goose has
no HTTP, TLS or async ecosystem. It's the transform core, run in worker processes behind an existing proxy
or called through C.

- **Relies on:** inline variable-size records, in-place construction, O(1) per-request teardown, share-nothing workers.
- **Could break it:** request handling in real services is often dominated by I/O and TLS, so the kernel's
  win gets diluted. Shared state such as caches and config can't be shared between workers, only copied.
  Embedding in a multithreaded server is blocked by the library threading rule. Rust's DTO baseline upstream
  may not be the best Rust: an arena-based serde would narrow the gap.
- **Competitor to beat:** Rust with serde plus a per-request arena (bumpalo), and C++ protobuf arenas. Goose
  must beat their throughput per core or their peak RSS by ≥ 1.3×.
- **Demand:** protobuf's arena guide on allocation cost [S7]; Cloudflare's Pingora serves over a trillion
  requests a day, and Cloudflare's write-up ties its rewrite to CPU and memory savings [S8].
- **Scores:**
  - Fit 4: the closest match to the best upstream benchmarks.
  - Win 3: up to 2.6× on the kernel, diluted by I/O.
  - Commercial 4: every API company runs this code.
  - Risk 4: no server ecosystem, and threading limits embedding.
- **Falsification test (2 days):** reshape a public JSON event stream (for example GitHub Archive hourly
  events) into a response DTO and render it as JSON, 1M times in-process with no network. Compare Goose
  (stdlib `json`) against Rust serde_json with a bumpalo arena per request. **Kill** if Goose isn't ≥ 1.3×
  faster per core *or* ≥ 1.3× lower in peak RSS, with byte-identical output.

### 2. Log and telemetry parsing and transformation

Observability agents and pipelines parse log lines into structured events with a handful of variable-size
fields, filter, enrich and batch them, then serialize and ship them. Each batch is built, transformed and
dropped, which is exactly Goose's memory model. The market is large and performance-sensitive: CPU and
memory spent in agents are a direct cost on every host. Datadog bought Vector's company for its pipeline,
and Fluent Bit (written in C) reports over 15 billion deployments. Because Fluent Bit is C, a Goose kernel
compiled to C is an unusually natural fit for a filter or parser plugin. The threading rule decides whether
that's practical.

- **Relies on:** variable-size records, batch teardown, C output for plugins into C agents.
- **Could break it:** agents are long-running, with buffers, retries and config reloads, and that's
  long-lived state. The value is in the hundreds of input and output connectors, not the parser. The
  library threading rule may rule out in-process plugins in multithreaded agents. Our symidx build phase,
  also line parsing into small records, was 1.43× slower than rust-expert.
- **Competitor to beat:** Vector (Rust) for pipelines, Fluent Bit (C) for agents. Goose must beat
  Vector-style Rust parsing, with the best arena implementation, by ≥ 1.3× in throughput or memory.
- **Demand:** Fluent Bit's self-reported 15B+ deployments [S9]; Datadog's acquisition of Timber (Vector) [S10].
- **Scores:**
  - Fit 4: the record shape matches, with batch teardown.
  - Win 3: the kernel only; parsing may be I/O- or regex-bound.
  - Commercial 4: a direct cost line for every observability buyer.
  - Risk 4: connectors and the threading rule.
- **Falsification test (2 days):** parse 10M lines of a Loghub dataset [S11] (for example HDFS or Apache) into
  events with about 8 fields, drop and enrich by rule, and emit NDJSON. Compare Goose against Rust (owned
  `String`s, and a bumpalo variant). **Kill** if Goose isn't ≥ 1.3× faster or ≥ 1.3× smaller in peak RSS
  than the better Rust, at identical output.

### 3. Memory-safe parsers for untrusted input, shipped as C

C and C++ codebases are under regulatory and security pressure to stop parsing hostile input in
memory-unsafe code. CISA's memory-safe roadmap guidance cites about 70% of Microsoft's CVEs and about 70%
of Chromium's vulnerabilities as memory-safety bugs. Goose compiles to one C file, is memory safe without
annotations, and has a free verified loader for its own formats. A team that can't adopt a Rust toolchain
could vendor a Goose-generated `.c` file, as teams already do with Wuffs. The catch is architectural: Goose's
library mode is single-threaded and aborts on a failed check. It therefore fits best where security
architecture already wants it, a sandboxed parser process that may crash safely, rather than an in-process
library.

- **Relies on:** memory safety, C output, the validating loader, abort-instead-of-corrupt.
- **Could break it:**
  - Exported functions run only on the initializing thread.
  - An abort takes the host down.
  - Each data stack reserves 2 GB of address space, which is unwelcome in a host process.
  - Wuffs already offers compile-time-proven safety with no runtime checks, also as C.
  - Rust plus a C ABI is the default answer.
- **Competitor to beat:** Wuffs (for the formats it covers) and Rust with cbindgen. Goose must be within 1.3×
  of the C original's speed, and be easier to adopt than Rust for a C team.
- **Demand:** CISA's memory-safe roadmap guidance [S12][S13]. The class of bug is real: cmark-gfm's table
  parser had an integer overflow leading to heap corruption, rated critical, with RCE possible on
  user-controlled Markdown [S14]. Wuffs shows that "safe language, emitted as C" can be adopted, in Chromium
  and Skia [S15].
- **Scores:**
  - Fit 3: the safety fits, the library model doesn't.
  - Win 3: the win is safety at near-C speed, not raw speed.
  - Commercial 4: regulatory pressure, real budgets.
  - Risk 5: the threading and abort rules, plus Wuffs and Rust already being there.
- **Falsification test (1–2 days):** port cmark-gfm's table extension (the code behind the critical CVE) to
  Goose as a `--standalone` library. Run it from a C harness over a table-heavy corpus and the CVE reproducer.
  **Kill** if any of these holds:
  - it's > 1.3× slower than the patched C;
  - a malformed input can't be turned into an error return instead of an abort;
  - the port needs more than about 2× the C's lines.

### 4. Genomics record processing (FASTQ, SAM, VCF)

Sequencing files are streams of small variable-size records: read names, sequences and quality strings in
FASTQ; variable INFO and genotype fields in VCF. Pipelines parse, filter and rewrite them in batch and
throw everything away. That's the `records` shape, Goose's best-documented win. Data volumes are large:
NIH reported the Sequence Read Archive at tens of petabytes in 2020 and growing. Incumbents are htslib (C)
and noodles (Rust). The weak side is commercial: much of the field is academic, and tools are adopted
through Python and R bindings.

- **Relies on:** inline variable-size records, streaming batch teardown, C interop (libdeflate for BGZF).
- **Could break it:** decompression often dominates; bindings into Python and R hit the library threading
  rule; the field values a decade of htslib compatibility over speed.
- **Competitor to beat:** htslib (bcftools) and noodles. Goose must beat the better of the two by ≥ 1.3× on a
  record-heavy transform.
- **Demand:** SRA size and growth (NIH SRA working group) [S16]; htslib's role as the community's C core [S17].
- **Scores:**
  - Fit 4: the record shape matches well.
  - Win 3: decompression dilutes the win.
  - Commercial 2: academic, binding-driven adoption.
  - Risk 4: ecosystem and compatibility expectations.
- **Falsification test (2 days):** parse the INFO fields of a public VCF (1000 Genomes chr22), filter on allele
  frequency and write VCF. Compare Goose (libdeflate through C) against `bcftools view` and noodles.
  **Kill** if Goose isn't ≥ 1.3× faster or leaner than the better of the two, with identical output.

### 5. Batch developer-tool front-ends: linters, formatters, compilers

Parse each file into an AST, analyze it, report, and drop it. That's the `interp` and `sexp` shape: trees of
variable-size nodes, built and torn down per file. Demand for fast native tooling is proven, with VoidZero
raising a Series A and OpenAI acquiring Astral (Ruff, uv). But the leaders already did what Goose does by
default: Oxc allocates its AST in a bump arena and credits that with about 20%. Goose would compete with
arena Rust, where upstream shows its smaller margins, and on ecosystem breadth (grammars, Unicode, LSP),
where it has none. Language servers are long-lived mutable state, symidx's losing shape. Batch CLI tools
are the only part that fits.

- **Relies on:** variable-size tree nodes, O(1) per-file teardown, in-place construction.
- **Could break it:** the recursion rule (growable data can't cross a recursive call) fights
  recursive-descent parsers; arena Rust already captures most of the allocation win; there's no ecosystem.
- **Competitor to beat:** Oxc and Ruff, both arena-based Rust. Goose must parse and lint ≥ 1.3× faster or with
  ≥ 1.3× less memory.
- **Demand:** VoidZero's $12.5M Series A [S18]; Astral's acquisition by OpenAI [S19]; Oxc's arena design [S20].
- **Scores:**
  - Fit 3: the tree shape fits, the recursion rule doesn't.
  - Win 2: arena Rust is the bar.
  - Commercial 4: proven demand.
  - Risk 4: ecosystem, and entrenched Rust tools.
- **Falsification test (2 days):** parse a fixed JSON-like or S-expression language (not JS: too big for
  2 days) into an AST and run three lint rules, over 1 GB of input. Compare Goose against Rust with bumpalo.
  **Kill** if < 1.3× on time or memory.

### 6. Markup rendering: Markdown and templates (plausible, overlaps with 3)

Markdown-to-HTML and template rendering build a small tree of variable-size nodes per document and discard
it. That fits Goose well. The C incumbent's CVE history (cmark-gfm) adds a safety argument. But the market is
small and the Rust alternatives (pulldown-cmark, comrak) are already safe. This is best treated as the
concrete product for candidate 3, not a business of its own.

- **Relies on:** per-document trees, teardown, C output.
- **Could break it:** Rust alternatives already provide the safety; the market is small.
- **Competitor to beat:** pulldown-cmark (Rust), cmark-gfm (C).
- **Demand:** cmark-gfm advisories [S14].
- **Scores:**
  - Fit 4: the shape fits.
  - Win 2: safe Rust exists, so it's speed only.
  - Commercial 2: a niche.
  - Risk 4: there's no reason to switch from Rust.
- **Falsification test (1 day):** CommonMark-subset rendering of a large Markdown corpus, against
  pulldown-cmark. **Kill** at < 1.3×.

### 7. ETL of semi-structured data (plausible)

Converting NDJSON or CSV into typed records and then into another format is build-and-emit work with
batch teardown. The incumbents are very strong at the tokenizing step: simdjson parses gigabytes per second
and sits inside ClickHouse, Velox and Node.js. Goose's lever would be the materialized records after
parsing, not the tokenizer, so the win is narrow.

- **Relies on:** variable-size records, batch teardown.
- **Could break it:** SIMD tokenizers dominate; columnar targets favour flat arrays, where Goose has no edge.
- **Competitor to beat:** simdjson (C++), simd-json and serde (Rust), Arrow writers.
- **Demand:** simdjson's paper and its adopters [S21].
- **Scores:**
  - Fit 3: records yes, columnar no.
  - Win 2: the tokenizer bar is very high.
  - Commercial 3: the data-tooling market.
  - Risk 4: entrenched libraries.
- **Falsification test (1–2 days):** NDJSON to typed records to CSV, against Rust (simd-json plus owned
  structs). **Kill** at < 1.3×.

### 8. Expression and policy evaluation (plausible, weak)

Policy engines and expression languages (CEL in Kubernetes admission and Google Cloud, OPA's Rego) parse an
expression into a tree and evaluate it against small structured inputs many times. Upstream `interp`
(1.29–1.41×, 2× less memory) supports the tree side, but `calc` loses to a Rust arena. These engines live
inside Go and Java hosts, so the library threading rule is close to fatal.

- **Relies on:** trees, per-evaluation teardown.
- **Could break it:** embedding in Go or Java hosts; the `calc` loss; long-lived compiled policies.
- **Competitor to beat:** cel-go, cel-cpp, OPA.
- **Demand:** OPA's CNCF graduation and production users [S22]; CEL in Kubernetes validating admission policies [S23].
- **Scores:**
  - Fit 3: the trees fit.
  - Win 2: mixed upstream evidence.
  - Commercial 3: policy-as-code.
  - Risk 5: embedding in Go and Java.
- **Falsification test (2 days):** a CEL subset evaluator over 1M records, against cel-go. **Kill** at < 1.3×.

### 9. Batch graph analytics (speculative)

Upstream's check-free CSR BFS is 1.12–1.32× ahead. But graphs are fixed-size records, where Goose has no
layout edge, and parallel graph kernels need a shared read-only graph. Goose's share-nothing workers would
have to copy it.

- **Relies on:** index types, check-free kernels.
- **Could break it:** no shared-memory parallelism; GAP's OpenMP reference is the bar.
- **Competitor to beat:** the GAP reference (C++/OpenMP) [S24].
- **Demand:** a research benchmark; a modest market.
- **Scores:**
  - Fit 2: fixed-size records, parallel sharing needed.
  - Win 2: 1.1–1.3× single-threaded at best.
  - Commercial 2: a niche.
  - Risk 4: parallelism.
- **Falsification test (1 day):** GAP BFS on a 2²⁴-vertex Kronecker graph, single-threaded and parallel,
  against gapbs. **Kill** if parallel is slower than gapbs.

### 10. Search index segment building (speculative)

Building an inverted-index segment means tokenizing documents into variable-size postings lists: build-heavy,
which Goose likes. But a search engine is mostly serving segments, which is symidx's losing shape until
goose#221 lands. Building alone isn't a product.

- **Relies on:** variable-size postings, build-phase teardown.
- **Could break it:** serving is the load-and-mmap workload Goose lost.
- **Competitor to beat:** Tantivy (Rust), now inside Datadog via Quickwit [S25].
- **Demand:** Datadog's Quickwit acquisition [S25].
- **Scores:**
  - Fit 2: build yes, serve no.
  - Win 2: build only.
  - Commercial 3: log search is valuable.
  - Risk 5: serving needs #221.
- **Falsification test (1–2 days):** postings construction for a 1 GB Wikipedia sample, against Tantivy's
  indexer with merging disabled. **Kill** at < 1.3×.

### 11. Game frame-scoped data (speculative)

Per-frame temporaries are already allocated from frame arenas that are reset each frame, standard practice
in C++ engines. So Goose's model mostly matches what engines already do by hand. Upstream `scene` is a tie
or loss, and particle kernels show no language advantage. Goose ships `gfx`, `physics` and `audio` stdlib
modules, but there's no console or engine ecosystem.

- **Relies on:** frame-scoped teardown, in-place construction.
- **Could break it:** engines already use frame arenas; long-lived mutable world state is the losing shape;
  no console toolchains.
- **Competitor to beat:** C++ with frame allocators [S26].
- **Demand:** large, but not reachable.
- **Scores:**
  - Fit 2: mostly long-lived state.
  - Win 1: ties upstream.
  - Commercial 2: unreachable.
  - Risk 5: ecosystem.
- **Falsification test (1 day):** a per-frame particle and command-list simulation against C++ with a frame
  arena. **Kill** at < 1.2×.

## 4. Ranked table

| Rank | Candidate | Fit | Win | Commercial | Risk | Composite | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | Request-scoped API/RPC transform kernels | 4 | 3 | 4 | 4 | 13 | ~~strong: test first~~ **falsified** (experiment 2) |
| 2 | Log and telemetry parsing and transformation | 4 | 3 | 4 | 4 | 13 | ~~strong: test with 1~~ **falsified** (experiment 2) |
| 3 | Memory-safe parsers for untrusted input, as C | 3 | 3 | 4 | 5 | 11 | strong on demand, blocked on embedding |
| 4 | Genomics record processing | 4 | 3 | 2 | 4 | 11 | ~~plausible~~ main argument gone (experiment 2) |
| 5 | Batch dev-tool front-ends | 3 | 2 | 4 | 4 | 11 | plausible: arena Rust is the bar |
| 6 | Markup rendering | 4 | 2 | 2 | 4 | 10 | plausible: a product for 3 |
| 7 | ETL of semi-structured data | 3 | 2 | 3 | 4 | 10 | ~~speculative~~ main argument gone (experiment 2) |
| 8 | Expression and policy evaluation | 3 | 2 | 3 | 5 | 9 | speculative |
| 9 | Batch graph analytics | 2 | 2 | 2 | 4 | 8 | speculative |
| 10 | Search index segment building | 2 | 2 | 3 | 5 | 8 | speculative until #221 |
| 11 | Game frame-scoped data | 2 | 1 | 2 | 5 | 6 | speculative |

Ties at 11 are broken by expected win, then commercial score.

## 5. Top 3 and the first experiment

1. **Request-scoped transform kernels** and 2. **log and telemetry parsing** are the same mechanism: parse
   variable-size records, transform them, emit, drop. **Recommended first experiment: one shared 2-day
   benchmark.** Parse a public dataset (Loghub lines and GitHub Archive events) into records, transform
   them, and render NDJSON. Run it in Goose and in the best Rust: serde with a bumpalo arena per batch,
   written by someone who'd write rust-expert, not rust-idiomatic. Use byte-identical output, symidx's
   harness (`env.txt`, CI on Linux and macOS), and the kill criterion **≥ 1.3× on throughput per core or on
   peak RSS against the better Rust**. If it fails, candidates 1, 2, 4 and 7 all lose their main argument,
   which makes this the highest-information experiment available. **Run as experiment 2: it failed**
   (0.88× throughput, 1.07× RSS; [report](../experiments/02-logxform/REPORT.md)).
3. **Memory-safe parsers as C.** The demand is the strongest on the list, and the blockers are documented
   rather than measured. **First experiment:** port cmark-gfm's table extension as a `--standalone` library
   (candidate 3's test). Answer three questions in a day: speed against C, error return against abort, and
   lines of code. If it passes, the next blocker is the library threading rule, which is upstream design,
   not benchmarking.

## 6. Where Goose is a poor fit

- **Serving large read-mostly images:** symidx's instant-start index, search serving, caches of
  precomputed data. `from_bytes` copies, so serving memory is 2–3× and warm load 10–25× worse than mmap,
  until something like goose#221 exists.
- **Long-lived mutable shared state:** in-memory databases, caches and LRUs (upstream `lru` loses or ties),
  language servers, game worlds, connection pools shared across workers.
- **Embedding in multithreaded hosts:** browsers, JVM/Go/Python services, multithreaded C++ servers.
  Exported functions are single-thread and a failed check aborts the host.
- **WebAssembly and edge runtimes, microcontrollers:** data stacks need address-space reservation, and the
  WebAssembly port is a proposal.
- **Flat numeric kernels:** image filters, particles, linear algebra. Upstream shows parity: no layout edge to exploit.
- **Plugin and dynamic-dispatch architectures:** no function pointers, no escaping closures,
  whole-program compilation.
- **Ecosystem-bound applications:** web backends needing database drivers, HTTP/2, TLS and cloud SDKs.
  Everything goes through C interop.

## Sources

Goose itself and this project:
- [R] symidx report: [bench/REPORT.md](../bench/REPORT.md)
- [S1] Goose README, "Why Goose" and "What it costs you": https://github.com/aardappel/goose
- [S2] Goose benchmark summary (October 2026 run): https://github.com/aardappel/goose/blob/master/bench/summary.md
- [S3] Goose reference, `export fn` (§24) and bounds checks (§16), shipped as `docs/reference.md` in release v2026.3: https://github.com/aardappel/goose/blob/master/docs/reference.md
- [S4] goose#221, verified zero-copy view request: https://github.com/aardappel/goose/issues/221
- [S5] Goose design note, running on WebAssembly (proposal): https://github.com/aardappel/goose/blob/master/docs/design/wasm.md
- [S6] goose#177, `from_bytes` and `append`: https://github.com/aardappel/goose/issues/177

Market and competitors:
- [S7] Protocol Buffers, C++ arena allocation guide: https://protobuf.dev/reference/cpp/arenas
- [S8] Cloudflare, how we built Pingora: https://blog.cloudflare.com/how-we-built-pingora-the-proxy-that-connects-cloudflare-to-the-internet/
- [S9] Fluent Bit home page (deployment count): https://fluentbit.io/ ; CNCF, Fluent Bit passes three billion downloads: https://cncf.io/blog/2022/10/13/fluent-bit-surpasses-three-billion-downloads
- [S10] Datadog acquires Timber Technologies (Vector): https://datadoghq.com/about/latest-news/press-releases/datadog-acquires-timber-technologies/
- [S11] Loghub, a large collection of system log datasets: https://arxiv.org/abs/2008.06448
- [S12] CISA et al., The Case for Memory Safe Roadmaps: https://cisa.gov/case-memory-safe-roadmaps
- [S13] The Register on the same guidance and the Microsoft and Chromium shares it cites: https://www.theregister.com/2023/12/07/memory_correction_five_eyes/
- [S14] cmark-gfm CVE-2022-24724 (table row integer overflow): https://releasealert.dev/cve/CVE-2022-24724
- [S15] Wuffs README (Chromium copy): https://chromium.googlesource.com/chromium/src/+/de982caac9d9bfd48edd20568fa9e48192e95d0d/third_party/wuffs/README.chromium
- [S16] NIH SRA Data Working Group report, 2020 (may refuse automated downloads): https://dpcpsi.nih.gov/sites/default/files/2.15PM-SRA_Data_WG_Report_Gregurick_Johnson_508.pdf ; Petabyte Scale Sequence Search Codeathon (2025), on searching the rapidly growing SRA: https://arxiv.org/abs/2505.06395
- [S17] HTSlib paper: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7931820/
- [S18] VoidZero Series A: https://www.dealstreetasia.com/stories/voidzero-accel-461657
- [S19] OpenAI's acquisition of Astral: https://www.businesstoday.in/technology/story/openais-astral-deal-reveals-hidden-funding-rounds-investor-windfall-simon-willison-521585-2026-03-20
- [S20] Oxc parser architecture (arena-allocated AST): https://oxc.rs/docs/learn/architecture/parser.md ; Oxc performance notes: https://oxc.rs/docs/learn/performance
- [S21] Langdale and Lemire, Parsing Gigabytes of JSON per Second: https://arxiv.org/abs/1902.08318
- [S22] CNCF, Open Policy Agent graduation: https://www.cncf.io/announcements/2021/02/04/cloud-native-computing-foundation-announces-open-policy-agent-graduation/
- [S23] Kubernetes blog, validating admission policies with CEL: https://v1-35.docs.kubernetes.io/blog/2022/12/20/validating-admission-policies-alpha/
- [S24] Beamer, Asanović, Patterson, The GAP Benchmark Suite: https://arxiv.org/pdf/1508.03619
- [S25] Datadog acquires Quickwit: https://datadoghq.com/blog/datadog-acquires-quickwit/
- [S26] Temporary allocations in C/C++ (frame arenas): https://dev.to/jonahgoldsmith/temporary-allocations-in-cc-oi8
