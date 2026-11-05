# Experiment 9: logXform of Goose as a pipeline server

**Status: frozen 2026-11-05, before any of its code was written.** Changes after this point go in the amendments list with a date. Follows the [research plan](../../docs/RESEARCH_PLAN.md).

The project owner asked for this to be ready for testing against established benchmarks, on this machine and on third-party systems, while they're away for 6 hours. Three decisions were left open and are taken conservatively here: the compiler stays unpatched, nothing is posted publicly, and nothing is rented. The owner hasn't confirmed the stopping rule in the research plan.

## What gets built

A server, `logxform`, in Goose and in Rust with **the same design**, so a difference between them says something about the languages:

- A config file names one source, one transform, one sink and an optional disk buffer.
- One worker per connection or tailed file: blocking read, transform a block of whole lines, blocking write. Each worker has its own sink connection. So order holds per connection, and a slow sink pushes back on the sender.
- **Sources:** TCP, tailed files (rotation, truncation, a checkpoint per file).
- **Transforms:** none, regex replacement (a real regex engine: Goose's `regex`, Rust's `regex` crate), set a field, parse syslog, parse syslog and tag debug records.
- **Sinks:** TCP, HTTP POST, blackhole.
- **Disk buffer:** every block is on disk before it's sent, and survives a restart or SIGKILL. Delivery is at least once.
- **Signals:** SIGTERM stops cleanly, SIGHUP doesn't lose data.

C is allowed in the Goose version for sockets and system calls, as in experiment 8, and is counted and reported. Rust uses its standard library, plus the `libc` crate for signals.

**This doesn't make it Vector's equal.** Neither has routing between many sources and sinks, TLS, metrics, buffers in memory, or a general transform language. The report must say so.

## Tests, chosen before running them

PipeBench at commit `cdb484f6a187384f3589e0bbcda8c1d6d7d0e528`, unmodified apart from adding our subjects and their configs, in a local fork.

| Group | Tests |
|---|---|
| Performance, first group | `tcp_to_tcp`, `tcp_to_blackhole`, `regex_mask`, `set_field`, `syslog_parsing`, `real_world_1` |
| Performance, second group | `tcp_to_http`, `file_to_tcp`, `tcp_to_tcp_persistent`, `disk_buffer` |
| Correctness | `file_rotate_create`, `file_rotate_truncate`, `file_truncate`, `file_rotate_restart`, `tcp_to_tcp_persistent`, `tcp_to_tcp_persistent_restart`, `tcp_to_tcp_persistent_crash`, `disk_buffer_persistence`, `tcp_to_http_persistent`, `sighup`, `wrapped_json` |

**Left out, with reasons:** Kafka, S3, Azure, Kinesis, SQS, SNS, CloudWatch, ClickHouse, MinIO and OTLP: these need protocols or services we don't implement. Netflow and the 5-minute variants: not in scope for a first version. If a listed test can't be attempted, the report says why. Tests aren't swapped after seeing results.

**Output equivalence.** PipeBench's receiver only counts, so we check content ourselves. Where Vector's config emits JSON, ours emits JSON with the same fields, so we aren't lighter on the wire. `tcp_to_tcp` forwards whole lines without parsing them, and Vector's config asks for raw text too.

## Requirements from the safety and change-request results

Marks are fixed here, before the fixes, and apply to the batch tool from experiment 7.

| Shortcoming | Pass mark |
|---|---|
| Hex scan costs Goose 31% on HDFS | At most 10% over the pre-change program, paired rounds |
| Goose slower than Rust after the change | One-core CPU at least 0.9× Rust's speed on HDFS and BGL, with Rust's own second pass allowed |
| Goose memory 1.14× Rust's on escape-heavy data | At most 1.1× |
| IPs in dashed host names leak | Rule below, oracle cases added, 0 leftover on SSH |
| Goose stops at 2 GiB with a misleading error | A stated maximum line length, handled the same way in all programs, with bounded memory and a clear error |
| Fluent Bit reject flake, feature table | Investigated, written down |

