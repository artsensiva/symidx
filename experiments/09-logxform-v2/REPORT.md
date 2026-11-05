# Experiment 9: results so far

**Status: interim, 1 of 3 rounds.** The [spec](SPEC.md) asks for at least 3 rounds per test, so nothing here is final and no Goose-versus-Rust difference is claimed yet. Rounds 2 and 3 are running on the same frozen code.

This report covers logXform of Goose and a Rust version with the same design, against Vector and Fluent Bit, on the owner's i5-8400T. It is one machine, shared with the load generator and receiver, and PipeBench's maintainer sells a competing tool. These numbers can't be compared with PipeBench's published ones.

## What this does and doesn't show

- Both of our servers passed all 22 correctness runs (11 tests each) and handled more lines per CPU core than Vector and Fluent Bit in every performance test.
- **The size of that lead is not yet a trustworthy finding.** It is 4 to 24 times on the tests with usable output. The owner's rule is that a large win over industry tools in realistic tests probably means an error in the method. The [audit](AUDIT.md) looked for one and found no single error, but the causes listed below remain, and no Vector or Fluent Bit expert has reviewed the tool configs.
- **We lose on memory in several tests**, and two batch marks were missed.
- **Goose and Rust are close.** On 10 of 13 tests their throughput is within 3%. One round can't separate them.

## Freeze and checks

The code was frozen at `e763a39` before any PipeBench round; see [FREEZE.md](FREEZE.md). Before writing this I checked that source and image hashes still match and that nothing has changed since.

| Check, on the frozen code | Result |
|---|---|
| Behavior tests, both servers | All passed |
| Output compared with Vector, both servers | 2,286 records, 0 differences |
| PipeBench correctness tests, both servers | 11 of 11 passed, 0% loss |
| Deliberately broken versions of the Goose server | 14 of 15 caught. Removing the SIGPIPE guard wasn't caught, cause unverified |
| Batch tool tests: Python, Goose, Rust | 31 of 31 each |
| Batch adversarial data: Python, Goose, Rust | 114 of 114 and 150 of 150 each |
| Batch fuzz: Goose and Rust against Python | 20,000 cases, 0 failures |

Correctness tests were run for our two servers only, so they say nothing about how Vector or Fluent Bit would score.

## Batch tool marks

These marks were set before the fixes. Timing ran pinned to one core, in paired rounds.

| Mark | Result | Verdict |
|---|---|---|
| Hex scan at most 10% over the pre-change Goose program, HDFS | 12.9% over (range 8.5–19.6%), 10 rounds | **Missed** |
| Goose at least 0.9× Rust's speed, HDFS | 0.94× by wall time and by CPU | Met |
| Goose at least 0.9× Rust's speed, BGL | 0.897× by wall time, 0.89× by CPU | **Missed, narrowly** |
| Goose memory at most 1.1× Rust's, escape-heavy data | 1.00× | Met |
| 0 leftover dashed IPs on SSH | 0 in development. Not yet repeated on the frozen binary, to avoid disturbing the running rounds | Open |
| Stated maximum line length, same handling in all programs | Covered by the 31 batch tests | Met |
| Fluent Bit reject flake, feature table | Investigated in the [audit](AUDIT.md). The flake's cause wasn't resolved: Fluent Bit's reject output was wrong in 4 of 25 runs at both Grace settings tried | Written down |

The two misses stand. Rerunning until they pass wouldn't count, and any code change would need a new freeze.

In the same timing, on HDFS, the new Goose program used 26% less memory than the pre-change one, and both languages used about the same memory on all four data sets. Rust was faster on BGL and SSH (about 10% each) and on HDFS (about 6%), and Goose was faster on escape-heavy data (about 10%).

## PipeBench, round 1

"D" is Vector's Debian image, run on two tests only. PipeBench uses the Alpine image, and Debian was about 20% faster in both, so Vector's other numbers probably understate it by a similar amount on processing tests.

### Throughput, million lines per second

