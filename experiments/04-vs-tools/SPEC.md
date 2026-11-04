# Experiment 4: logxform against Vector and Fluent Bit

Pre-registered 2026-11-04, before any measurement of these tools. Step 1 of the plan to find a first product:
Goose has only been compared with hand-tuned Rust. This compares it with the products it would compete with.

## Question

On experiment 2's task and corpus, is a fixed-purpose Goose tool clearly better on speed or memory than
Vector and Fluent Bit doing the same work, each configured sensibly?

## Task

[experiments/02-logxform/SPEC.md](../02-logxform/SPEC.md): parse three log formats strictly, filter by level,
normalize the timestamp, redact IPv4 addresses, extract key-value pairs, render NDJSON. Corpus S for
correctness and M for measurement.

**What "same work" means here.** The tools can't produce logxform's byte-exact output: JSON key order is theirs,
and Fluent Bit may render an empty `kv` as `[]`. So correctness is checked after normalizing: `check.py`
parses each output line, and compares the sorted multiset of records (including `kv` as a map) with logxform's,
which itself matches the reference checksum. `[]` is accepted as an empty `kv`. Output order is reported
separately. A tool that can't pass this on S isn't measured until the config is fixed.

## Versions and configurations

- Goose v2026.3 release, `logxform` as built for experiment 2. No patches: this is what exists today.
- Vector 0.61.0 (official x86_64-gnu tarball, sha256 checked): `stdin` source, `remap` with VRL, `console` sink
  with the JSON codec. One process per input file, since `stdin` is one stream.
- Fluent Bit 5.1.5 (official Ubuntu package, sha256 checked): `tail` with `read_from_head` and `exit_on_eof`,
  `lua` filter, `stdout` output in `json_lines`. One process per input file. `mem_buf_limit` is set so memory
  isn't left unbounded, as a real agent would run it.
- rust-arena from experiment 2, as a reference for what tuned Rust achieves on the same harness.

Configs are in this directory. Each tool's config is written once for correctness, then given one tuning pass
from its documentation. Anything tried is recorded in the report.

## Measurement

`experiments/03-goose-patches/measure.py`: random-order rounds, each command once for wall time and once under
GNU time for peak RSS; warm cache; stdout to `/dev/null`. M corpus, 3 rounds.

Two settings: **one core** (`taskset` to one CPU; `-t 1`, `--threads 1`) and **all six cores** (`-t 6`,
`--threads 6`, Fluent Bit unpinned). To keep the harness identical, logxform and rust-arena also run one process per
file through the same wrapper.

## Decision rule

A **clear win** over a tool is at least 1.5× its throughput or at most 1/1.5 of its peak RSS, with the other metric
no more than 1.1× worse. The product idea proceeds if logxform has a clear win over **both tools on one core**.
The all-cores result is reported and doesn't decide: Goose's known queue copies are a separate item (step 4).

If it doesn't, the log product is rethought before any compiler work is spent on it.

## What this doesn't show

- It doesn't show Goose is faster than Rust. rust-arena is in the table so that the size of the specialization effect is
  visible: a fixed-purpose Rust tool would get this win too.
- It doesn't count what the tools do and logxform doesn't: dozens of sources and sinks, buffering, retries, checkpoints,
  routing, reload, metrics, a configuration language. A win here is one input to a product decision, not a verdict.
- One machine, warm cache, one author, who knows Goose's side best and is less practised in VRL and Fluent Bit. A
  specialist might configure either tool better; the configs are published for that reason.

## Amendments

Recorded before the M run, after correctness checks and the tuning pass on S (a 70 MB HDFS slice).

- **A1. Fluent Bit's missing lines.** `tail` doesn't emit a final line without a newline, and `Apache.log` and
  `SSH.log` end that way, so it outputs 989,054 of S's 989,056 records. With those two set aside, its records and
  order are identical to the reference. This is tool behaviour with no effect on the measurement, so it is accepted
  and reported instead of changing the tool's input. Vector matches exactly, including order.
- **A2. Tuning pass, all recorded** (70 MB slice, wall time, peak RSS; "MB" of RSS here is KiB ÷ 1000, corrected in the report):
  - Vector `console` sink: 7.5 s, 175 MB (6 threads); 14.9 s, 98 MB (1 thread). `file` sink to `/dev/null`: 7.2 s, 194 MB;
    12.4 s, 104 MB. **Adopted `file`**, which favours Vector. With a `blackhole` sink (no JSON encoding, so
    not the same work): 3.0 s, so about half its time is output. Without VRL: 0.9 s.
  - Fluent Bit `protected_mode` on and off: 6.0 s, 35 MB both. `threaded: true` on the input: 6.0 s, 140 MB, so **not
    adopted**. `inotify_watcher: false` was set because this machine hit its inotify limit.
  - Fluent Bit's wall time came out at exactly 6.01 s in all runs, with about 5.3 s of CPU, which suggests its exit at
    end of file waits for a timer. So its CPU time is reported beside wall time.
- **A3. Recorded after the M run.** Vector logs `Failed to close file. path=/dev/null` at each exit; it exits 0, and
  the same sink passed the correctness check writing a real file. A2 promised Fluent Bit's CPU time beside its wall
  time, but `measure.py` records only wall time, so M has none. At most a few seconds of its roughly 124 s can be
  the exit timer, about one per input file, so this doesn't affect the outcome.
