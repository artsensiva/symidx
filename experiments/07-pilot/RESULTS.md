# Pilot results so far

**Status: both required sessions are done. The change request and delivery checks aren't, so neither decision rule in the [SPEC](SPEC.md) is settled.** How each program was built is in [BUILD.md](BUILD.md). Raw data is in [data/session1/](data/session1/), [data/session2/](data/session2/) and [data/wall-check/](data/wall-check/), and [summarize.py](summarize.py) prints these tables from it.

"logXform of Goose" is our program. In the CSV files it's `goose`, as measured.

## Session 1, 2026-11-04, 13:20–15:58

Every program writes real output and rejects files, end to end. Five rounds on one core; three on all cores. Other work disturbed its late stages, as described below; session 2 is the better measurement.

### The 1.66 GB corpus, one core

Each format's median, summed.

| Program | Throughput | Peak RSS | CPU per GB | CPU ÷ logXform of Goose |
|---|---|---|---|---|
| **logXform of Goose** | 204.3 MB/s | 36.0 MiB | 4.2 s | 1.00 |
| Rust | 194.6 MB/s | 36.1 MiB | 4.8 s | 1.12 |
| Python | 13.6 MB/s | 66.3 MiB | 73.6 s | 17.3 |
| Fluent Bit (Lua) | 12.0 MB/s | 36.5 MiB | 79.0 s | 18.6 |
| Vector (VRL) | 4.8 MB/s | 99.7 MiB | 202.1 s | 47.6 |

### Per format, one core

MB/s, peak MiB, CPU seconds per GB.

| Input | logXform of Goose | Rust | Python | Fluent Bit | Vector |
|---|---|---|---|---|---|
| HDFS, 1,578 MB | 209.3, 36.0, 4.2 | 198.7, 36.1, 4.7 | 14.0, 66.3, 71.5 | 12.4, 36.5, 76.8 | 4.9, 99.7, 195.8 |
| SSH, 73.4 MB | 137.1, 32.0, 6.3 | 137.1, 34.3, 6.3 | 8.3, 60.3, 118.2 | 7.2, 34.6, 125.7 | 3.0, 99.6, 328.4 |
| Escape-heavy, 27.1 MB | 59.1, 42.2, 14.8 | 52.9, 37.0, 16.6 | 5.4, 65.9, 183.4 | 6.5, 36.1, 94.1 | 4.2, 97.5, 231.0 |
| Apache, 5.1 MB | 151.9, 18.1, 3.9 | 141.2, 18.9, 5.8 | 11.6, 33.1, 81.8 | 4.8, 31.5, 99.3 | 3.0, 87.9, 327.1 |
| Mostly filtered, 5.0 MB | 405.7, 6.5, too short | 429.7, 6.2, too short | 13.1, 12.3, 74.2 | 4.7, 23.2, 66.2 | 4.2, 78.0, 240.6 |

Apache and mostly-filtered are too short for precise ratios, and Fluent Bit's one-second floor dominates their wall time.

### HDFS, all cores

Only the tools use more than one core (SPEC, A4). This stage was disturbed; see below.

| Program | Wall per round | Throughput | Peak RSS |
|---|---|---|---|
| logXform of Goose | 8.2, 8.9, 8.3 s | 190.4 MB/s | 35.7 MiB |
| Rust | 6.7, 10.0, 8.8 s | 179.0 MB/s | 36.0 MiB |
| Fluent Bit | 105.5, 108.7, 119.0 s | 14.5 MB/s | 37.1 MiB |
| Vector | 165.1, 213.7, 167.2 s | 9.4 MB/s | 196.9 MiB |

### Correctness

From [check_oracle.py](check_oracle.py), on the adversarial set and the failure cases.

| Program | Checks passed | What fails |
|---|---|---|
| logXform of Goose, Rust, Python | 114 of 114, byte-exact | Nothing |
| Vector | [111 of 114](data/oracle-vector.txt), compared semantically | Invalid UTF-8 becomes U+FFFD |
| Fluent Bit | [106 of 114](data/oracle-fluentbit.txt), compared semantically | Invalid UTF-8 becomes private-use characters; **a final line with no newline is lost**; rejects lose a trailing CR |

logXform of Goose and Rust also match the recorded checksums on S and M.

## Session 2, 2026-11-04, 18:34–20:47