| Test | Goose | Rust | Vector | Vector D | Fluent Bit |
|---|---:|---:|---:|---:|---:|
| `tcp_to_tcp` | 7.13 | 6.94 | 0.68 | | 1.07 |
| `tcp_to_blackhole` | 29.40 | 29.50 | 1.21 | | 1.34 |
| `regex_mask` | 6.02 | 6.25 | 0.47 | 0.56 | 0.21 |
| `set_field` | 4.70 | 4.58 | 0.35 | | 0.65 |
| `syslog_parsing` | 5.58 | 5.61 | 0.30 | | 0.10 |
| `real_world_1` | 5.56 | 5.62 | 0.30 | | 0.08 |
| `real_ssh_mask` (ours) | 9.38 | 9.18 | 0.54 | 0.65 | 0.26 |
| `real_hdfs_mask` (ours) | 7.87 | 7.71 | 0.53 | | 0.13 |
| `real_ssh_syslog` (ours) | 6.66 | 6.57 | 0.32 | | 0.17 |
| `tcp_to_http` | 2.73 | 2.67 | 0.70 | | 1.08 |
| `file_to_tcp` (see below) | 3.72 | 3.74 | 0.17 | | 0.03 |
| `tcp_to_tcp_persistent` | 2.97 | 2.73 | 0.19 | | 0.73 |
| `disk_buffer` | 2.55 | 2.85 | 0.19 | | 0.75 |

### Thousand lines per second, per CPU core

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Goose ÷ best tool |
|---|---:|---:|---:|---:|---:|---:|
| `tcp_to_tcp` | 4,601 | 4,581 | 210 | | 402 | 11.5 |
| `tcp_to_blackhole` | 27,282 | 27,612 | 239 | | 1,374 | 19.9 |
| `regex_mask` | 2,636 | 2,668 | 132 | 159 | 163 | 16.2 |
| `set_field` | 1,742 | 1,866 | 139 | | 313 | 5.6 |
| `syslog_parsing` | 1,489 | 1,522 | 99 | | 51 | 15.0 |
| `real_world_1` | 1,484 | 1,528 | 96 | | 44 | 15.4 |
| `real_ssh_mask` (ours) | 3,832 | 3,567 | 139 | 175 | 185 | 20.7 |
| `real_hdfs_mask` (ours) | 3,102 | 2,907 | 132 | | 107 | 23.6 |
| `real_ssh_syslog` (ours) | 2,389 | 2,232 | 103 | | 132 | 18.1 |
| `tcp_to_http` | 3,596 | 3,239 | 161 | | 402 | 8.9 |
| `file_to_tcp` | 7,637 | 7,547 | 133 | | 293 | not usable |
| `tcp_to_tcp_persistent` | 1,661 | 1,646 | 80 | | 343 | 4.8 |
| `disk_buffer` | 1,531 | 1,745 | 83 | | 354 | 4.3 |

Both servers pass the competing bar from the spec, 1.3× better CPU per event on a processing test, in this round. Rust's ratios are close to Goose's, from 4.8 to 22.1 on the same tests (`disk_buffer` 4.9, `tcp_to_tcp_persistent` 4.8, `set_field` 6.0).

### Peak memory, MB

| Test | Goose | Rust | Vector | Vector D | Fluent Bit |
|---|---:|---:|---:|---:|---:|
| `tcp_to_tcp` | 475 | 338 | **99** | | 8,244 |
| `tcp_to_blackhole` | **10** | 11 | 90 | | 230 |
| `regex_mask` | 276 | 429 | **102** | 104 | 2,033 |
| `set_field` | **88** | 91 | 104 | | 244 |
| `syslog_parsing` | **45** | 46 | 108 | | 64 |
| `real_world_1` | **38** | 41 | 105 | | 61 |
| `real_ssh_mask` (ours) | **23** | 24 | 101 | 108 | 1,084 |
| `real_hdfs_mask` (ours) | **24** | 29 | 104 | | 685 |
| `real_ssh_syslog` (ours) | **36** | 101 | 107 | | 915 |
| `tcp_to_http` | 26 | **25** | 201 | | 7,961 |
| `file_to_tcp` | 60 | **49** | 75 | | 110 |
| `tcp_to_tcp_persistent` | 445 | 417 | 119 | | **34** |
| `disk_buffer` | 381 | 401 | 122 | | **30** |

**Where we lose:** Vector uses roughly a fifth to a third of our memory on `tcp_to_tcp`, `regex_mask` and both disk tests. Fluent Bit uses about a thirteenth on the two disk tests. We haven't established why ours is high there. It may be kernel socket or file cache charged to the container, but that is unverified, so these count as losses for now. Fluent Bit's very large figures on the TCP tests may come from buffering at the generator's full rate, which is also unverified.

### Loss and output size

