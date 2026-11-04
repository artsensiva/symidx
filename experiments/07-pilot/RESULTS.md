# Pilot results so far

**Status: one of two required sessions. The change request and delivery checks haven't been done, so neither decision rule in the [SPEC](SPEC.md) is settled.** How each program was built is in [BUILD.md](BUILD.md). Raw data is in [data/session1/](data/session1/), and [summarize.py](summarize.py) prints these tables from it.

"logXform of Goose" is our program. In the CSV files it's `goose`, as measured.

## Session 1, 2026-11-04, 13:20–15:58

Every program writes real output and rejects files, end to end. Five rounds on one core; three on all cores.

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

## How to read this

- **Python doesn't clearly beat Fluent Bit.** On HDFS their CPU ratio has a median of 1.07 and a range of 0.91 to 1.21, which is no difference within the spread. Fluent Bit uses about half Python's memory on most inputs and half its CPU on escape-heavy data (0.51×). Python passes every correctness check, and Fluent Bit doesn't. Vector is clearly behind both. So "the best alternative" depends on the format and on whether CPU, memory or correctness matters.
- **logXform of Goose and Rust can't be told apart on speed.** HDFS runs overlap (6.9–8.8 s and 7.1–9.2 s), and SSH is level. The 1.12× CPU figure in the first table isn't a measured lead.
- **Memory against Rust:** level on the main data, but 1.14× worse on escape-heavy data, which is over the spec's 1.1× limit on that one test.

## Against the decision rules, provisionally

- **A, is a tool like this worth having?** On track. Against the best alternative per format, the CPU ratio is about 17× on HDFS and 19× on SSH, and 6.4× on escape-heavy data, the lowest. The target is 1.3×. Memory passes on HDFS, SSH and Apache, but on escape-heavy data, where Fluent Bit is the best alternative, it's 1.17× Fluent Bit's (42.2 against 36.1 MiB), which is over the 1.1× limit on that one test.
- **B, why Goose rather than Rust?** Not decided. Speed passes, memory passes on the main data with the escape-heavy exception, and no compiler change was needed, though a small C file was (Rust needed none). **The required measured advantage doesn't exist yet.**

## What limits this session

- **Other work on the machine.** Load stayed under 2.2 until the HDFS stages. It reached about 4 in the one-core HDFS stage and 8.7 on all cores, while separate CPU-heavy jobs were running. One-core programs were pinned and rounds randomized, so ratios should hold, but all-cores numbers shouldn't be relied on.
- **One session.** The spec requires at least two.
- **The requirements and tests were written by the same agent** that wrote the programs, and there's no external user.
- **Not tested:** crash recovery, following live files and network delivery, which the spec excludes, and which are what the tools are built for. No fuzzing or sanitizer runs yet.
