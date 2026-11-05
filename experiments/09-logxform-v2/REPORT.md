# Experiment 9: results

**Status: the local evaluation is finished, 3 of 3 rounds, including the correctness tests on Vector and Fluent Bit ([amendment A8](SPEC.md)).** Independent hardware hasn't been tested, and the tool configs need fixing first, so this isn't the end of the evaluation.

This report covers logXform of Goose and a Rust version with the same design, against Vector and Fluent Bit, on the owner's i5-8400T. It is one machine, shared with the load generator and receiver, and PipeBench's maintainer sells a competing tool. These numbers can't be compared with PipeBench's published ones.

## What this does and doesn't show

- Both of our servers passed all 66 correctness runs and handled more lines per CPU core than Vector and Fluent Bit in every performance test. In the same correctness tests, Vector passed 23 of 33 runs and Fluent Bit 21 of 33.
- **Those passes don't show that our servers are more correct.** Reruns traced most of Fluent Bit's loss in three of its four failing tests to the configs PipeBench ships, and showed that Vector's lost lines on `tcp_to_tcp_persistent` never reached its sinks. See [Correctness on the tools](#correctness-on-the-tools).
- **The size of that lead is not yet a trustworthy finding.** It is about 5 to 23 times on the tests with usable output. The owner's rule is that a large win over industry tools in realistic tests probably means an error in the method. The [audit](AUDIT.md) found no single error in the performance tests, but the correctness work has now found real faults in the shipped tool configs, the causes listed below remain, and no Vector or Fluent Bit expert has reviewed the configs. The lead is stable across rounds, which shows it repeats, not that it is fair.
- **We lose on memory in four tests**, and two batch marks were missed.
- **Goose and Rust are close, with no overall winner.** On 10 of 13 tests their median throughput is within 3%, and the other three have overlapping ranges. Each leads on some tests by a small margin.

## Freeze and checks

The code was frozen at `e763a39` before any PipeBench round; see [FREEZE.md](FREEZE.md). Source, image and batch binary hashes still match, and all 228 runs in the three rounds have different timestamps, so no round reused a stale result.

| Check, on the frozen code | Result |
|---|---|
| Behavior tests, both servers | All passed |
| Output compared with Vector, both servers | 2,286 records, 0 differences |
| PipeBench correctness tests, both servers | 11 of 11 passed in each of 3 rounds, 0% loss |
| Deliberately broken versions of the Goose server | 14 of 15 caught. Removing the SIGPIPE guard wasn't caught, cause unverified |
| Batch tool tests: Python, Goose, Rust | 31 of 31 each |
| Batch adversarial data: Python, Goose, Rust | 114 of 114 and 150 of 150 each |
| Batch fuzz: Goose and Rust against Python | 20,000 cases, 0 failures |

The frozen driver ran the correctness tests on our two servers only. That was an omission of mine, and amendment A8 added the tools.

## Batch tool marks

These marks were set before the fixes. Timing ran pinned to one core, in paired rounds.

| Mark | Result | Verdict |
|---|---|---|
| Hex scan at most 10% over the pre-change Goose program, HDFS | 12.9% over (range 8.5–19.6%), 10 rounds | **Missed** |
| Goose at least 0.9× Rust's speed, HDFS | 0.94× by wall time and by CPU | Met |
| Goose at least 0.9× Rust's speed, BGL | 0.897× by wall time, 0.89× by CPU | **Missed, narrowly** |
| Goose memory at most 1.1× Rust's, escape-heavy data | 1.00× | Met |
| 0 leftover dashed IPs on SSH | 0 on the frozen binaries, 655,147 lines, under the stricter count in amendment A9. Goose and Rust outputs are byte-identical | Met |
| Stated maximum line length, same handling in all programs | Covered by the 31 batch tests | Met |
| Fluent Bit reject flake, feature table | Investigated in the [audit](AUDIT.md). The flake's cause wasn't resolved: Fluent Bit's reject output was wrong in 4 of 25 runs at both Grace settings tried | Written down |

The two misses stand. Rerunning until they pass wouldn't count, and any code change would need a new freeze.

In the same timing, on HDFS, the new Goose program used 26% less memory than the pre-change one, and both languages used about the same memory on all four data sets. Rust was faster on BGL and SSH (about 10% each) and on HDFS (about 6%), and Goose was faster on escape-heavy data (about 10%).

