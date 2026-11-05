# Audit: do our comparisons with Vector and Fluent Bit hold up?

Written for the project owner's question of 2026-11-05: established tools shouldn't lose to our programs in tests that reflect real use, so there's likely a fundamental error in the application or method. The figures here come from development runs on the owner's i5-8400T, labelled as such. Results that count are in [REPORT.md](REPORT.md).

## Short answer

- **We found no measurement error that would remove the gap,** and looked in five places. A large gap remains in records-per-CPU.
- **The owner's doubt is right about experiment 7.** It ran the tools as batch jobs, through our wrapper, pinned to one core, with no network. It can't say how they compare in real use.
- **This doesn't show our program is a better product.** It does far less. See [What the gap doesn't mean](#what-the-gap-doesnt-mean).

## Five checks

### 1. Does the harness reproduce published tool results?

Yes, within the published range. Running PipeBench unchanged on this machine gives results close to the published 4-vCPU tier. The hardware differs, so this is a rough calibration and not a reproduction, which needs a c7i machine.

Lines per second:

| Tool | Test | This machine, 6 cores | c7i.large, 2 vCPU | c7i.xlarge, 4 vCPU | c7i.4xlarge, 16 vCPU |
|---|---|---|---|---|---|
| Vector | `tcp_to_tcp` | 681,547 | 476,876 | 699,965 | 950,267 |
| Vector | `regex_mask` | 449,714 | 286,873 | 439,138 | 849,225 |
| Vector | `set_field` | 325,926 | 291,737 | 359,078 | 905,394 |
| Vector | `syslog_parsing` | 252,329 | 193,784 | 272,519 | 705,224 |
| Vector | `real_world_1` | 271,486 | 190,141 | 267,433 | 390,089 |
| Vector | `tcp_to_blackhole` | 995,454 | 687,628 | 1,136,282 | 2,333,305 |
| Fluent Bit | `tcp_to_tcp` | 1,159,913 | 866,889 | No result | 1,504,668 |
| Fluent Bit | `regex_mask` | 213,172 | 250,711 | 338,184 | 329,872 |
| Fluent Bit | `set_field` | 654,876 | 537,747 | 976,671 | 1,038,462 |
| Fluent Bit | `syslog_parsing` | 105,817 | 74,408 | 133,662 | 160,541 |
| Fluent Bit | `real_world_1` | 83,652 | 67,081 | 112,710 | 143,235 |
| Fluent Bit | `tcp_to_blackhole` | 1,216,435 | 1,650,054 | 1,971,082 | 2,066,154 |

These local runs had other work on the machine at times, so they aren't results. A third tool in the published data, `vmetric`, reaches 26.9M lines/s on `tcp_to_tcp` and 2.5M on `regex_mask` on a c7i.4xlarge. So very high throughput isn't unique to us. PipeBench's maintainer sells that tool.

### 2. Do we do the same work?

We checked directly, because PipeBench's receiver only counts. [compare_vector.py](compare_vector.py) sends the same lines through Vector with PipeBench's own transforms and through our servers, then compares every record, field by field.

- **The first comparison found real differences, all fixed:** facility names, structured data, carriage returns, leading spaces, syslog without a colon, and what happens to lines that don't parse. We were also writing 1-second timestamps where Vector writes nanoseconds, which was lighter work.
- **Now:** 2,286 of 2,286 records match in both languages, ignoring only each record's port and receipt time, which are checked by type.
- **Bytes on the wire match too:** 271 per line on `regex_mask` and 351 on `syslog_parsing`, for Vector and for us.

Limits: 2,286 records is a sample, and syslog forms beyond those in the script could differ.

### 3. Is the generator's data too easy?

**Yes, in a way that favors us, so we tested without it.** The published cases repeat one template line, and `regex_mask`'s regex can never match, because the generator's alphabet has no `=`.

So we added three cases of our own, on 200,000 real SSH and HDFS lines each, with a regex that matches and with varying syslog severities ([real_cases.py](pipebench/real_cases.py)). The gap stays about the same or grows:

| Test | Goose lines/s | Rust lines/s | Vector lines/s | Fluent Bit lines/s |
|---|---|---|---|---|
| Real SSH, mask IPs | 9,321,482 | 8,384,437 | 546,627 | 252,432 |
| Real HDFS, mask IPs | 7,837,654 | 6,895,277 | 522,417 | 125,047 |
| Real SSH, parse syslog, tag debug | 6,420,516 | 6,530,815 | 307,872 | 167,350 |

### 4. Are the tools badly configured?

The published cases use PipeBench's own configs, and we didn't change them. Whether each is the tool's best is an open question: PipeBench's maintainer wrote them and sells a competing tool.

On our own real-data case, we tried what Fluent Bit's documentation suggests:

| Setting | Lines/s |
|---|---|
| As configured | 252,432 |
| Output `Workers 2` | 245,305 |
| Input `Threaded on` | 0, nothing delivered |

We didn't find out why `Threaded on` delivered nothing here, so that one remains open. A C or Wasm filter for Fluent Bit is untested. **An expert in either tool might well do better**, and we haven't asked one, since that means posting publicly, which is the owner's decision.

### 5. Where do the tools spend their CPU?

Microseconds of CPU per line, from the development runs:

| Test | What's added | Vector | Fluent Bit | Goose | Rust |
|---|---|---|---|---|---|
| `tcp_to_blackhole` | Input only | 4.23 | 0.82 | 0.04 | 0.05 |
| `tcp_to_tcp` | Output | 4.80 | 2.46 | 0.21 | 0.21 |
| `set_field` | A field, as JSON | 7.06 | 3.23 | 0.50 | 0.68 |
| `regex_mask` | A regex, as JSON | 7.87 | 6.23 | 0.35 | 0.58 |
| `syslog_parsing` | A parser, as JSON | 10.03 | 18.66 | 0.63 | 0.73 |

- **Most of Vector's cost comes before any transform:** 4.23 µs a line just to receive. Each line becomes an event with its own allocations, moved between tasks.
- **Fluent Bit's depends on the step:** its C input is fast, and its regex-based syslog parser is the expensive part.
- **Ours has no events.** A worker transforms a block of bytes in place in one thread. It's a design that can't do what theirs can, as below.
- **`tcp_to_blackhole` and `tcp_to_tcp` barely count for us:** we don't look at each line, only for the last newline of a block. That's allowed, and `vmetric`'s numbers suggest it does the same, but it says nothing about an engine. Experiment 8's bar only counts processing tests.

These explanations come from the per-line costs and from how the tools are documented to work. We haven't profiled inside them.

## What the gap doesn't mean

| Feature | logXform server | Vector | Fluent Bit |
|---|---|---|---|
| Many sources and sinks, routing between them | No: one of each | Yes | Yes |
| Other protocols: Kafka, S3, OTLP, Elasticsearch and more | No: TCP and HTTP POST | Yes | Yes |
| TLS, authentication | No | Yes | Yes |
| A general transform language | No: five fixed transforms | VRL | Lua, Wasm, built-in filters |
| Metrics and health endpoints | No | Yes | Yes |
| Compression, batching policies, retry policies | No: one fixed retry | Yes | Yes |
| File rotation, checkpoints | Yes, tested, by inode | Yes, by fingerprint | Yes |
| Disk buffer | Yes, one design | Yes | Yes |
| Backpressure | Yes, through TCP | Yes | Yes |
| End-to-end delivery acknowledgements | No: a TCP write counts as delivered | Yes, where the sink supports it | Partly |
| Years in production | None | Yes | Yes |

The tools' columns come from their public documentation as we know it, not from tests. Their security record, supply chain and communities aren't assessed.

**So a fair summary of the gap:** a small program built for a fixed set of transforms does those transforms with far less CPU than general engines. Adding the rows above would cost some of that lead. We can't yet say how much.

## What this means for experiment 7

Its numbers stand as what they were, but it can't be quoted as a comparison with the tools in real use. The batch workflow stays useful as a test of language and correctness.

- **Wrapper cost:** the wrapper's cost is still unmeasured, but it scans each file once on tens of seconds to minutes of tool time, so it can't explain the gap.
- **Pinning:** all-cores results are now the main comparison, because PipeBench doesn't pin anything.

## Left over from the pilot

- **Fluent Bit's lost reject:** on the 2 MiB rejected line, the rejects file was wrong in 4 of 25 runs with `Grace 1`, and in 4 of 25 with `Grace 5`. So more grace time doesn't fix it. We didn't find the cause, and it could lie in our configuration or wrapper rather than in the tool.
- **Feature table:** the table above covers the server. The batch programs in the pilot have none of those features except atomic output and backpressure from reading at their own pace.

## Added after the evaluation

This audit found no single error in the performance tests. The correctness runs later found faults in the configs PipeBench ships. Fluent Bit's `tcp_to_tcp` persistence configs let it give up on data, and its HTTP config caps storage below what the test sends. See the [report](REPORT.md#correctness-on-the-tools). That doesn't show the performance configs are at fault, but they can't be treated as the tools' best until someone who knows the tools has reviewed them.
