# Experiment 2, logxform: pre-registered specification

Pre-registered on 2026-11-03, before any implementation was written. The task, corpus, metrics, fairness
rules and kill criterion below **must not change** after implementation starts. A real problem found later
is recorded under "Amendments" with its reason, and the report gives both readings: the original one and
the amended one.

## Purpose

To falsify the top two candidates of [docs/GOOSE_OPPORTUNITIES.md](../../docs/GOOSE_OPPORTUNITIES.md):
request-scoped transform kernels (1) and log and telemetry processing (2). Both rest on the same mechanism:
parse many small variable-size records, transform them, render, and drop everything at once. This is the
shape of Goose's largest upstream wins (`records`, `respond`). One benchmark tests both. A failure also
removes the main argument for candidates 4 (genomics records) and 7 (ETL).

## Task

`logxform [-t N] FORMAT FILE [FORMAT FILE ...]` reads each FILE as a log of the given FORMAT (`hdfs`, `ssh`
or `apache`), in argument order. It writes one NDJSON line per kept record to stdout. It then writes one
summary line to stderr, `lines=<n> kept=<n> dropped=<n> malformed=<n>\n`, totalled over all files.

### Processing model (all implementations)

- **Streaming.** A file is read in blocks of exactly 1 MiB (2^20 bytes), with the platform's `read(2)`
  or its language-standard equivalent. A file is never read whole, and it is never mapped.
- **Batches.** A batch is the next 65,536 lines of one file, or what's left of it. A batch never spans two
  files. A partial line at the end of a block is carried into the next batch.
- **Build, transform, render, drop.** For each batch, in this order:
  1. parse every line of the batch into a record (below);
  2. transform the records (below);
  3. render every kept record into one output buffer;
  4. write that buffer to stdout, then release the batch.

  Every record of a batch exists at the same time before rendering starts. A record holds its parsed fields
  (timestamp, level, component, message, and the key-value list as separate key and value byte strings),
  either as copies or as references into the batch's input bytes. Rendering reads records, not input lines.
  A fused parse-and-print loop that never materializes the batch's records doesn't conform.
- **Output.** Each batch's output goes to stdout in input order, as one write (or one `write_all`) per
  batch. The benchmark discards stdout (`/dev/null`).
- **Threads.** `-t 1`, the default, runs everything on the calling thread, with no worker threads. `-t N`
  for N > 1 runs N worker threads that parse, transform and render batches. The main thread reads input and
  writes output, in input order. At most 2N batches are in flight at once, counting input read but not yet
  processed and output rendered but not yet written.

### Lines

A line is the bytes up to a `\n`, without it. A final segment without a `\n` is a line if it's non-empty.
One trailing `\r` is removed from each line (the HDFS and SSH files have CRLF endings). Bytes are bytes:
nothing is decoded as UTF-8. The pinned corpora are pure ASCII, and that's checked when they're built.
Every line counts in `lines`. A line that doesn't match its format exactly is **malformed**: it's counted
and produces no record and no output.

### Formats

Each format gives a timestamp, a level, a component, a message (`msg`) and format-specific key-value pairs.
"Digits" means ASCII `0`–`9`. Month names are `Jan`…`Dec`; weekday names are `Mon`…`Sun`, case-sensitive.
Every field check below is part of the format: if one fails, the line is malformed.

**`hdfs`** (Loghub HDFS_v1): `YYMMDD HHMMSS PID LEVEL COMPONENT: MSG`, single spaces.
- `YYMMDD`, `HHMMSS`: 6 digits each; year = 2000 + YY.
- `PID`: one or more digits.
- `LEVEL`: one of `TRACE DEBUG INFO WARN ERROR FATAL`.
- `COMPONENT`: the bytes after the level's space, up to the first `": "` (colon, space). It must be
  non-empty and contain no space. `MSG` is everything after that `": "`, possibly empty.
