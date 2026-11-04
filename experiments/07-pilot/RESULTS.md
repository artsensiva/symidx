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

## How to read this

- **Python doesn't clearly beat Fluent Bit.** Their CPU on HDFS swapped order between sessions, with Fluent Bit at 1.07× Python's in session 1 and 0.94× in session 2. Fluent Bit uses about half Python's memory on most inputs and half its CPU on escape-heavy data. Python passes every correctness check, and Fluent Bit doesn't. Vector is clearly behind both. So "the best alternative" depends on the format and on whether CPU, memory or correctness matters.
- **logXform of Goose and Rust are close, with Rust slightly ahead on HDFS.** Level on SSH CPU; on escape-heavy data, logXform of Goose uses about 10–15% less CPU, in both sessions.
- **Memory against Rust:** level on the main data, but 1.14× worse on escape-heavy data, in both sessions, which is over the spec's 1.1× limit on that one test.
- **Session 1 was disturbed:** Vector went from 319.5 to 259.2 s on one core and from 167.2 to 114.6 s on all cores on the quiet machine.

## Against the decision rules, provisionally

- **A, is a tool like this worth having?** On track. Against the best alternative per format in session 2, the CPU ratio is about 18× on HDFS, 19× on SSH and 6.3× on escape-heavy data, the lowest. The target is 1.3×. Memory passes on HDFS, SSH and Apache, but on escape-heavy data, where Fluent Bit is the best alternative, it's 1.18× Fluent Bit's (42.2 against 35.7 MiB), over the 1.1× limit on that one test.
- **B, why Goose rather than Rust?** Not decided.
  - **Speed:** a near miss as measured (0.84× in session 2), and 0.93–1.00× in the diagnostic. Stated as exactly that.
  - **Memory:** passes on the main data, misses on escape-heavy data.
  - **Compiler change:** none needed, though a small C file was, and Rust needed none.
  - **Measured advantage:** none yet. **It's required, and depends on the change request and delivery checks.**

## What limits these results

- **The requirements and tests were written by the same agent** that wrote the programs, and there's no external user.
- **Not tested yet:** the safety section (SPEC, A5). Crash recovery, following live files and network delivery are excluded by the spec, and they're what the tools are built for.
- **One machine,** warm cache.
