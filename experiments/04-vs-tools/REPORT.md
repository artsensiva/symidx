# Experiment 4: logxform against Vector and Fluent Bit

Spec, with amendments: [SPEC.md](SPEC.md). Raw runs: `data/`. Local machine (i5-8400T, 6 cores, warm cache), M corpus
(1.66 GB, 11.9M lines), 3 random-order rounds per setting. Goose v2026.3 release, no patches.

*Later: [docs/GOOSE_LOGXFORM_REPORT.md](../../docs/GOOSE_LOGXFORM_REPORT.md) repeats this comparison with the fixes, with CPU time, in one session.*

**The spec was written before these runs, but not committed before them,** so that order rests on the session's
record, not on git history.

## Result: the decision rule is met

*Qualified after an independent review:* this rule justifies testing a real workflow. It isn't evidence that anyone wants this tool, or that Goose is the right language for it. It also covers a Lua filter only, not a native Fluent Bit parser, and was chosen when Goose's multi-core weakness was known.

On one core, logxform has a clear win over both tools (rule: at least 1.5× throughput or 1/1.5 of the RSS, with the
other metric no more than 1.1× worse).

| One core | Throughput | Peak RSS | logxform's speed advantage | Tool's RSS ÷ logxform's |
|---|---|---|---|---|
| Goose logxform | 212.7 MB/s | 35.9 MiB | — | — |
| rust-arena (reference) | 258.5 MB/s | 36.1 MiB | 0.81× | 1.00 |
| Fluent Bit 5.1.5 (Lua) | 13.4 MB/s | 39.1 MiB | **15.9×** | 1.09 |
| Vector 0.61.0 (VRL) | 5.6 MB/s | 96.9 MiB | **38.9×** | 2.70 |

| All six cores | Throughput | Peak RSS | logxform's speed advantage | Tool's RSS ÷ logxform's |
|---|---|---|---|---|
| Goose logxform | 605.4 MB/s | 468 MiB | — | — |
| rust-arena (reference) | 1,152.6 MB/s | 349 MiB | 0.53× | 0.74 |
| Fluent Bit | 14.2 MB/s | 42.1 MiB | 41× | 0.09 |
| Vector | 13.0 MB/s | 207 MiB | 46× | 0.43 |

Ratios are medians of paired rounds. By the rule's definition, all cores is not a clear win: speed is far ahead, but
memory is 11× Fluent Bit's and 2.3× Vector's. This setting doesn't decide, as registered. Going to six cores, Fluent Bit
barely gains and Vector gains 2.3×, and logxform at `-t 1` already outruns both at six cores (213 MB/s against 14 and
13), so `-t 6`'s memory is optional.

## How to read this

- **Most of the win is specialization, not Goose.** rust-arena does the same job about 1.2× faster than Goose on one
  core and 1.9× faster on six, so it would beat the tools by more: about 19× and 46× on one core. A fixed-purpose
  Rust tool is the real competitor for this product. What this shows is that Goose is already well inside the range where
  the specialized design pays off, not that it's the fastest way to get there.
- **rust-arena's lead here (0.81×) is larger than in experiment 2** (0.88×; 0.93–1.03× across rebuilds). logxform's own
  runs spread 7.1–8.4 s, and the load average reached about 3.8 during the run, so treat this as noise-affected.
- **Memory is close to Fluent Bit's.** It's 1.09× on one core, well under the 1.5× a memory win would need. The case against
  Fluent Bit is CPU, not RAM.

## Where the tools' time goes (70 MB slice, tuning pass)

Vector: 0.9 s reading with no transform, 3.0 s with VRL and no output, 7.2 s with JSON output to a file, at six
threads. So on this task its cost is split between VRL and its output path. Fluent Bit used about 5.3 s of CPU, and
`protected_mode` and threaded input didn't change its speed.

## A native Fluent Bit configuration (added after the review)

An outside review pointed out that 16–20× only covered a Lua filter. So `fluentbit-native/` uses native regex parsing and native `grep`, with Lua only for what has no native form as far as this author knows. It matches the reference on the edge corpus, S and M, apart from the same final lines. Raw: `data/native/`; load average 1–3.5. Apache and SSH 5 rounds, HDFS 3, one core. The total sums the formats' medians. Multiples compare with Goose logxform with fixes.

| One core | Throughput | Peak RSS | CPU per GB | Its CPU ÷ Goose's |
|---|---|---|---|---|
| Goose logxform, with fixes | 215 MB/s | 36.0 MiB | 3.8 s | — |
| Goose logxform, release | 232 MB/s | 36.0 MiB | 4.2 s | 1.09 |
| Tuned Rust | 196 MB/s | 36.1 MiB | 4.2 s | 1.09 |
| **Fluent Bit, Lua alone** | 13.5 MB/s | 39.8 MiB | 71.6 s | **18.8** |
| Fluent Bit, native parser, `grep`, minimal Lua | 10.5 MB/s | 39.9 MiB | 93.2 s | 24.4 |

| CPU per GB, by format | Goose with fixes | Fluent Bit, Lua | Fluent Bit, native | Share of bytes |
|---|---|---|---|---|
| HDFS | 3.7 s | 69.5 s | 90.8 s | 95.3% |
| SSH | 6.3 s | 117 s | 143 s | 4.4% |
| Apache (too short for a precise ratio) | 5.8 s | 82 s | 117 s | 0.3% |

Unpinned on HDFS: Goose logxform 564 MB/s and 503 MiB, tuned Rust 822 MB/s and 350 MiB, Fluent Bit 15.5 MB/s and 43 MiB with Lua, 11.8 MB/s and 45 MiB native.

**What this shows.**
- **The clear win holds against the configurations tried.** Goose logxform stays far ahead of both Fluent Bit configs. Among those two, native parsing doesn't help: it's about 30% slower than Fluent Bit's Lua config here. Dropping lines natively before Lua saved nothing on the 70 MB slice.
- Wall time in this table is less reliable than CPU: Goose's wall figures moved more than its CPU figures, and Fluent Bit's wall times fall on whole seconds, apparently from an exit timer.
- **Ceilings, on HDFS, not the same work:** `tail` with the parser to `stdout` is 35.8 s of CPU per GB, and `tail` alone is 7.3 s, about twice Goose's whole job. These are indicative only, not upper bounds: they write every line, while a real filter writes about 59%, and output is a large part of that cost.

**What it doesn't show.** A filter written in C or Wasm wasn't tried, since it's a different effort from configuring the tool, and it's the one option that could change this materially. Its result would need the same correctness checks. A specialist might also find a better configuration. Tuned Rust wins by about as much.

## What this doesn't show

- **The tools do far more.** They have many sources and sinks, buffering, retries, checkpoints, routing, reload, metrics and a
  configuration language. logxform reads finished files and writes stdout. It has no file following, rotation, sinks or
  backpressure. Any of those will cost something, and none is measured here.
- **This task is transform-heavy.** It's what the scripting layers are slowest at. A Fluent Bit native C filter wasn't tried and
  would likely narrow the gap, and a job that only forwards lines would narrow it further.
- **One author, more practised in Goose than in VRL or Fluent Bit.** Configs are in this directory for a specialist to improve.
- **Small deviation.** Fluent Bit's `tail` drops a final line without a newline (2 of 989,056 records on S). Otherwise both
  tools match the reference records, Vector in order too; Fluent Bit's order was checked on S and matches.
- **One machine, warm cache, 3 rounds.** The ratios are large enough that this doesn't change the outcome, but the exact values
  shouldn't be quoted as general.