The same programs and script, on a machine kept free of other jobs. Load peaked at 1.54 in the HDFS one-core stage and 3.89 on all cores, against 4.42 and 8.48 in session 1, so **this is the better measurement.** During its first stages, the BGL download and small checks ran at low priority on another core, which is why load reached 2.74 in the SSH stage. They had finished before the HDFS stages.

### The 1.66 GB corpus, one core

| Program | Throughput | Peak RSS | CPU per GB | CPU ÷ logXform of Goose |
|---|---|---|---|---|
| **logXform of Goose** | 198.1 MB/s | 36.0 MiB | 4.0 s | 1.00 |
| Rust | 233.2 MB/s | 36.1 MiB | 3.8 s | 0.97 |
| Python | 12.9 MB/s | 66.5 MiB | 77.2 s | 19.4 |
| Fluent Bit (Lua) | 12.7 MB/s | 36.6 MiB | 73.6 s | 18.5 |
| Vector (VRL) | 5.8 MB/s | 98.8 MiB | 171.4 s | 43.1 |

### Per format, one core

MB/s, peak MiB, CPU seconds per GB.

| Input | logXform of Goose | Rust | Python | Fluent Bit | Vector |
|---|---|---|---|---|---|
| HDFS, 1,578 MB | 203.7, 36.0, 3.9 | 242.3, 36.1, 3.7 | 13.2, 66.5, 75.2 | 13.3, 36.6, 71.0 | 6.1, 98.8, 163.2 |
| SSH, 73.4 MB | 127.0, 32.0, 6.5 | 132.7, 34.4, 6.4 | 8.2, 60.4, 120.7 | 7.2, 35.0, 127.5 | 3.0, 97.6, 336.2 |
| Escape-heavy, 27.1 MB | 59.5, 42.2, 14.4 | 50.9, 37.1, 16.2 | 5.2, 66.0, 191.9 | 8.6, 35.7, 90.4 | 4.5, 97.7, 221.4 |
| Apache, 5.1 MB | 134.5, 18.2, 3.9 | 136.5, 19.0, 3.9 | 10.7, 33.1, 87.6 | 4.8, 31.2, 105.1 | 2.8, 87.5, 344.6 |
| Mostly filtered, 5.0 MB | 437.5, 6.5, too short | 305.7, 6.2, too short | 13.4, 12.5, 72.2 | 4.7, 22.7, 64.2 | 4.3, 76.4, 228.6 |

### HDFS, all cores

| Program | Wall per round | Throughput | Peak RSS |
|---|---|---|---|
| logXform of Goose | 6.6, 6.9, 7.9 s | 230.0 MB/s | 36.1 MiB |
| Rust | 7.8, 7.9, 6.1 s | 201.5 MB/s | 36.1 MiB |
| Fluent Bit | 103.4, 102.6, 102.6 s | 15.4 MB/s | 37.4 MiB |
| Vector | 119.5, 113.2, 114.6 s | 13.8 MB/s | 204.5 MiB |

logXform of Goose and Rust are single-threaded (SPEC, A4), so their differences here are noise, about as large as the one below.

## The wall-time gap on HDFS

**As measured by the spec's method, session 2's HDFS wall time puts logXform of Goose at 0.84× Rust's speed, below decision rule B's 0.9× floor. Session 1 put it at about 1.02×. Both readings stand.**

CPU was much closer (6.09 and 5.87 s), so we ran a [diagnostic](wall_check.py) that isn't one of the spec's sessions: HDFS only, both programs in seeded random order. In session 2, every logXform of Goose run straight after Fluent Bit was slow, and Rust never ran in that position.

| Condition | Runs each | logXform of Goose, wall | Rust, wall | Speed against Rust | User CPU, Goose and Rust |
|---|---|---|---|---|---|
| Straight after each other | 10 | 6.33 s (6.31–6.51) | 6.21 s (6.15–6.66) | 0.98× | 5.27 and 5.13 s |
| After `sync` | 10 | 6.81 s (6.33–7.13) | 6.32 s (6.20–6.59) | 0.93× | 5.26 and 5.12 s |
| Straight after Fluent Bit | 4 | 8.31 s (7.66–9.47) | 8.30 s (8.26–8.72) | 1.00× | 5.44 and 5.45 s |