**Dashed-IP rule, for all programs, applied after dotted IPs and before hex:** four decimal numbers from 0 to 255 joined by `-`, where the first has no ASCII letter or digit directly before it other than a single `-` that doesn't itself follow a digit-only group, and the last isn't followed by an ASCII letter, a digit, or `-` and a digit. They become `<ip>`. So `ec2-52-80-34-196.cn-north-1` becomes `ec2-<ip>.cn-north-1`, and `2005-06-03-15` doesn't change.

**Maximum line length, for all programs:** 64 MiB by default, set by `--max-line BYTES`. A longer line counts as malformed. Its first 4 KiB go to rejects, with a newline, and the rest is skipped.

## How results count

By the owner's rule, a result counts only if the code, tests and marks were frozen before the run.

1. **Development runs** are short smoke tests, are labelled as such, and are never reported as results.
2. **Freeze:** commit and binary hashes are recorded in `FREEZE.md`.
3. **Local evaluation:** at least 3 rounds per test, every round kept, same PipeBench commit, on the owner's i5-8400T. The generator, receiver and collector share its 6 cores, so these numbers can't be compared with published ones.
4. **Independent evaluation:** the same frozen code on a c7i.4xlarge through a script in this directory. The owner decides whether and when to rent it. Published Vector and Fluent Bit tests are rerun first.

Any change after a freeze means a new version and new runs. PipeBench's maintainer sells a competing tool, and the report will say so.

## What counts as competing

Reported per test, as PipeBench reports: lines per second, CPU per event, peak memory, loss, and pass or fail. Interesting is at least 1.3× better CPU per event than the better of Vector and Fluent Bit on a processing test with verified output, from experiment 8. Losses are reported, and differences within the spread count as no difference.

## Amendments

- **A1, 2026-11-05, before the freeze: wider dashed-IP rule.** Checking the frozen rule on SSH left 614 lines leaking the form `host229-140-211-80.serverdedicati.aruba.it`, where letters run straight into the first number. The 0-leftover mark can't be met otherwise, so the first number may now directly follow ASCII letters. A digit directly before it still rules it out, and so does a `-` that follows a digit-only group. So `ab1-2-3-4` becomes `ab<ip>`. This errs toward redacting too much. The mark isn't changed.
- **A2, 2026-11-05, before the freeze: host names with extra numbers.** After A1, addresses like `pla75-1-78-194-48-145.fbxo.proxad.net` still leaked, because a digit-only group came before them. Now a chain of digit-only groups before the four numbers rules them out only if it starts the run. If a group with a letter comes before the chain, they're redacted: `pla75-1-<ip>.fbxo`. `2005-06-03-15` and `1-2-3-4-5` stay as they are. "Leftover" in the mark means four numbers from 0 to 255, so `657-1-127-147` isn't one.
- **A3, 2026-11-05, before the freeze: real-data tests added.** The published cases repeat one template line, and `regex_mask` can never match. So three cases of ours are added to the performance list, for all four programs, labelled as ours: `real_ssh_mask`, `real_hdfs_mask`, `real_ssh_syslog`. Nothing is removed.
- **A4, 2026-11-05, before the freeze: the dashed-IP rule doesn't go into Fluent Bit and Vector's batch scripts.** The [audit](AUDIT.md) concludes that the batch comparison with the tools can't speak to real use, so this version compares them through PipeBench. The batch rule is checked in Python, Goose and Rust.
- **A5, 2026-11-05, before the freeze: Rust's second pass.** Rust's server got a SIMD escape scan, since Goose's `find_any` is SIMD, and its batch tool got direct rendering, as Goose's did. Rust's batch dotted-IP scan and Goose's are otherwise as they were.
- **A6, 2026-11-05, before the freeze: rounds.** Three rounds of the whole list take about 5.5 hours on this machine. Whole rounds run in order, so an early stop leaves complete rounds, and the report says how many finished.
