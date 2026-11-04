# Pilot: sanitize rotated logs for an analytics store

Frozen 2026-11-04, and committed before any pilot code exists. Changes after that go under "Amendments", with reasons, and the report gives both readings.
Why this pilot exists: an outside review ([Symidx_Audit_04-11-2026.md](../../Symidx_Audit_04-11-2026.md)) found that the benchmarks so far can't say whether anyone should use this, or why Goose rather than Rust. The compiler work is paused until this answers.

## The workflow

**An operator has a directory of rotated logs in known formats, and must load them into an analytics store (ClickHouse, Elasticsearch, a data lake) without leaking IP addresses or keeping noisy records.** It's a one-off or nightly batch job on one machine.

Why this one:
- It's something people really do, for backfills, sharing logs with a vendor, and retention rules.
- It's a batch job, so today's Goose can do it with no compiler change, no embedding and no multi-core redesign.
- Every alternative can do it too, so the comparison is of whole workflows.

**The weakness, stated up front: there's no external user.** The project owner chose to proceed without one, and the requirements below were written by the same agent that will implement them. So a positive result shows a feasible and possibly useful tool, not demand for it. Finding a real user who'd run this remains the most valuable next step, and any such user's requirements replace these.

## Requirements

Each program must meet all of these, or the report states what's missing.

1. **Input.** A list of `FORMAT FILE` pairs, or `FORMAT -` for stdin, so that `zcat app.log.gz | tool hdfs -` works.
2. **Formats.** `hdfs`, `ssh`, `apache`, under experiment 2's parsing, filter, redaction and rendering rules ([SPEC](../02-logxform/SPEC.md)), filtering before building records as a product would, and stated as such.
3. **Output.** NDJSON, in input order, to stdout or `--out FILE`. With `--out`, the file appears only on success (a temporary file, renamed at the end).
4. **Rejects.** Malformed lines go to `--rejects FILE` unchanged, in order, so that nothing is lost silently.
5. **Summary.** Counts for lines, kept, dropped and malformed, on stderr. `--max-reject-rate R` makes the run exit non-zero if exceeded.
6. **Failures are visible.** Unreadable input, a write failure or a closed pipe gives a clear message and a non-zero exit. A final line with no newline counts as a line.

Not required, and stated as such: following live files, network sinks, retries, checkpoints, or restart after a crash. A user who needs those needs one of the tools, not this.

## The programs compared

| Program | How it's built |
|---|---|
| **Goose** | Unpatched Goose v2026.3 release. No local compiler patches. A vectorizable scan like F2's lives in the program itself, as any user could write it |
| **Rust** | Stable Rust, the same design and features, from `rust-arena`, including the same scan. It's an equal attempt, not a baseline to beat |
| **Fluent Bit** | Best configuration a tool user would reach: a native `parser` filter, with Lua only for what it can't do. The Lua-only configuration is reported too |
| **Vector** | Best VRL configuration, reviewed against its documentation |
| **Python** | Plain standard-library script, from `ref.py`: what many people would write for a one-off job |

Tools that can't meet a requirement get a wrapper script, whose cost is counted, or the gap is reported.

## Test data

- **Measured:** experiment 2's M corpus, reported **per format** as well as in total, since HDFS is 95% of its bytes.
- **Held out, untouched before this spec:** Loghub `BGL` (about 700 MB, same pinned Zenodo record), used for the change request.
- **Adversarial, new:** escape-heavy messages, very long lines, invalid UTF-8, empty files, no trailing newline, CRLF, mostly-filtered and nothing-filtered inputs. The expected output comes from a corrected reference, reviewed before implementations are run against it.
- **Scan cost check:** escape-heavy input, because F2's scan pays a full preliminary pass on strings that need escaping.

## The change request

Written here, so nobody can pick an easy one afterwards. After all programs pass the base requirements:

> Add the `bgl` format. Severity comes from the line's level field. Also redact hexadecimal addresses of the form `0x` followed by 8 hexadecimal digits, as `<hex>`, in all formats, and drop `bgl` records whose component is `APP` unless they are `ERROR` or above.

Exact field rules go in the amendment recording this request's start, from inspecting the BGL data, before any implementation of it begins. Measured for each program: lines changed, working minutes, tests that broke, and whether performance moved.

## What's measured

- **Speed:** end-to-end wall time and CPU per GB, whole workflow, one core, and all cores where the program uses them.
- **Memory:** peak RSS.
- **Correctness:** every program on every corpus, by `check.py`, in order, fail-closed.
- **Delivery:** bytes to install, runtime dependencies, steps on a clean machine, whether a built binary runs when copied to another machine, and which toolchain a user needs to rebuild it.
- **Failure behaviour:** requirement 6's cases, tested.
- **Change effort:** as above.

Method: `measure.py` with its order, timestamps, load and hashes; at least 5 rounds, over at least 2 separate sessions. Ratios are reported as ranges, not confidence intervals. A difference within the spread is reported as no difference.

## Decision rules

Two separate questions, because the earlier work ran them together.