| Test | Goose / Rust loss % | Vector % | Vector D % | Fluent Bit % | Bytes per line: ours, Vector, Fluent Bit |
|---|---|---:|---:|---:|---|
| `tcp_to_tcp` | 0 / 0 | 0.12 | | 0.00 | 257, 257, 292 |
| `regex_mask` | 0 / 0 | 0.18 | 0.06 | 0.80 | 271, 271, 292 |
| `set_field` | 0 / 0 | 0.26 | | 0.08 | 407, 405, 329 |
| `syslog_parsing` | 0 / 0 | 0.32 | | 1.26 | 351, 351, 307 |
| `real_world_1` | 0 / 0 | 0.31 | | 1.46 | 351, 351, 307 |
| `real_ssh_mask` | 0 / 0 | 0.31 | 0.36 | 0.49 | 118, 118, 139 |
| `real_hdfs_mask` | 0 / 0 | 0.36 | | 2.04 | 146, 146, 167 |
| `real_ssh_syslog` | 0 / 0 | 0.89 | | 1.52 | 219, 219, 171 |
| `tcp_to_http` | 0 / 0.01 | 0.06 | | 0.00 | 257, 257, 292 |
| `file_to_tcp` | 0 / 0 | 94.46 | | 99.06 | 257, 257, 292 |
| `tcp_to_tcp_persistent` | 0 / 0 | 0.63 | | 0.05 | 257, 257, 292 |
| `disk_buffer` | 0 / 0 | 0.58 | | 0.07 | 257, 257, 292 |

`tcp_to_blackhole` sends nothing out, so PipeBench shows 100% loss for every program, and its numbers show input handling only. On `set_field` our lines are 2 bytes longer than Vector's, cause not found. PipeBench's receiver only counts lines, so these runs don't verify content. Content was checked separately against Vector, as listed above.

## Why these numbers need care

1. **`file_to_tcp` isn't a usable comparison for the tools.** The generator wrote 50 to 57 GB in 60 seconds, and the run counts lines not yet delivered as lost. So the 94% and 99% figures are mostly backlog at the end of the window, not shown data loss. Fluent Bit used only 0.09 cores and delivered 1.8 million lines, which looks like a stall rather than a CPU limit. Its cause isn't known, and it could be a problem in the test or our config for it.
2. **Most tests run at saturation.** The generator sends as fast as it can. Real systems normally run below their limit, and CPU per event at a fixed lower rate is untested. Vector's and Fluent Bit's small losses at the end of each run may also come from the fixed window.
3. **We do less work per event.** Our servers have no general event model, routing, TLS, metrics or memory buffers, and they use one timestamp per block. That accounts for an unknown share of the lead. This is a difference in product, not language.
4. **Lighter delivery.** Our server opens one sink connection per input connection and counts a TCP write as delivered. Its disk buffer syncs at most every 500 ms. We haven't compared those guarantees with what Vector and Fluent Bit promise in their disk tests.
5. **Tool configs are unreviewed.** Our Fluent Bit tuning attempts didn't help, and `Threaded on` delivered nothing, cause not found.
6. **Same machine.** The generator and receiver share the 6 cores with the program under test, and a faster program makes them work harder.

[FAIRNESS.md](FAIRNESS.md) and [AUDIT.md](AUDIT.md) have the full reasoning.

## Goose and Rust

Goose's throughput divided by Rust's runs from 0.89 (`disk_buffer`) to 1.09 (`tcp_to_tcp_persistent`). Those two tests use an identical config on our servers, yet they lean opposite ways, so gaps of this size may well be noise. Rust's memory on `real_ssh_syslog` (101 MB against 36) is the largest other gap. Three rounds will show what holds.

The [fairness review](FAIRNESS.md) changed Rust before this run. It removed four handicaps that all favored Goose, so the earlier development gaps shouldn't be expected to return.

## Conduct of the run

- **Batch timing** came from the first run, which was stopped at the first freeze. The batch code is byte-for-byte unchanged since then, so it stands, as amendment A7 says.
- **Run order** rotates by test and round, and every run is kept in `results/i5-8400t/round-N/`.
- **Carry-over.** Runs start right after one another, so the 1-minute load before a run was often 3 to 20. Rotation spreads this across programs but doesn't remove it. Round 1's few comparison gaps should be read with that in mind.
- **My own activity during runs.** I read result files and ran small scripts during the last correctness run of round 1 and the first runs of round 2. One of my commands hung at about 06:53, for about 2 minutes, in a grep waiting on input. It didn't appear in the top CPU users at the time, but it overlapped round 2's `tcp_to_tcp`. Writing and committing this report also happened during round 2. I can't rule out a small effect on those runs, so they stay in with this note.

## Not done yet

- Rounds 2 and 3.
- The 0-leftover check on the frozen binary, after the rounds.
- Independent hardware. `third_party.sh` has never been run end to end, and renting the c7i.4xlarge is the owner's decision.
- Expert review of the Vector and Fluent Bit configs, also the owner's decision, since it means asking publicly.