## PipeBench, 3 rounds

Figures are medians, with Goose and Rust's lowest and highest in brackets. "D" is Vector's Debian image, run on two tests only. PipeBench uses the Alpine image, and Debian was 17–18% faster in both, so Vector's other numbers probably understate it on processing tests. Every run is in [results/i5-8400t](results/i5-8400t).

### Throughput, million lines per second

| Test | Goose | Rust | Vector | Vector D | Fluent Bit |
|---|---|---|---:|---:|---:|
| `tcp_to_tcp` | 7.13 (6.92–7.49) | 6.94 (6.50–7.59) | 0.68 | | 1.16 |
| `tcp_to_blackhole` | 29.24 (29.01–29.40) | 29.22 (29.18–29.50) | 1.20 | | 1.34 |
| `regex_mask` | 6.02 (5.84–6.99) | 6.77 (6.25–6.87) | 0.47 | 0.56 | 0.21 |
| `set_field` | 4.72 (4.70–4.77) | 4.71 (4.58–4.74) | 0.35 | | 0.65 |
| `syslog_parsing` | 5.49 (5.21–5.58) | 5.60 (5.56–5.61) | 0.30 | | 0.10 |
| `real_world_1` | 5.54 (5.52–5.56) | 5.62 (5.57–5.62) | 0.30 | | 0.08 |
| `real_ssh_mask` (ours) | 9.32 (9.30–9.38) | 9.12 (9.09–9.18) | 0.55 | 0.64 | 0.26 |
| `real_hdfs_mask` (ours) | 7.82 (7.80–7.87) | 7.68 (7.65–7.71) | 0.53 | | 0.13 |
| `real_ssh_syslog` (ours) | 6.61 (6.61–6.66) | 6.57 (6.56–6.57) | 0.31 | | 0.17 |
| `tcp_to_http` | 2.73 (2.73–2.74) | 2.67 (2.67–2.68) | 0.69 | | 1.13 |
| `file_to_tcp` (see below) | 3.62 (3.11–3.72) | 3.22 (2.91–3.74) | 0.18 | | 0.03 |
| `tcp_to_tcp_persistent` | 2.57 (2.40–2.97) | 2.73 (2.43–2.74) | 0.19 | | 0.73 |
| `disk_buffer` | 2.37 (2.30–2.55) | 2.40 (2.18–2.85) | 0.19 | | 0.75 |

### Thousand lines per second, per CPU core

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Goose ÷ best tool | Rust ÷ best tool |
|---|---|---|---:|---:|---:|---:|---:|
| `tcp_to_tcp` | 4,601 (4,599–4,609) | 4,581 (4,547–4,701) | 210 | | 402 | 11.5 | 11.4 |
| `tcp_to_blackhole` | 26,882 (26,768–27,282) | 27,389 (27,359–27,612) | 239 | | 1,369 | 19.6 | 20.0 |
| `regex_mask` | 2,636 (2,465–2,765) | 2,574 (2,542–2,668) | 129 | 160 | 163 | 16.2 | 15.8 |
| `set_field` | 1,742 (1,715–1,746) | 1,784 (1,748–1,866) | 143 | | 313 | 5.6 | 5.7 |
| `syslog_parsing` | 1,491 (1,489–1,519) | 1,522 (1,522–1,530) | 99 | | 51 | 15.1 | 15.4 |
| `real_world_1` | 1,484 (1,482–1,485) | 1,532 (1,528–1,551) | 96 | | 45 | 15.4 | 15.9 |
| `real_ssh_mask` (ours) | 3,832 (3,797–3,940) | 3,567 (3,560–3,681) | 139 | 175 | 186 | 20.6 | 19.2 |
| `real_hdfs_mask` (ours) | 3,102 (3,086–3,193) | 2,907 (2,889–2,987) | 133 | | 108 | 23.4 | 21.9 |
| `real_ssh_syslog` (ours) | 2,316 (2,313–2,389) | 2,232 (2,217–2,289) | 103 | | 132 | 17.5 | 16.9 |
| `tcp_to_http` | 3,606 (3,596–3,731) | 3,247 (3,239–3,340) | 161 | | 401 | 9.0 | 8.1 |
| `file_to_tcp` | 7,637 (7,261–7,759) | 7,514 (7,141–7,547) | 134 | | 293 | not usable | not usable |
| `tcp_to_tcp_persistent` | 1,661 (1,645–1,676) | 1,646 (1,626–1,879) | 83 | | 343 | 4.8 | 4.8 |
| `disk_buffer` | 1,728 (1,531–1,764) | 1,745 (1,488–1,867) | 83 | | 343 | 5.0 | 5.1 |