**A. Is such a tool worth having at all?** Yes if it has at least **1.3× end-to-end CPU per GB** against the best alternative that meets the requirements, tools and Python both, on the per-format results that matter, with memory no more than 1.1× worse. If it doesn't, stop: nobody needs this tool.

**B. If so, why Goose rather than Rust?** Goose is justified only if **all** of these hold:
- one-core speed at least 0.9× Rust's, and memory at most 1.1×;
- no requirement needed a compiler change, or a workaround that a Goose user couldn't reasonably find;
- and at least one measured advantage: the change request taking at most 0.7× Rust's lines and working minutes, or a delivery benefit that Rust can't match (for example, shipping as C source to a user with no Rust toolchain, shown working on a clean machine).

If B fails, the recommendation is to build the tool in Rust. The project owner may still choose Goose, as a preference and not a benchmark result, and the documents will say so.

**Known bias in B.** Lines and minutes come from one AI agent, not from people with normal experience of either language. So they're a weak signal, and any result that hinges on them is reported as such. A human trying the change request would be stronger evidence.

## Limits

- **Effort cap:** 2 weeks of work in total, including the change request and report. At the cap, report what exists and stop.
- **No compiler changes.** If Goose can't do something without one, that's a result, which counts against question B. It doesn't start a new compiler project.
- **Decision owner:** the project owner, on the report's evidence. A near miss isn't quietly reinterpreted: anything between "met" and "not met" gets stated as exactly that.

## Amendments

- **A1, before any pilot code.** The Fluent Bit row assumed a native `parser` would be its best configuration. Measured since ([experiment 4](../04-vs-tools/REPORT.md)), it's slower than Fluent Bit with Lua alone. So Lua alone is the Fluent Bit configuration to beat, and the native one is reported beside it. A C or Wasm filter is still out of scope, and the report must say so.
- **A2, before any pilot code: exact behaviour of the requirements.**
  - Command line: `TOOL [--out FILE] [--rejects FILE] [--max-reject-rate R] FORMAT PATH [FORMAT PATH ...]`, where `PATH` may be `-` for stdin.
  - `--out`: output goes to `FILE.tmp`, renamed to `FILE` only if the whole run succeeds. Otherwise `FILE` isn't created, and the temporary file is removed.
  - `--rejects`: each malformed line, as read, including any trailing CR, then a newline. Written as the run goes, so it's still there after a failure.
  - Summary line on stderr, always, on a run that reaches the end of its input: `lines=N kept=N dropped=N malformed=N`.
  - `--max-reject-rate R`: fails if `malformed / lines` is greater than `R`. Zero lines never fails.
  - Exit codes: 0 success; 1 reject rate exceeded; 2 bad command line; 3 I/O failure, with a message on stderr. A closed output pipe is an I/O failure.
  - Bytes are bytes: invalid UTF-8 is copied through unchanged, as experiment 2's spec says. A tool that can't do that is reported as such.
  - Oracle: `gen_adversarial.py` builds each adversarial line together with its expected output, without using any parser, and `sanitize.py` (the reference, and the Python competitor) must match it. So reference and implementations can't pass by sharing a parser bug.
- **A3, before any pilot code: test evidence.** `check_oracle.py` has 114 checks, including requirement 6's failures and a kill partway through. The reference passes all of them, and matches experiment 2's recorded checksums on S and M. Ten deliberately broken copies of the reference were run through it: all fail, one only after adding the kill test, which is how that test came to exist.
- **A4, before any pilot code: one thread.** Goose and Rust start as single-threaded programs, since neither tool beats them on all cores, multi-core isn't a requirement, and the six-core work is on hold. So the "all cores" measurement applies to the tools only. If that changes, it's a new amendment.

- **A5, 2026-11-04, after session 1, before the change request and session 2: an operational safety section.** The project owner asked whether safety is being taken into account, and today it's only partly covered. The report gains a section on it. **It's report-only: decision rules A and B don't change,** so nothing is moved after seeing session 1. Its contents:
  - **Malformed input.** A seeded mutation run over samples of each format and the adversarial set: byte flips, truncations, inserted lines, oversized fields. For every program: no crash, no signal, and an exit code from the spec. logXform of Goose and Rust are also compared with the Python reference on every mutated input.
  - **Sanitizers.** logXform of Goose and Rust under AddressSanitizer and UndefinedBehaviorSanitizer on the same inputs, where the toolchain allows. If one can't be run, the report says so; that isn't a pass.
  - **Redaction misses.** An IP-address search over each program's output on the corpus, and a list of forms the rules don't cover (IPv6, for example). These are limits of the rules, reported for every program.
  - **Long runs and large inputs.** Peak memory for logXform of Goose and Rust over a long stream through stdin, and on one very long line, so that growth or unbounded buffering shows up.
  - **Feature table.** For all five programs: crash recovery, retries, disk buffering, backpressure, following rotated files. This workflow excludes these, and the tools are built for them, so the table is what stops a batch result reading as a general one.
  - **Not assessed, and stated as such:** security updates and CVE history, supply chain, and the size of each community.
