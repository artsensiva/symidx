# Experiment 3: low-cost Goose patches

Pre-registered 2026-11-04, before any measurement. Goose v2026.3 built from source (tag `v2026.3`,
commit `8511ae3`), patched on a local branch in `toolchain/goose-src` (gitignored). Patches stay local:
nothing is sent upstream. The unpatched source build produces a symidx binary byte-identical to the
release's (sha256 `e23759a4…`), so "base" below is the release.

Each patch is measured against the unpatched source build, with nothing else changed. The method fixes
two weaknesses an outside audit found in the earlier harnesses: runs are **paired and interleaved in
random order** (hyperfine runs one command's repetitions back to back), and each run's wall time and peak
RSS come from the same process (`wait4`). Report the median of the paired ratios and a bootstrap 95%
interval.

## Patch 1: huge pages for large data stacks

- **Change.** The runtime reserves each data stack with `mmap` and already sets `MADV_NOHUGEPAGE` on its
  first 2 MB. The patch sets `MADV_HUGEPAGE` on the rest of the reservation. On a system whose THP mode is
  `madvise` (this one; the Ubuntu default) a stack that grows past 2 MB gets huge pages on touch; under
  `always` it already did.
- **Evidence it might help.** `spike/FINDINGS.md`, "Load profile": about half of `from_bytes` time is
  first-touch page faults; a hand-applied `MADV_POPULATE_WRITE` + `MADV_HUGEPAGE` cut read + groups by
  27% on M and 20% on L.
- **Benchmark.** Phase 1 symidx, warm, local: `load` on M and L (time), `find <img> Model` (serving
  RSS, selective) and `find <img> ""` (full), and `build` on M (time and peak RSS, since huge pages can
  raise RSS).
- **Target.** Warm load at least 15% faster on both M and L, with byte-identical `find` output.
- **Stop.** Less than 10% faster on either size, or any serving or build RSS more than 10% higher.

## Patch 2: verify in place (a read-only view over a Goose-owned buffer)

Specified after patch 1 is measured. Target and stop as stated before work started: selective serving RSS
at most 1.6× rust-expert's on M and 1.9× on L, and L load under 90 ms; stop at 5 days of work or if the
design needs anything other than a read-only view.

**Design, as built** (written before measuring; branch `patch2-from-file` from `v2026.3`, without
patch 1). The buffer the bytes are verified in is the result array's own storage, so no new kind of root
or view type is needed:

- `from_file<T[>..]>(path, at) -> T[>..], i64, bool`, a builtin beside `from_bytes`. It reads the
  `to_bytes` frame at byte `at` of a file: the varint prefix (checked against the file's size), then the
  payload with `pread` straight to the top of the result's data stack. The existing verifier runs over it
  there, and the stack top and count move past it only if it accepts. A rejected frame leaves the array
  empty, as `from_bytes` does; the second result is the offset after the frame, or -1.
- `os.read_file_range(path, at, n, out)`: up to n bytes from `at`, appended straight to `out`'s storage.
- Both rely on the data stack's guard gap, as the runtime's `gs_bld_append` already does: a read that
  runs into it fails with EFAULT, which is reported as an error.
- `patch2/symidx.goose` is `goose/symidx.goose` with only `load` changed: three `from_file` calls replace
  `read_file` + `frame` + `from_bytes`, and `read_file_range` reads the magic and checks for trailing
  bytes. Everything else, including the push-copies of `paths` and `files` and the validation pass that
  builds `group_at`, is unchanged.

**Correctness checks:** `patch2/test_from_file.goose` (valid frames, every rejection path, equality with
`from_bytes`); output against `bench/ref-checksums.txt` on S, M and L; `patch2/corrupt.py` (truncations
and seeded byte flips of the S image: base and patched must agree on every one and never crash); Goose's
own `test/run_tests.py` with the base and patched compilers.

**Benchmark:** `measure.py`, as for patch 1, with three commands per round: base, patched and rust-expert
(this harness's RSS differs from Phase 1's GNU time, so rust-expert is re-measured here). Load: 40
rounds on M and L. Serving: `find <img> Model`, 20 rounds. The targets above are judged on these numbers.

## Results (added after measuring)

Local, warm, pinned to one core, random-order rounds; each round runs every command once for wall time
and once under GNU time for peak RSS. Median, and the median paired ratio with a bootstrap 95% interval.
Raw runs: `data/run2/`. Every build gives byte-identical images and `find` output, matching
`bench/ref-checksums.txt` on S, M and L.

**Correction.** The first run of patch 1 took peak RSS from `wait4`, which never reports less than the
measuring Python process's own ~13 MB (`posix_spawn` shares its memory until exec). Its M serving numbers
were invalid, and its data was replaced. Values above 13 MB (L, build) agreed with the corrected run.

| | base | patch 1 (huge pages) | patch 2 (`from_file`) | rust-expert |
|---|---|---|---|---|
| load M, 40 rounds | 11.69 ms | 11.63 ms (0.99) | 9.30 ms (0.79) | 1.40 ms |
| load L, 40 | 137.1 ms | 89.3 ms (0.64) | **97.2 ms** (0.71) | 5.89 ms |
| `find Model` RSS M, 20 | 11,664 KiB | 14,408 (1.24) | **8,584** (0.74) | 5,692 |
| `find Model` RSS L, 20 | 118,928 KiB | 123,888 (1.04) | **80,400** (0.68) | 45,620 |
| build M, 10 | 258 ms, 14,690 KiB | 259 ms, 17,196 (1.17) | 259 ms, 14,714 (1.00) | — |

Ratios in parentheses are against base; every interval is within ±0.02 of its median.

**Patch 1: fails as registered.** M's load doesn't move (target 15% faster, stop below 10%), and M's
RSS rises 24% (build 17%; stop above 10%). On L, load is 36% faster for 4% more RSS. It trades memory for
speed, the opposite of what Phase 1 needed, and Rust could use huge pages too.

**Patch 2: misses one of its three targets.**
- Selective serving RSS against rust-expert's: **1.51×** on M (target ≤ 1.6, met) and **1.76×** on L
  (target ≤ 1.9, met), from 2.05× and 2.61× at base.
- Load on L: **97.2 ms** (target < 90, missed). It is 29% faster than base and still 16.5× rust-expert's.
- No stop rule fired: about an hour of work, and the design is a read-only verified load with nothing
  beyond it.

Where patch 2's L load goes (`SYMIDX_PROFILE=1`, 3 runs): `from_file groups` 58–61 ms, the validation
pass that builds `group_at` 30–31 ms, paths and files about 10 ms. The whole-image `read_file` (25–33
ms at base) is gone. But reading the groups straight into fresh memory costs as much as verifying and
copying them did (57–71 ms at base): the first-touch page faults moved with the bytes.

**Exploratory, not registered: both patches together** (branch `combo-p1-p2`, `data/run2/combo-*`).
Load is 9.23 ms on M and **68.7 ms** on L (0.50 of base). Serving RSS is 11,408 KiB on M (**2.00×**
rust-expert's, so the M target fails again) and 83,888 KiB on L (1.84×). Huge pages remove the page-fault
cost on L but undo patch 2's memory saving on M, so no build meets all three targets.

**What remains is not the copy.** With both patches, about 30 ms of L's load is the validation pass that
builds `group_at`, and about 30 ms is reading and verifying 30 MB of variable-size groups at roughly
1 GB/s. rust-expert maps its image and validates it in 6 ms. Closing that needs a layout
with fixed-size records (`spike/FINDINGS.md`, layouts B–D: `from_bytes` 2× faster) or a lazily built
index, not another language patch.

## Round 2: layouts and huge-page configuration

Pre-registered 2026-11-04 before these numbers were taken. Correctness checks were already run: every
variant matches `bench/ref-checksums.txt` on S, M and L, and `layout/corrupt2.py` found no crash or
disagreement on 428 corrupted images per variant. Image sizes were already known too (see the results).

**Layouts** (`layout/`, no language change beyond patch 2's `from_file`):
- `fixed`: every record fixed-size, including groups, so `groups` is searched directly and `group_at` is
  gone. `paths` is no longer pinned by a bound type, so it needs no push-copy; spans are checked in load's
  pass. Conforms to SPEC.
- `chunked` (default mode, "stream"): occurrences stored in frames of 4096 records. Load reads and verifies
  every frame and keeps none of them; a query reads and re-verifies the frames it needs. Conforms to SPEC.
- `chunked` with `SYMIDX_VALIDATE=lazy`: frames are verified only when a query reaches them. Doesn't conform.
- `layout/rust-stream/`: rust-expert plus `SYMIDX_VALIDATE=stream`, every chunk validated at load and the
  mapped pages dropped after each. Added so that a memory win from the *design* isn't credited to Goose.

**Huge pages** (compiler branch `cfg-huge-env`): `GOOSE_HUGE_AFTER=<bytes>` requests huge pages past that
offset of each stack, at run time. Configurations: off, 2 MB (patch 1's behaviour), 8 MB (a threshold
chosen so M's arrays stay on small pages while L's large ones don't).

**Targets**, using the method above:
1. `fixed`, huge pages off, against rust-expert eager: L load < 90 ms, selective RSS ≤ 1.6× on M and
   ≤ 1.9× on L (patch 2's targets). Stretch, from the improvement plan: RSS ≤ 1.2× and load ≤ 2× on M and L.
2. `chunked` stream against rust-stream, and `chunked` lazy against rust-expert lazy: RSS ≤ 1.2× and load
   ≤ 2×, on M and L.
3. 8 MB threshold: M's RSS within 2% of huge pages off, and L's load within 5% of the 2 MB setting.
4. Huge pages on the log workload (experiment 2, M, `-t 1` and `-t 6`), never measured before: report the
   time and RSS ratios against huge pages off. No target.

**Correction before the final numbers.** A first full matrix (`data/round2-with-copy/`) showed `fixed` at
87 MB on L, far above its 44.5 MB image. Reason, from the generated C: `a, n, ok = from_file(...)` onto an
*existing* variable lowers to a temporary plus a `memcpy` onto it; only `var a, n, ok = from_file(...)`
writes in place. So the "from_file groups" cost of patch 2's layout A still includes a copy, and the
explanation in its results above ("the page faults moved with the bytes") was incomplete. `fixed` and
`chunked` now hold their arrays as locals of one function, so they don't copy. Layout A can't: `u32 in
groups` pins `groups` as a global. The targets are unchanged; `corrupt2.py` and the checksums were re-run.

### Results, round 2 (added after measuring)

Local, warm, one session, core-pinned random-order rounds: load 30, `find Model` 20, `find ""` 10.
Raw runs: `data/round2/`; the first matrix, with the hidden copy, is in `data/round2-with-copy/`, which
also holds the log workload (not re-run: it uses neither layout). Every variant matches the reference
checksums on S, M and L. `corrupt2.py`: 428 images per variant, no crash, all modes agree.

| | load M | RSS M | load L | RSS L | `find ""` L | image L |
|---|---|---|---|---|---|---|
| base (release) | 11.2 ms | 11.7 MB | 136.8 ms | 118.9 MB | 247 ms, 125 MB | 39.3 MB |
| layout A + patch 2 | 9.0 ms | 8.6 MB | 100.0 ms | 80.4 MB | 206 ms, 87 MB | 39.3 MB |
| `fixed` | 3.3 ms | 6.0 MB | 29.2 ms | 48.0 MB | 106 ms, 54 MB | 44.5 MB |
| `fixed` + huge pages (2 MB) | 3.3 ms | 6.0 MB | 16.2 ms | 48.9 MB | 87 ms, 56 MB | 44.5 MB |
| `chunked` stream | 3.1 ms | 5.0 MB | 22.4 ms | 15.8 MB | 111 ms, 16 MB | 44.5 MB |
| `chunked` lazy (not SPEC) | 2.6 ms | 5.0 MB | 8.3 ms | 15.8 MB | 100 ms, 16 MB | 44.5 MB |
| rust-expert eager | 1.3 ms | 4.9 MB | 6.4 ms | 45.7 MB | 119 ms, 46 MB | 43.9 MB |
| rust stream | 2.9 ms | 3.6 MB | 9.4 ms | 13.4 MB | 118 ms, 46 MB | 43.9 MB |
| rust lazy (not SPEC) | 1.0 ms | 3.6 MB | 1.1 ms | 14.2 MB | 114 ms, 46 MB | 43.9 MB |

RSS is `find Model` unless stated. Rust's `find ""` isn't comparable on memory: its query doesn't drop
mapped pages as it scans, though it could.

**Rust's RSS on M depends on system state.** rust-expert's M serving RSS was 5.8 MB in the first matrix and
4.9 MB here; its lazy mode 5.5 and 3.6 MB. Goose's didn't move. The likely cause (not confirmed) is how
the kernel holds the mapped file in page cache. These results use the lower, later session, the
conservative choice for Goose. Its L numbers were stable.

**Verdicts on the targets:**
1. `fixed`, against rust-expert eager: **met.** L load 29.2 ms (target < 90); RSS 1.24× on M (≤ 1.6) and
   1.05× on L (≤ 1.9). **Stretch missed:** M RSS 1.24× (≤ 1.2); load 2.48× on M and 4.48× on L (≤ 2), and
   still 2.51× on L with huge pages.
2. `chunked`: **missed.** Stream against rust stream: RSS 1.40× on M and 1.17× on L, load 1.03× on M and
   2.36× on L. Lazy against rust lazy: RSS 1.40× and 1.11×, load 2.62× and 7.71×. Rust is ahead in
   every cell; on M the RSS difference is 1.4 MB.
3. 8 MB threshold: **half met.** M RSS is unchanged (1.00), but L load is 1.16× the 2 MB setting's on layout A
   (target within 5%) and 1.27× on `fixed`.
4. Log workload (M, 3 rounds): `-t 1` 7.24 s off, 7.28 s at 2 MB, RSS +6.7%: no gain, some cost. `-t 6`
   2.54 s and 2.39 s, RSS 529 and 520 MB, with run-to-run spread of 2.3–3.6 s: inconclusive.

**Huge pages depend on the layout.** On layout A at 2 MB, M's RSS rises 33% (8.6 → 11.4 MB), because its
arrays just cross 2 MB, for no speed gain. On `fixed`, M doesn't change at all (its arrays stay under 2 MB),
and L's load is 43% faster for 2% more RSS.

**What changed against rust-expert eager, base → `fixed`:** L load 21× → 4.5×, L serving RSS 2.6× → 1.05×,
M serving RSS 2.4× → 1.24×, same-session. Goose's `find ""` on L is faster (0.89×), and its build 1.1–1.3×
faster with 1.1–1.2× the RAM (L: 6.9 s, 118 MB against 8.8 s, 106 MB). **What it cost:** the smaller image is gone
(1.01× larger on L, was 1.12× smaller), and `paths` and groups are checked by hand-written passes rather
than by index types.

**Kill criterion unchanged.** No configuration uses 1.3× less memory than rust-expert in a like-for-like
mode. By the improvement plan's own rule, gap 1 (≤ 1.2× RSS, ≤ 2× load on M and L) still isn't met, so
Phase 2's language decision doesn't reopen on these numbers.