- **Running straight after Fluent Bit costs both programs about 2 s, equally.** Most of session 2's gap came from which program happened to follow it. With 5 rounds, random order didn't balance that out.
- **Rust is really slightly faster on HDFS.** Its user CPU is about 2.7% lower, and the ranges barely overlap. So the earlier "logXform of Goose has a small lead" doesn't hold on this data: session 1's 1.12× CPU figure came from a disturbed run.
- **Not explained:** why `sync` beforehand slows logXform of Goose by more than Rust, with the same CPU. Both programs write the same number of blocks. It's still above 0.9×.
- **For the method:** wall time on a large file depends on what ran before it. CPU is much less affected. Future comparisons of programs this close should use many short paired rounds, not a few mixed with slow programs.

## Change request, 2026-11-04

The rules were fixed before any program changed (SPEC, A6): a new `bgl` format and hex redaction, in all five programs. Raw data: [data/change/](data/change/). Runs took place from 21:35 to 22:39, with load at most 1.97.

### Implementing it

| Program | Lines changed | Minutes |
|---|---|---|
| Python | 31 | 0.5 |
| **logXform of Goose** | **115** | **1.1** |
| Rust | 151 | 0.6 |
| Fluent Bit | 27 | About 3 to the first full run, about 6 with verification |
| Vector | 60 | 1.1 |

- **Lines come from `git diff --numstat`, and minutes are wall clock.** One agent wrote all five, so this isn't a developer study.
- **Goose and Rust passed on their first run.** Test time dominates Fluent Bit's clock.
- **The clock is coarse and the order was fixed:** Python, Goose, Rust, then the tools. Goose went before Rust on purpose, which biases against Goose. Rust's line count is inflated by rustfmt.
- **Goose ÷ Rust:** lines 0.76, minutes 1.97. The spec's bar is 0.7 on both, so **logXform of Goose doesn't show the advantage.**

### Correctness

| Program | Change checks (150) | Base checks (114) | BGL against the reference, 4,747,953 records |
|---|---|---|---|
| Python | 150 | 114 | Reference |
| logXform of Goose | 150 | 114 | Byte-identical |
| Rust | 150 | 114 | Byte-identical |
| Fluent Bit | 148, on the ASCII set | 104 in one run, 106 before | Same records, different bytes |
| Vector | 150, on the ASCII set | 111 | Same records, different bytes |

- **Rejects** on BGL match the reference in all four programs.
- **The tools ran on an ASCII set** so that their known failures on other bytes didn't hide the new rules. Fluent Bit's two failures there are the known CR-in-rejects limit.
- **Fluent Bit's lower base count isn't from the change.** It intermittently loses a rejected 2 MiB line, 1 of 25 repeats, and its summary reports the line as dropped. This goes to the safety section.
- **On HDFS, SSH and Apache** the changed Goose and Rust programs write the same bytes as before.
- **Mutation test:** 16 of 16 mutants caught.

### BGL, one core (743 MB, 5 rounds)

| Program | Wall (s) | Peak memory (MiB) | CPU (s) | CPU against Goose |
|---|---|---|---|---|
| Rust | 2.99 | 55.6 | 2.60 | 0.84× |
| **logXform of Goose** | **3.56** | **56.7** | **3.10** | |
| Fluent Bit | 43.85 | 36.1 | 42.14 | 13.6× |
| Python | 48.43 | 77.8 | 48.45 | 15.6× |
| Vector | 148.38 | 100.9 | 146.89 | 47.4× |

In a separate 10-round pair, Goose took 3.43 s and Rust 2.90 s. Goose's peak memory is 1.57× Fluent Bit's here, over the 1.1× limit. Every APP record in BGL is FATAL, so the APP filter drops nothing on this data.

### What the change cost on data with no hex values

HDFS, 10 paired rounds, median wall time. HDFS has no hex matches, so this is the cost of looking.

| Program | Before (s) | After (s) | Cost |
|---|---|---|---|
| logXform of Goose | 6.35 | 8.34 | **+31%** |
| Rust | 6.51 | 6.90 | +6% |

Goose moved from level with Rust to 1.21× Rust's wall time. **The registered result is this one.**

The first Goose version copies every byte through a bounds-checked loop, even on lines with nothing to redact. The Rust version uses `memmem` from the `memchr` crate and moves nothing unless it finds a match. Three follow-up variants, written after seeing the result, measure how much of the cost is avoidable:

- **A ([patch](data/change/hexvar-a.patch)):** the byte loop, but no copying before the first match.
- **B ([patch](data/change/hexvar-b.patch)):** libc `memmem` through a helper added to the C file.
- **C ([patch](data/change/hexvar-c.patch)):** `find_pair` from Goose's standard library, with no C.

All three pass 114 of 114 and 150 of 150 checks, and write the registered BGL output and rejects. Each group below is 10 paired rounds, from [measure_hexvar.sh](measure_hexvar.sh). The groups ran separately, so compare each program with the Rust row of its own group.

| Group | Program | HDFS wall (s) | Against Rust | BGL wall (s) | Against Rust |
|---|---|---|---|---|---|
| 1 | Registered Goose | 8.30 | 1.22× | 3.47 | 1.19× |
| 1 | Variant A | 7.52 | 1.10× | 3.28 | 1.13× |
| 1 | Variant B | 7.28 | 1.07× | 3.20 | 1.10× |
| 1 | Rust | 6.82 | | 2.91 | |
| 2 | Registered Goose | 8.44 | 1.23× | 3.48 | 1.18× |
| 2 | **Variant C** | **6.95** | **1.01×** | **3.15** | **1.07×** |
| 2 | Goose before the change | 6.39 | | Not applicable | |
| 2 | Rust | 6.87 | | 2.95 | |

- **Most of the cost was how I wrote it.** Against the Goose base program in the same group, variant C costs 9% on HDFS and the registered program 32%. Rust's cost was 6%, from a separate run.
- **Goose's standard library has the fast form, and the first version didn't use it,** though it already used the related `find_any` for newlines. Variant C is plain Goose, and is faster here than the C helper, though they ran in separate groups.
- **These variant timings aren't valid results.** The code was written after the result was seen, and Rust got no second pass. By the project owner's rule ([research plan](../../docs/RESEARCH_PLAN.md)), they're leads for the next version, which has to be frozen and measured again. The registered program stays as measured, and the safety checks use it.
- **Not explained:** the 9% left in variant C. Nor did I check whether the Rust program has similar room.

## Safety, 2026-11-04 and 2026-11-05 (SPEC, A5)

Report-only, so none of this changes the decision rules directly. It uses the registered change-request programs. Raw data: [data/safety/](data/safety/), from [run_safety.sh](run_safety.sh). **Still to do:** the Fluent Bit reject flake and the feature table.

### Malformed input

Seeded mutations of real and adversarial lines, from [safety_fuzz.py](safety_fuzz.py). The mutations are random, not coverage-guided.

| Run | Cases | Result |
|---|---|---|
| logXform of Goose and Rust against Python: exit code, output, rejects, summary | 20,000 | No differences, no signals |
| Fluent Bit and Vector, crashes only | 200 | No crashes or signals. Their output isn't compared here |
| Sanitizer builds of logXform of Goose and Rust against Python | 2,000 | No differences, no reports |

### Sanitizers

| Check | logXform of Goose | Rust |
|---|---|---|
| AddressSanitizer | Yes | Yes, through `RUSTC_BOOTSTRAP=1`, which stable Rust doesn't support |
| UndefinedBehaviorSanitizer | Yes, except alignment | Not run |
| 264 oracle checks | All pass | All pass |
| BGL, HDFS head, SSH, Apache | Same output and rejects as the normal build, 0 reports | Same |

- **Alignment:** with every check on, each Goose case stops at a misaligned 16-bit access in the generated C, at [three sites](data/safety/alignment.txt). Goose's documentation says its C backend targets "64-bit, little-endian hosts with unaligned packed accesses", so this is by design. It's still undefined behavior in C, so it limits delivery as C source, and other architectures are untested.
- **What these runs can't see:** Goose values live in its own mapped data stacks, which AddressSanitizer doesn't track, so an overrun inside one relies on Goose's bounds checks and guard gap. Rust's standard library wasn't instrumented, and the Rust build's only sanitizer is AddressSanitizer.
- **Different builds:** the sanitizer build of Goose comes from `goose --standalone` at clang `-O1`, not the registered binary, though from the same source.

### What redaction misses

Searched in logXform of Goose's output, which is byte-identical to the reference. These are limits of the rules, and every program applies the same ones.

| Form | Where | Lines | Example |
|---|---|---|---|
| IP inside a host name, with dashes | SSH | **3,498** of 655,146 input lines | `ec2-52-80-34-196.cn-north-1.compute.amazonaws.com.cn` |
| `0x` values not 8 digits long | BGL | 247,993, by the A6 rule | `0x0157` |
| Dotted IPv4, IPv6 | All four | 0 | |