- Pairs, in order: `pid` = PID; then `blk`, if the message has a space-separated token that starts with
  `blk_`: the first such token, cut to its longest prefix matching `blk_-?[0-9]+`. No `blk` pair if no
  digits follow (`blk_` or `blk_-`).

**`ssh`** (Loghub SSH, syslog): `Mmm DD HH:MM:SS HOST PROG[PID]: MSG`.
- `Mmm`: a month name. `DD`: two bytes, a space and a digit, or two digits. `HH:MM:SS`: digits with colons.
- The year is not in the log. It's 2017 for months Jul–Dec, 2018 for Jan–Jun (the corpus spans
  Dec 2017 to Jan 2018).
- `HOST`: one or more bytes other than a space. `PROG`: one or more bytes other than space and `[`.
  `PID`: one or more digits. Then exactly `]: `, and `MSG` is the rest, possibly empty.
- Level, from the message: prefix `error: ` → `ERROR`; prefix `fatal: ` → `FATAL`; prefix `Failed `,
  `Invalid user ` or `reverse mapping ` → `WARN`; anything else → `INFO`.
- Component: PROG. Pairs, in order: `host` = HOST, `pid` = PID.

**`apache`** (Loghub Apache error log): `[Www Mmm DD HH:MM:SS YYYY] [level] MSG`.
- `Www`: a weekday name (not checked against the date). `DD`: two digits. `YYYY`: four digits.
- `level`: one of `emerg alert crit` → `FATAL`, `error` → `ERROR`, `warn` → `WARN`, `notice` → `NOTICE`,
  `info` → `INFO`, `debug` → `DEBUG`.
- After `] ` comes `MSG`, the rest, possibly empty. (The corpus's 4,477 lines without a timestamp are
  malformed.)
- Component: the constant `httpd`. No format-specific pairs.

**Timestamp ranges, all formats:** month 1–12, day 1–31 (not checked against the month), hour 0–23,
minute 0–59, second 0–59.

### Transform

Applied to every record of the batch, in this order:
1. **Filter by level.** Level order: `TRACE < DEBUG < INFO < NOTICE < WARN < ERROR < FATAL`. A record is
   kept if its level is at least its component's minimum level, and **dropped** otherwise (counted in
   `dropped`). The minimum level is `INFO`, except for the components `dfs.DataNode$PacketResponder` and
   `dfs.FSDataset`, whose minimum is `WARN` (noisy-logger suppression; it drops about 43% of HDFS).
2. **Normalize the timestamp** to RFC 3339 in UTC, `YYYY-MM-DDTHH:MM:SSZ` (the logs carry no zone; they
   are taken as UTC).
3. **Redact** IPv4 addresses in `msg`. Scanning left to right: a *run* starts at a digit whose preceding
   byte is neither a digit nor `.` (or at the start), and extends over every following digit and `.`. Drop
   the run's trailing dots from consideration. If what's left is exactly four groups of 1–3 digits joined by
   single dots, it's replaced with `<ip>`, and the trailing dots are kept. Other runs, and everything
   outside runs, are copied unchanged. Examples: `/10.250.19.102:54106` → `/<ip>:54106`;
   `74.82.254.191.ifibertv.com` → `<ip>.ifibertv.com`; `1.2.3.4.5` and `blk_-160899` are unchanged.
4. **Extract message pairs** from the redacted `msg`. Split it on spaces (0x20), skipping empty tokens.
   A token with an `=` at a position p ≥ 1, whose bytes before p are all in `[A-Za-z0-9_.-]`, gives the pair
   (token[..p], token[p+1..]). The value may be empty, and may contain `=`. These pairs follow the format's
   pairs.
5. **Derive** `sev`, the syslog severity of the level: `FATAL` 2, `ERROR` 3, `WARN` 4, `NOTICE` 5, `INFO` 6,
   `DEBUG` 7, `TRACE` 7.

The key-value list has **dictionary semantics**: a key keeps the position of its first occurrence and the
value of its last one (as a Python `dict` or an insertion-ordered map does).

### Output

One line per kept record, compact JSON with no spaces, keys in this order, then `\n`:

```
{"ts":"2008-11-09T20:35:18Z","level":"INFO","sev":6,"component":"dfs.DataNode$DataXceiver","msg":"Receiving block blk_-1608999687919862906 src: /<ip>:54106 dest: /<ip>:50010","kv":{"pid":"143","blk":"blk_-1608999687919862906"}}
```

`kv` is always present, `{}` when empty. Strings are escaped exactly as serde_json and Python's
`json.dumps(..., ensure_ascii=False)` do: `"` → `\"`, `\` → `\\`; `\b \f \n \r \t` in their short forms;
other bytes below 0x20 as `\u00xx` with lowercase hex. Every other byte is copied, including 0x7f and bytes
at or above 0x80.

### Reference

`experiments/02-logxform/ref.py` (Python 3, standard library only) defines the output. Each implementation's
stdout must have the same sha256 as the reference's on every corpus, and its stderr summary line must be
equal. The reference's checksums are recorded in `experiments/02-logxform/ref-checksums.txt`.

## Corpus

Source: **Loghub** (He, Zhu, He, Li, Lyu; "Loghub: A Large Collection of System Log Datasets for AI-driven
Log Analytics", ISSRE 2023), Zenodo record [8196385](https://zenodo.org/records/8196385),
DOI 10.5281/zenodo.8196385. `experiments/02-logxform/corpus/fetch.sh` downloads the archives, checks every
sha256 below, extracts the logs, checks them, derives S's HDFS file and checks it, and checks that every log
is ASCII.

| Archive | Zenodo md5 | sha256 |
|---|---|---|
| `HDFS_v1.zip` (186,645,559 bytes) | `76a24b4d9a6164d543fb275f89773260` | `04f919f2185821f23f045dca611a7586429bdabc601bd7b43f30005f8e289b01` |
| `SSH.tar.gz` (4,596,666 bytes) | `a44e40b4348697dabf2bba56885e0a38` | `296610a35773f58b7c295e5407fc5ccdf48beb3c544fc14a6309addf904a2712` |
| `Apache.tar.gz` (262,905 bytes) | `de9a42d12f9b60612631c67a5a9f8628` | `f2cb5014453c8a0f71596838e1639a2131ff6d360839ad280409f621a6cac452` |

| Input file | From | Lines | Bytes | sha256 |
|---|---|---|---|---|
| `Apache.log` | `Apache.tar.gz` | 56,482 | 5,135,876 | `23e616a1ed529bab9b20b9bc345d37035061eee971d246102bcc4937e51a039b` |
| `SSH.log` | `SSH.tar.gz` | 655,147 | 73,417,506 | `89eee9e36c182722f9fadc6e5617a4818ffc66109e7e222b8f9e8b78fc3aa2f3` |
| `HDFS.log` | `HDFS_v1.zip` | 11,175,629 | 1,577,982,906 | `0783096174d7832c618337f9609e06e04abd86ddd7089b3c12b407e63bfebc52` |
| `HDFS_head500k.log` | `head -n 500000 HDFS.log` | 500,000 | 70,529,095 | `c0c06bcb8af8b361f4d48f6732a3263d06c2a717539e218c2ad45a2225f2b915` |

| Corpus | Arguments, in order | Input bytes | Role |
|---|---|---|---|
| S | `apache Apache.log ssh SSH.log hdfs HDFS_head500k.log` | 149,082,477 | development, quick CI check |
| M | `apache Apache.log ssh SSH.log hdfs HDFS.log` | 1,656,536,288 | **the decision corpus** |
| L | M's arguments, repeated 4 times | 6,626,145,152 | scaling check: throughput and RSS must stay flat |

L is replicated by repeating the arguments, not by copying files. Its output is M's output 4 times, and
it's read from the page cache when warm. M fits in the page cache of every machine used here.

## Implementations

All in `experiments/02-logxform/`.
1. **`goose/`**: idiomatic Goose (v2026.3, pinned as in Phase 1). Records with inline variable-size fields,
   batch data on data stacks released when the batch's scope ends, workers through typed queues.
   File reading goes through a C sidecar (`open`/`read`/`close` via `extern fn`), since `os.goose` only
   reads whole files. Nothing else is done in C.
2. **`rust-arena/`**: the competitor that matters. A hand-written byte parser into a per-batch `bumpalo`
   arena, records borrowing from the batch's input buffer where they can, and rendering straight into a
   reused output buffer without intermediate allocations, the way a competent performance-minded team
   would write it.
3. **`rust-idiomatic/`**: for context only, not for the verdict. Owned `String`s per field, `serde` derive
   and `serde_json` for rendering, a `Vec` of records per batch.

## Metrics

Measured by `experiments/02-logxform/run.sh`, in the style of `bench/run.sh`: `env.txt` with every result,
`PIN=`, `COLD=1`, `RUNS=`, `OUT=`.
- **Single-thread throughput:** input MB (10^6 bytes) per second of wall time, `-t 1`. Wall time is the
  hyperfine mean of the whole process, stdout to `/dev/null`.
- **Multi-thread throughput:** the same at `-t N`, N = the machine's logical core count (`nproc`, or the
  `PIN` set's size).
- **Peak RSS:** of the `-t 1` process and of the `-t N` process (GNU `time` on Linux, `/usr/bin/time -l` on
  macOS), the median of 3 runs.
- **Output checksum:** sha256 of stdout against the reference, plus an equal stderr summary line. A
  mismatch invalidates the row.

Warm cache means one untimed run of the same command first, and hyperfine warm-up runs. `COLD=1` empties
the page cache before each timed run, as in Phase 1, and is reported but doesn't decide.

## Fairness rules

- Every implementation follows the processing model above, with the same batch size, read size, write
  pattern, in-flight bound and thread counts.
- Each one is built in its standard optimized configuration:
  - Rust: `--release`, `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`; the default target CPU, with
    no `target-cpu=native`;
  - Goose: the default `goose build` (`-O2`) with clang, as in Phase 1, with no extra `-D` or C flags.
- Libraries:
  - rust-arena: `std`, `bumpalo`, `memchr`, `crossbeam-channel`;
  - rust-idiomatic: `std`, `serde`, `serde_json`;
  - Goose: its standard library, plus C only for opening, reading and closing files.
  - Nobody replaces the global allocator, and nobody uses SIMD intrinsics written by hand.
- No `unsafe` in either Rust implementation. Goose has none. Both sides are memory-safe.
- The same harness for everyone, with nothing extra exec'd inside a timed command.
- **Fairness audit.** Before any verdict, a separate agent that hasn't seen the results' interpretation gets
  only this SPEC and the source code. It looks for ways any implementation is handicapped: allocation
  patterns, I/O buffering, unequal parsing work, threading, compiler flags. What it finds is fixed in both
  directions and re-measured. The report gives its findings and the numbers before and after.

## Kill criterion

**Goose must beat rust-arena by ≥ 1.3× on single-thread throughput, or on peak RSS of the `-t 1` process,
on M, warm cache, on the reference machine (the local Linux machine of Phase 1), after the fairness
audit.** Otherwise the Goose track ends, and `docs/GOOSE_OPPORTUNITIES.md` is updated accordingly.

- Throughput ratio = Goose MB/s ÷ rust-arena MB/s. RSS ratio = rust-arena peak RSS ÷ Goose peak RSS. The
  criterion passes if either ratio is ≥ 1.30.
- Multi-thread throughput, multi-thread RSS, S, L, cold cache, CI and macOS are reported, and they can
  qualify the verdict, but they don't decide it.
- **Ambiguous** results: a deciding ratio between 1.25 and 1.35 on the reference machine, or CI Linux
  disagreeing with the reference machine on pass or fail, for the same metric. In those cases no verdict is
  written until the project owner has decided.
- rust-idiomatic is never the comparison.

## Amendments

None yet. Each amendment gets a date, what changed, why, and both readings in the report.
