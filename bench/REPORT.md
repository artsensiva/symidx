# symidx report: Goose vs Rust for an instant-start symbol index

2026-11-01, cross-platform and cold-cache confirmation added 2026-11-03. Data: `bench/results/20261101-132456/`
(implementations) and `bench/results/baselines-20261101-132720/` (market baselines); CI runs as linked below.

## Verdict

**The large project should be built in Rust.** The verdict rests on the refined reading of the kill
criterion (below): Goose's serving memory is 2.0–3.1× worse than rust-expert's on every platform measured,
warm and cold.

The criterion is "no ≥ 1.3× memory win over rust-expert". On the reference machine (Linux), against the
fairness-corrected (streaming) rust-expert, Goose has none:

| Memory metric | M | L |
|---|---|---|
| Peak RAM, build | 1.04× **more** (14.6 vs 14.1 MB) | 1.04× **more** (111 vs 106 MB) |
| Peak RAM, serving a selective query | 2.0× **more** (11.4 vs 5.6 MB) | 2.6× **more** (116 vs 44 MB) |
| Peak RAM, serving a full-index query | 1.8× **more** (12.3 vs 6.7 MB) | 2.7× **more** (122 vs 45 MB) |
| Image size | 1.20× smaller (3.00 vs 3.62 MB) | 1.12× smaller (39.3 vs 43.9 MB) |

Image size is the only memory-like metric Goose wins, and it's below the 1.3× target on both corpora.
Goose also loads 10–25× slower than rust-expert with a warm cache, and 1–2× slower cold (parity on the
macOS CI VM; see "Cross-platform and cold-cache confirmation").

### Criterion refinement