**The SSH hosts are a real leak against the workflow's purpose:** the address is readable in the host name. The rules, written by the same agent, didn't cover it.

### Long runs and very long lines

Peak memory and exit code. Long streams are flat in both programs, with no growth from 1× to 8× HDFS. The sizes below are single lines, or two rejected lines of that size.

| Input | Goose | Rust |
|---|---|---|
| HDFS × 1, stdin | 36 MiB | 36 MiB |
| HDFS × 8, stdin | 36 MiB | 36 MiB |
| One 64 MiB line | 258 MiB | 131 MiB |
| One 256 MiB line | 1.0 GiB | 515 MiB |
| One 1 GiB line | 4.0 GiB | 2.0 GiB |
| One 2.3 GiB line | **Stops at 2.0 GiB, exit 3** | 4.4 GiB, succeeds |
| Two rejected 64 MiB lines | 258 MiB | 259 MiB |
| Two rejected 256 MiB lines | 1.0 GiB | 1.0 GiB |
| Two rejected 1 GiB lines | **Stops at 2.0 GiB, exit 3** | 4.0 GiB, succeeds |

- **Goose has a limit Rust doesn't:** input that fills the default 2 GiB data stack ends the run. It fails closed, with exit 3 but says `cannot read -`, which misdescribes the cause.
- **Why it doesn't overwrite anything:** the C helper reads straight to the top of the data stack, so `read(2)` hits the guard gap behind the region. That follows from reading the runtime's source and from these two runs, not from a dedicated test.
- **Goose uses twice Rust's memory on one very long kept line.** No program in this pilot is expected to meet such lines, but nothing prevents them.

## How to read this

- **Python doesn't clearly beat Fluent Bit.** Their CPU on HDFS swapped order between sessions, with Fluent Bit at 1.07× Python's in session 1 and 0.94× in session 2. Fluent Bit uses about half Python's memory on most inputs and half its CPU on escape-heavy data. Python passes every correctness check, and Fluent Bit doesn't. Vector is clearly behind both. So "the best alternative" depends on the format and on whether CPU, memory or correctness matters.
- **logXform of Goose and Rust are close, with Rust slightly ahead on HDFS.** Level on SSH CPU; on escape-heavy data, logXform of Goose uses about 10–15% less CPU, in both sessions.
- **Memory against Rust:** level on the main data, but 1.14× worse on escape-heavy data, in both sessions, which is over the spec's 1.1× limit on that one test.
- **Session 1 was disturbed:** Vector went from 319.5 to 259.2 s on one core and from 167.2 to 114.6 s on all cores on the quiet machine.

## Against the decision rules, provisionally

The project owner has since set a different goal: research into both tools, not a choice between them ([research plan](../../docs/RESEARCH_PLAN.md)). So rule B's outcome doesn't end the work. The owner also doubts these comparisons reflect real use, and the plan audits them first.

- **A, is a tool like this worth having?** On track. Against the best alternative per format in session 2, the CPU ratio is about 18× on HDFS, 19× on SSH and 6.3× on escape-heavy data, the lowest. The target is 1.3×. Memory passes on HDFS, SSH and Apache. Over the 1.1× limit against Fluent Bit on two tests: escape-heavy data at 1.18× (42.2 against 35.7 MiB), and BGL, added by the change request, at 1.57× (56.7 against 36.1 MiB), where the CPU ratio is 13.6×.
- **B, why Goose rather than Rust?** Not decided.
  - **Speed:** before the change request, a near miss as measured (0.84× in session 2), and 0.93–1.00× in the diagnostic. After it, a miss: 0.83× on HDFS and 0.85× on BGL.
  - **Memory:** passes on the main data, misses on escape-heavy data.
  - **Compiler change:** none needed, though a small C file was, and Rust needed none.
  - **Measured advantage:** none yet. The change request didn't show one (lines 0.76, minutes 1.97, against a bar of 0.7). **One is required, and only the delivery checks are left to show it.**

## What limits these results

- **The requirements and tests were written by the same agent** that wrote the programs, and there's no external user.
- **Not tested yet:** the rest of the safety section (the Fluent Bit reject flake, the feature table). Crash recovery, following live files and network delivery are excluded by the spec, and they're what the tools are built for.
- **One machine,** warm cache.