Both servers pass the competing bar from the spec, 1.3× better CPU per event on a processing test. Either server's lowest run against the tools' highest run still gives at least 4.2× on every usable test. Read this together with the caveats below.

### Peak memory, MB

| Test | Goose | Rust | Vector | Vector D | Fluent Bit |
|---|---|---|---:|---:|---:|
| `tcp_to_tcp` | 370 (310–475) | 315 (151–338) | **99** | | 8,836 |
| `tcp_to_blackhole` | **12** (10–13) | 13 (11–13) | 90 | | 230 |
| `regex_mask` | 276 (128–365) | 132 (111–429) | **104** | 105 | 2,033 |
| `set_field` | **85** (78–88) | 88 (88–91) | 104 | | 227 |
| `syslog_parsing` | 45 (40–49) | **39** (36–46) | 108 | | 64 |
| `real_world_1` | 43 (38–52) | **41** (35–47) | 107 | | 55 |
| `real_ssh_mask` (ours) | **23** (21–23) | 25 (24–26) | 103 | 105 | 1,084 |
| `real_hdfs_mask` (ours) | **24** (24–27) | 29 (24–32) | 104 | | 690 |
| `real_ssh_syslog` (ours) | **40** (36–47) | 49 (39–101) | 107 | | 922 |
| `tcp_to_http` | 26 (26–26) | **25** (25–26) | 201 | | 9,914 |
| `file_to_tcp` | 51 (35–60) | **48** (43–49) | 73 | | 124 |
| `tcp_to_tcp_persistent` | 427 (396–445) | 417 (395–420) | 119 | | **33** |
| `disk_buffer` | 339 (298–381) | 349 (346–401) | 121 | | **31** |

**Where we lose:** Vector uses less memory than both of our servers on `tcp_to_tcp` and `regex_mask`, and about a third of ours on the two disk tests, where Fluent Bit uses less than a tenth. We haven't established why ours is high there, and our figures on those tests vary widely between rounds. It may be kernel socket or file cache charged to the container, but that is unverified, so these count as losses for now. Fluent Bit's figures of 9 to 10 GB on the plain TCP tests may come from buffering at the generator's full rate, which is also unverified.

### Loss and output size

| Test | Goose / Rust loss % | Vector % | Vector D % | Fluent Bit % | Bytes per line: ours, Vector, Fluent Bit |
|---|---|---:|---:|---:|---|
| `tcp_to_tcp` | 0 / 0 | 0.12 | | 0.12 | 257, 257, 292 |
| `regex_mask` | 0 / 0 | 0.16 | 0.11 | 0.80 | 271, 271, 292 |
| `set_field` | 0 / 0 | 0.26 | | 0.06 | 407, 405, 329 |
| `syslog_parsing` | 0 / 0 | 0.35 | | 1.26 | 351, 351, 307 |
| `real_world_1` | 0 / 0 | 0.31 | | 1.90 | 351, 351, 307 |
| `real_ssh_mask` | 0 / 0 | 0.31 | 0.36 | 0.95 | 118, 118, 139 |
| `real_hdfs_mask` | 0 / 0 | 0.32 | | 2.04 | 146, 146, 167 |
| `real_ssh_syslog` | 0 / 0 | 0.78 | | 1.60 | 219, 219, 171 |
| `tcp_to_http` | 0 / 0 | 0.06 | | 0.04 | 257, 257, 292 |
| `file_to_tcp` | 0 / 0 | 94.09 | | 99.12 | 257, 257, 292 |
| `tcp_to_tcp_persistent` | 0 / 0 | 0.63 | | 0.05 | 257, 257, 292 |
| `disk_buffer` | 0 / 0 | 0.58 | | 0.07 | 257, 257, 292 |

`tcp_to_blackhole` sends nothing out, so PipeBench shows 100% loss for every program, and its numbers show input handling only. On `set_field` our lines are 2 bytes longer than Vector's, cause not found. PipeBench's receiver only counts lines, so these runs don't verify content. Content was checked separately against Vector, as listed above.

## Correctness on the tools