The original kill criterion (CLAUDE.md's target table) targeted **build RAM**. Serving memory was added
mid-experiment as the primary metric, because an always-resident server pays it constantly, while builds
are rare. Both readings, side by side:

| Reading | Linux (local, CI) | macOS CI VM |
|---|---|---|
| **Literal:** build RAM, Goose ≥ 1.3× less? | not met (parity, within ±4%) | **met** in 3 of 4 runs: 1.28–1.50× less (low confidence, uninvestigated) |
| **Refined:** serving memory, Goose ≥ 1.3× less? | not met: 2.0–2.7× **more** | not met: 3.1× **more** |

So the literal criterion is not met on Linux and is met, narrowly and not in every run, on the macOS CI VM. The refined criterion is not
met anywhere, warm or cold. **The verdict (Rust) rests on the refined criterion**, and on the load gap; the
literal one alone would not decide it on macOS. This is a negative result for Goose for this workload, and
the experiment did its job.

## What belongs to Goose, and what to the layout

Most of the gap between the first Rust version and Goose came from **the compact layout**, which Rust
can use too:

- **Interning, grouping by name, one arena per string kind.** This is what makes images 5–17× smaller than
  SQLite and ctags. rust-expert uses all of it: 3.62 MB on M, against 17.7 MB (SQLite) and 20.1 MB (ctags).
- **Streaming the build through a bounded window.** Goose's first build already did this; rust-expert's
  didn't, and used 1.9× (M) and 3.7× (L) more build RAM. Once rust-expert streams, the difference is gone.
  The earlier "Goose uses 2.9× less build RAM" was an artifact of my first rust-expert, not of the language.

What does belong to **Goose as a language**:

- **Inline variable-size records** (`u8[varint]` names, a `varint` line, nested `Occ[varint]`). They're the
  whole of Goose's remaining 1.12–1.20× image advantage: about 7 bytes an occurrence and no offset tables,
  against 8-byte occurrences plus two 4-byte offset tables in rust-expert. A Rust layout could close most of
  this gap too, with a varint-packed occurrence stream, at the price of hand-written decoding.
- **A validating loader for free.** `from_bytes` checks structure, every index type and every bound type.
  The remaining checks are a short pass. rust-expert needs bytecheck plus a hand-written `validate`, and a
  mistake in it would be unsound. This is real, but it's development cost and safety, not a metric here.
- **The cost side, also the language's:** `from_bytes` always copies into fresh memory. A load pays for the
  read buffer, the copy and a verify walk, and both the source and the copy are resident at once. That's why
  Goose serves at about 2× image size while rkyv-over-mmap serves at about 1×. And why Goose's load can't
  approach rust-expert's: on L, `read_file` alone takes 27 ms, five times rust-expert's whole 5.3 ms load.
  Goose has no way to verify bytes in place over foreign memory (`bytes_of` views are read-only and only
  over Goose arrays).

## Recommendation for the large project

Build it in Rust, with rust-expert's approach as the baseline:

- interned names and paths in arenas, occurrences grouped by name, one fixed-size occurrence array;
- `rkyv` with `bytecheck` over an mmap, followed by an explicit eager validation pass (SPEC);
- a streaming build with a bounded channel.

If image size starts to matter, try a varint-packed occurrence stream behind the same API. Revisit Goose
if `from_bytes` ever gets an in-place, zero-copy verified view (over an mmap or a read buffer). That one
change would remove both its load and serving-memory deficits.

## Methodology

- **Task** (`bench/SPEC.md`): walk `*.py`, find `def` and `class` lines, save an index (name, kind, file, line),
  answer name-prefix queries. All three implementations produce byte-identical `find` output, checked by
  sha256 against `bench/ref.py` on every corpus. All intern names and paths, and verify the whole image
  eagerly before any query.
- **Corpus** (`corpus/make.sh`): S = Django 6.1.2 (0.52M lines), M = S + CPython v3.14.10 (1.6M lines),
  L = M × 31 (49.7M lines). L's names repeat 31 times, so M is the primary memory comparison.
- **Implementations:**
  - `goose/`: Goose v2026.3, built with system clang 21 (`goose/build.sh`).
  - `rust-idiomatic/`: owned `Vec`s, serde + bincode 1.3 + `serde_bytes`, rayon.
  - `rust-expert/`: FxHash interning into arenas, 8-byte occurrences, rkyv 0.8 over mmap, streaming build.
    `rust-expert-batch` is its first build (all parsed text held, 16-byte sort keys), kept for comparison.
  - Rust: rustc 1.99.1, release, LTO, one codegen unit.
- **Harness:** `bench/run.sh` and `bench/baselines/run.sh`. Times are hyperfine means of whole processes,
  3 runs for build and 10 otherwise; build and serving RSS come from `/usr/bin/time`. "Find" is the mean over
  prefixes `get_ test Model _`, one process each, load included. "Serving" is the peak RSS of one process
  that loads and answers `""` (the whole index) or `Model` (selective).
- **Machine:** 6 cores, 15 GB RAM with only 2–4 GB free (desktop apps open), `powersave` governor, warm page
  cache. Expect noise of a few percent. Cold-cache runs need passwordless sudo, which this machine lacks;
  they were done in CI instead ("Cross-platform and cold-cache confirmation").
- **Timing caveat:** in this run every build command was wrapped in `env` (one extra exec, ~2 ms), equally for
  all implementations. That's under 3% of an M build; `bench/run.sh` has since been fixed.
- **Tuning parity:** no Linux-specific tuning in any implementation. Pre-faulting (`madvise` populate +
  huge pages) was measured for Goose (load -20–27%) and not applied, so Rust got no `MAP_POPULATE` either.
  It changes time, not RSS, so it doesn't affect the verdict.

## Results

| Impl | Corpus | Build | Build RAM | Image | Load | Find | Serve full | Serve selective |
|---|---|---|---|---|---|---|---|---|
| goose | S | 47 ms | 7.9 MB | 1.18 MB | 5.0 ms | 5.5 ms | 6.9 MB | 5.8 MB |
| rust-idiomatic | S | 38 ms | 12.2 MB | 1.81 MB | 7.5 ms | 8.1 ms | 7.6 MB | 7.6 MB |
| rust-expert | S | 35 ms | 8.2 MB | 1.39 MB | 1.0 ms | 1.5 ms | 4.6 MB | 3.6 MB |
| rust-expert-batch | S | 36 ms | 12.3 MB | 1.39 MB | 1.0 ms | 1.5 ms | 4.6 MB | 3.6 MB |
| goose | M | 106 ms | 14.6 MB | 3.00 MB | 12.2 ms | 12.5 ms | 12.3 MB | 11.4 MB |
| rust-idiomatic | M | 90 ms | 29.5 MB | 4.82 MB | 18.6 ms | 20.4 ms | 16.7 MB | 16.6 MB |
| rust-expert | M | 74 ms | 14.1 MB | 3.62 MB | 1.3 ms | 2.2 ms | 6.7 MB | 5.6 MB |
| rust-expert-batch | M | 76 ms | 26.8 MB | 3.62 MB | 1.3 ms | 2.2 ms | 6.7 MB | 5.6 MB |
| goose | L | 5.37 s | 111 MB | 39.3 MB | 134 ms | 148 ms | 122 MB | 116 MB |
| rust-idiomatic | L | 5.97 s | 442 MB | 61.7 MB | 106 ms | 144 ms | 129 MB | 129 MB |
| rust-expert | L | 4.84 s | 106 MB | 43.9 MB | 5.3 ms | 20.4 ms | 45 MB | 44 MB |
| rust-expert-batch | L | 4.66 s | 388 MB | 43.9 MB | 5.1 ms | 20.2 ms | 45 MB | 45 MB |

MB = 1024² bytes for RAM, 10⁶ bytes for image sizes. Checksums match on every row.

Against the CLAUDE.md targets (Goose vs rust-expert, M):

| Metric | Target | Result |
|---|---|---|
| Peak RAM (build) | ≥ 1.3× less | 1.04× more: missed |
| Image size | ≥ 1.3× smaller | 1.20× smaller: missed |
| Cold load | ≈ parity | 10× slower warm; 2× slower cold on CI Linux, parity on the macOS CI VM: missed on Linux |
| Build time | ≈ parity | 1.43× slower |
| Prefix find | parity | 5.6× slower (load included) |

Against rust-idiomatic, Goose does meet most of its targets on M: 2.0× less build RAM, a 1.6× smaller
image, 1.5× faster load. That's the compact layout against an idiomatic one, not Goose against Rust.

### Market baselines

Performance only. ctags parses differently (classes, functions and members: 131k tags on M, against 133k
symbols), so it isn't checksum-matched. SQLite reuses `bench/ref.py`'s parser in Python, with a plain,
non-interned schema and an index on (name, file, line), and does match.

| Baseline | Corpus | Build | Build RAM | Index | Query (mean of 4) | Selective (`Model`) | Serve full | Serve selective |
|---|---|---|---|---|---|---|---|---|
| ctags + readtags | M | 1.23 s | 33 MB | 20.1 MB | 14.9 ms | 1.3 ms | 21 MB | 2.2 MB |
| SQLite (Python) | M | 2.26 s | 38 MB | 17.7 MB | 57.8 ms | 22.6 ms | 14.3 MB | 12.9 MB |
| ctags + readtags | L | 51.8 s | 803 MB | 652 MB | 433 ms | 13.8 ms | 589 MB | 4.5 MB |
| SQLite (Python) | L | 98.1 s | 673 MB | 612 MB | 1440 ms | 47.9 ms | 14.3 MB | 14.4 MB |

SQLite query times include 15 ms of Python startup. For comparison, the selective `Model` query takes:

| | M | L |
|---|---|---|
| goose | 11.6 ms | 132 ms |
| rust-expert | 1.3 ms | 5.9 ms |
| readtags | 1.3 ms | 13.8 ms |

What this says:
- **Selective queries:** ctags/readtags and SQLite have no load step. A selective lookup costs a binary
  search on disk. Goose's one-shot query pays a full load, so readtags is 9× faster on M and 10× on L.
- **Index size:** Goose and rust-expert both beat these baselines 5–17×. That's the compact layout again.
- **Long-running server:** a resident language server pays the load once. So serving memory and image size
  matter more than one-shot latency, and on serving memory rust-expert is better than Goose.

### Goose load: where the time goes, and what was tried

`SYMIDX_PROFILE=1` (`spike/FINDINGS.md`, "Load profile"), M: `read_file` 2.2 ms, `from_bytes` of groups
5.8 ms, validation + index 2.0 ms, everything else 0.3 ms, for about 0.3 GB/s overall. About half of
`from_bytes` is first-touch page faults on fresh memory (about 4 µs each on this machine), and the rest is
verify + copy at about 1 GB/s.

| Option | M load | L load | M image | L image | Serving (L, sel.) | Adopted |
|---|---|---|---|---|---|---|
| layout A (current) | 10.2 ms | 128 ms | 3.00 MB | 39.3 MB | 116 MB | yes |
| layout D′: flat 8-byte `Occ` array, group = name + count | 7.5 ms | 89 ms | 3.16 MB | 44.0 MB | 128 MB | no |
| pre-fault (madvise populate + THP) | -27% | -20% | same | same | same | no |

Layout D′ (`spike/layout_dprime/`) is 27–30% faster to load. But it's larger and uses more serving memory,
and memory is the primary metric. Even its load is 17× slower than rust-expert's on L. Neither option
changes the verdict.

## Cross-platform and cold-cache confirmation

Goose vs rust-expert on M, one table per environment. CI is `.github/workflows/bench.yml`
([run 41640770345](https://github.com/artsensiva/symidx/actions/runs/41640770345)), RUNS=3; cold means the
page cache is emptied before every timed load and find run (`COLD=1`: `drop_caches` on Linux, `purge` on
macOS). Serving RSS and image size don't depend on the cache state; they're shown for both rows. Each row's
`env.txt` is in the run's artifacts.

**Local Linux** (i5-8400T, 6 cores, NVMe, `powersave`; `bench/results/local-warm-final/`, RUNS=10). Cold:
not measured, no passwordless sudo.

| Goose / rust-expert | Load | Find | Serving RSS (selective) | Image |
|---|---|---|---|---|
| warm | 11.8 / 1.2 ms (9.5×) | 12.9 / 2.3 ms | 11.6 / 5.7 MB (2.0×) | 3.00 / 3.62 MB |

**CI Linux** (ubuntu-latest: AMD EPYC 7763, 4 vCPUs, Azure VM).

| Goose / rust-expert | Load | Find | Serving RSS (selective) | Image |
|---|---|---|---|---|
| warm | 10.8 / 1.0 ms (10.5×) | 12.8 / 1.8 ms | 11.3 / 5.6 MB (2.0×) | 3.00 / 3.62 MB |
| cold | 18.4 / 9.3 ms (2.0×) | 20.1 / 12.5 ms | 11.3 / 4.1 MB (2.7×) | 3.00 / 3.62 MB |

**CI macOS** (macos-latest: Apple M1, virtual, 3 vCPUs). **Low confidence:** a 3-core VM with a load
average above 40, and 3 runs.

| Goose / rust-expert | Load | Find | Serving RSS (selective) | Image |
|---|---|---|---|---|
| warm | 9.4 / 2.9 ms (3.3×) | 10.0 / 4.4 ms | 10.6 / 3.5 MB (3.1×) | 3.00 / 3.62 MB |
| cold | 121.8 / 119.7 ms (parity) | 129 / 193 ms (Goose faster) | 10.6 / 3.5 MB (3.1×) | 3.00 / 3.62 MB |

Does the verdict hold?
- **Local Linux, CI Linux:** yes, on both readings of the criterion. Serving memory is 2.0–2.7× worse for
  Goose, and build RAM is at parity.
- **CI macOS:** yes on the refined criterion (serving memory 3.1× worse); the literal one is met (below).
- **Cold cache:** the load gap shrinks from 10× to 2× on Linux and to parity on macOS: reading the image from
  storage dominates both, and rust-expert's advantage is not copying it. Serving memory doesn't change.

**Open item, not investigated: macOS build RAM.** In four CI runs on the macOS VM, streaming rust-expert's
build peaked at 17.9–20.8 MB on M against Goose's 13.9 MB (1.28–1.50×), while
on Linux the two are at parity. Possible causes: macOS's allocator keeping freed memory resident, 16 KB pages
coarsening RSS, or the build's buffering on 3 cores.

## Experiment: segmented validation for rust-expert

rust-expert's serving memory roughly equals the parts of the image its eager validation touches: all
offset tables and every occurrence. `SYMIDX_VALIDATE=lazy` (`rust-expert/src/main.rs`) checks structure
(bytecheck) and the O(1) invariants at load. Each 1024-entry chunk of an offset table, and the occurrences a
chunk of groups spans, is checked the first time a query touches it, and before anything from that segment
is returned. The output is identical to eager mode on S, M and L. 1,200 corrupted-image runs gave exit
0 or 1 only. **This doesn't conform to SPEC's eager-validation rule, so it's an experiment, not the default.**

Measured in a separate session from the main run (so eager L numbers differ slightly from the Results tables).

| L (43.9 MB image) | Eager | Lazy |
|---|---|---|
| `load` | 7.9 ms | 1.0 ms |
| `find Model` (12k rows): time / peak RSS | 9.8 ms / 43.3 MB | 2.9 ms / 12.4 MB |
| `find get_` (75k rows) | 12.6 ms / 43.8 MB | 5.8 ms / 13.2 MB |
| `find test` (1.58M rows), RSS | 44.8 MB | 26.1 MB |
| `find ""` (whole index) | 133 ms / 45.1 MB | 137 ms / 45.1 MB |

| M (3.6 MB image) | Eager | Lazy |
|---|---|---|
| `load` | 1.4 ms | 1.0 ms |
| `find Model`: time / peak RSS | 1.5 ms / 4.4 MB | 1.1 ms / 3.3 MB |
| `find ""` | 7.1 ms / 6.6 MB | 7.5 ms / 6.6 MB |

A process that only prints usage peaks at 2.1 MB, so on M most of what's left is the process itself.

**The trade-off.** Selective queries on a large index use 3.5× less memory and run 3.4× faster, and load
becomes constant time. A full-index query costs about 3% more time and the same memory, since it ends up
validating everything. The costs:
- A corrupt segment is found only when a query reaches it, so a query can return rows from valid segments
  and then fail.
- "Load succeeded" no longer means "the image is valid".
- Load-time figures stop being comparable with the eager implementations. That's why SPEC's rule exists.

For a long-running server the gain mostly applies to RSS before the index has been fully touched. Adopting
it for Phase 2 would need a SPEC amendment, for example "validation may be deferred per segment, but must
complete for a segment before any data from it is returned".

## Development time

Logged in `DEVLOG.md`. All three versions were written by the same AI agent in one session, so the minutes
measure agent effort, not human hours, and are only comparable with each other:

| Version | Minutes |
|---|---|
| Goose (spike, v1, profiling) | 20 |
| rust-idiomatic v1 | 2 |
| rust-expert (v1 and the streaming build) | 4 |

The Goose time includes learning the language and finding and diagnosing a compiler bug
([aardappel/goose#177](https://github.com/aardappel/goose/issues/177)).

## Known Goose issues found

- `from_bytes` rejects valid index types into an array grown with `append`: the verifier reads a stale
  length. Filed as aardappel/goose#177. Workaround: grow pinned arrays with `push` (~2% of load).
- `varint` is signed (zigzag), so an image can carry a negative line number. The loader checks `line >= 1`.
- `os.goose` has no `lstat`, and `list_dir`/`is_dir` follow symlinks, so the walk needs a C sidecar.
- Arrays pinned by index types can't be cleared or reassigned, so one process loads one image.
- The default `cc` may be a wrapper (here, `zig cc`). Build with `--cc clang`.