These 66 runs used the configs PipeBench ships. All have results and different timestamps. They ran after the three rounds, not alongside our servers' runs.

| Test | Goose | Rust | Vector | Vector loss % | Fluent Bit | Fluent Bit loss % |
|---|---:|---:|---:|---:|---:|---:|
| `file_rotate_create` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `file_rotate_truncate` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `file_truncate` | 3 of 3 | 3 of 3 | **2 of 3** | 0–0.7 | **0 of 3** | 50.1–50.2 |
| `file_rotate_restart` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `tcp_to_tcp_persistent` | 3 of 3 | 3 of 3 | **0 of 3** | 2.7–10.6 | **0 of 3** | 90.4–100 |
| `tcp_to_tcp_persistent_restart` | 3 of 3 | 3 of 3 | **0 of 3** | 7.0–10.7 | **0 of 3** | 100 |
| `tcp_to_tcp_persistent_crash` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `disk_buffer_persistence` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `tcp_to_http_persistent` | 3 of 3 | 3 of 3 | **0 of 3** | 1.3–1.6 | **0 of 3** | 40.5–41.2 |
| `sighup` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |
| `wrapped_json` | 3 of 3 | 3 of 3 | 3 of 3 | 0 | 3 of 3 | 0 |

The tools fail the same tests here as in PipeBench's published c7i.12xlarge results, so this machine isn't the cause.

**Finding the causes.** These reruns changed one thing at a time. They are development runs under a separate label, they don't change the counted results above, and each has only one or two samples. The evidence is in [results/i5-8400t/investigation](results/i5-8400t/investigation).

| Failure | Change tried | Loss after | What it shows |
|---|---|---:|---|
| Fluent Bit, `tcp_to_tcp_persistent`, 90–100% | Added `Retry_Limit false` | 0%, 0% | Caused by the config. It doesn't set `Retry_Limit`, and the log shows chunks given up with `cannot be retried` while the receiver is down |
| Fluent Bit, `..._restart`, 100% | Same | 0.06%, 0% | Mostly the config. One run would still fail the 0% mark |
| Fluent Bit, `tcp_to_http_persistent`, 41% | Raised `storage.total_limit_size` from 2G to 8G | 0.41%, 0.46% | Mostly the config. It already had `Retry_Limit false`, but capped storage below the roughly 3 GB sent. The rest is unexplained and would still fail |
| Fluent Bit, `file_truncate`, 50% | Debug logging; polling instead of inotify | 50.24%, 50.08% | **Not explained.** Debug logging shows no truncation message. Goose and Rust pass, and Vector usually does, so the test can be passed |
| Vector, `tcp_to_tcp_persistent`, 3–11% | Added a second sink, a file, to count lines | 13.35%, 10.27% | The file and TCP sinks got exactly the same counts: 389,930 and 403,770. So the lines never reached either sink, and the disk buffer and TCP sink aren't the cause. **Whether Vector or the test's generator is at fault is unknown** |

Not investigated: Vector's `tcp_to_tcp_persistent_restart` and `tcp_to_http_persistent` losses, and its single 0.7% miss on `file_truncate`.

**What follows from this:**

- "We pass where they fail" isn't a fair claim, and this report doesn't make it. For Fluent Bit it would mostly compare our default behavior, which retries without limit and pushes back on the sender, with a shipped config that allows drops. For Vector the cause is still unknown.
- This supports the owner's rule that a result like this probably points to a fault in the method. PipeBench's maintainer wrote these configs and sells a competing tool. We found no sign of intent, only that the configs can't be taken as the tools' best.
- It raises a question this work hasn't answered: whether the performance configs also understate the tools. A retry limit wouldn't affect those runs, but they have had no expert review either.

## Why these numbers need care

1. **`file_to_tcp` isn't a usable comparison for the tools.** In round 1 the generator wrote 50 to 57 GB in 60 seconds, and the run counts lines not yet delivered as lost. So the 94% and 99% figures are mostly backlog at the end of the window, not shown data loss. In round 1, Fluent Bit used only 0.09 cores and delivered 1.8 million lines, which looks like a stall rather than a CPU limit. Its cause isn't known, and it could be a problem in the test or our config for it.
2. **Most tests run at saturation.** The generator sends as fast as it can. Real systems normally run below their limit, and CPU per event at a fixed lower rate is untested. Vector's and Fluent Bit's small losses at the end of each run may also come from the fixed window.
3. **We do less work per event.** Our servers have no general event model, routing, TLS, metrics or memory buffers, and they use one timestamp per block. That accounts for an unknown share of the lead. This is a difference in product, not language.
4. **Lighter delivery.** Our server opens one sink connection per input connection and counts a TCP write as delivered. Its disk buffer syncs at most every 500 ms. We haven't compared those guarantees with what Vector and Fluent Bit promise in their disk tests.
5. **Tool configs are unreviewed, and some are demonstrably at fault** (see above). Our Fluent Bit tuning attempts on the performance tests didn't help, and `Threaded on` delivered nothing, cause not found.
6. **Same machine.** The generator and receiver share the 6 cores with the program under test, and a faster program makes them work harder.

[FAIRNESS.md](FAIRNESS.md) and [AUDIT.md](AUDIT.md) have the full reasoning.

## Goose and Rust

Goose's median throughput divided by Rust's runs from 0.89 (`regex_mask`) to 1.13 (`file_to_tcp`), and those two have overlapping ranges, like most tests. The tests where the two never overlapped are below. Three runs each is a small sample, so these are leads, not settled differences.

| Test | Throughput | Lines per core |
|---|---|---|
| `real_ssh_mask` | Goose +2.2% | Goose +7.4% |
| `real_hdfs_mask` | Goose +1.8% | Goose +6.7% |
| `real_ssh_syslog` | Goose +0.7% | Goose +3.7% |
| `tcp_to_http` | Goose +2.1% | Goose +11% |
| `real_world_1` | Rust +1.5% | Rust +3.2% |
| `syslog_parsing` | overlap | Rust +2.1% |
| `set_field` | overlap | Rust +2.3% |
| `tcp_to_blackhole` | overlap | Rust +1.9% |

Two gaps seen in round 1 didn't hold. `disk_buffer` and `tcp_to_tcp_persistent` use an identical config on our servers, and which one led changed from round to round. Rust's 101 MB on `real_ssh_syslog` was one high run.

The [fairness review](FAIRNESS.md) changed Rust before this run. It removed four handicaps that all favored Goose, and the gaps seen in development shrank or reversed. For example, Goose's lead on `regex_mask` in development is now a Rust lead in throughput, with overlapping ranges. Those development numbers aren't counted, so this is only an indication.

## Conduct of the run

- **Batch timing** came from the first run, which was stopped at the first freeze. The batch code is byte-for-byte unchanged since then, so it stands, as amendment A7 says.
- **Run order** rotates by test and round, and every run is kept in `results/i5-8400t/round-N/`.
- **Carry-over.** Runs start right after one another, so the 1-minute load before a run was often 3 to 20. Rotation spreads this across programs but doesn't remove it.
- **Other programs.** VS Code and `codex` stayed open on the machine, each averaging a few percent of a core. I can't rule out other use of the machine during the run.
- **My own activity during runs.** I read result files and ran small scripts during the last correctness run of round 1 and the first runs of round 2. One of my commands hung at about 06:53, for about 2 minutes, in a grep waiting on input. It didn't appear in the top CPU users at the time, but it overlapped round 2's `tcp_to_tcp`. I also committed the interim report during round 2's first tests. During round 2's correctness tests I wrote and stub-tested the tool script and committed it. Small scripts that wait for a finish ran throughout. I can't rule out a small effect on those runs, so they stay in with this note.
- **Tool correctness runs** came after the frozen rounds, on the same PipeBench commit and images. These tests are pass or fail and light on CPU, but I can't rule out other use of the machine then either.
- **A weakness in the frozen driver.** `take_result.py` takes the last stored result for a test, so a run that timed out could have repeated an earlier round's numbers. All 228 timestamps differ, so that didn't happen. The tool script stores each round separately, and its 66 timestamps differ too.

## Not done yet

- Corrected tool configs, in a new freeze with new runs, since the fixes above aren't counted.
- Expert review of the Vector and Fluent Bit configs. This is the owner's decision, since it means asking publicly.
- A test at a fixed, lower rate.
- The cause of our high memory on `tcp_to_tcp`, `regex_mask` and the disk tests, and of Vector's lost lines and Fluent Bit's `file_truncate` failure.
- Independent hardware. `third_party.sh` has never been run end to end, and renting the c7i.4xlarge is the owner's decision. Running it before the configs are fixed would repeat the same faults.
