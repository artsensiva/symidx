# Experiment 9: all results in tables

First full evaluation with code frozen beforehand, comparing logXform of Goose and a Rust version with Vector and Fluent Bit on one machine. It was planned as a final evaluation, but its main result is a list of problems to resolve: faults in the shipped tool configs, unexplained tool failures, our high memory on four tests, and two missed batch marks. The performance lead over the tools is not confirmed.

Figures are the median of 3 rounds, with the lowest and highest in brackets. All runs were on the owner's i5-8400T, which also ran the load generator and receiver. The tables were recomputed from the 294 raw run files in [results/i5-8400t](results/i5-8400t). The [report](REPORT.md) has the reasoning and caveats.

## How it was tested

| Topic | Where |
|---|---|
| Spec, marks set in advance, amendments A1–A9 | [SPEC.md](SPEC.md) |
| Freeze at `e763a39`, hashes | [FREEZE.md](FREEZE.md) |
| Changes made so that Rust and the tools were treated fairly | [FAIRNESS.md](FAIRNESS.md) |
| Audit of the earlier tool comparisons | [AUDIT.md](AUDIT.md) |
| Findings, conduct of the run, what isn't done | [REPORT.md](REPORT.md) |
| PipeBench driver, frozen | [pipebench/run_formal.sh](pipebench/run_formal.sh) |
| PipeBench driver for the tools' correctness runs | [pipebench/run_tools_correctness.sh](pipebench/run_tools_correctness.sh) |
| Server behavior tests, comparison with Vector, broken versions | [test_server.py](test_server.py), [compare_vector.py](compare_vector.py), [mutate_server.py](mutate_server.py) |
| Batch tests and fuzz | [batch_test.py](batch_test.py), [batch_fuzz.py](batch_fuzz.py) |
| Leftover check | [check_leftovers.py](check_leftovers.py) |
| Script for independent hardware, never run end to end | [third_party.sh](third_party.sh) |

PipeBench is pinned at `cdb484f6a187384f3589e0bbcda8c1d6d7d0e528`. Its maintainer sells a competing tool, and these numbers can't be compared with its published ones.

## 1. Builds

| Build | What it is | Comment |
|---|---|---|
| **Goose** | logXform of Goose, [goose/](goose), Goose v2026.3, frozen at `e763a39` | Passed every correctness run. Lost on memory in 4 tests and missed 2 batch marks. |
| **Rust** | Same design as Goose, [rust/](rust), Rust 1.99.1, same freeze | Close to Goose, with no overall winner. |
| **Goose pre-change** | The earlier batch program | Batch baseline only, on HDFS. |
| **Python** | Batch reference program | Checks correctness only, not timed. |
| **Vector** | `0.54.0-alpine`, PipeBench's config | The image PipeBench uses. |
| **Vector D** | `0.54.0-debian`, same config | Run on 2 performance tests only, and 17–18% faster than Alpine on both. Vector's other processing numbers probably understate it. |
| **Fluent Bit** | `5.0`, PipeBench's config | The shipped configs caused most of its loss in 3 of its 4 failing tests. `Threaded on` delivered nothing, cause not found. |

## 2. Throughput (million lines per second)

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Comment |
|---|---:|---:|---:|---:|---:|---|
| `tcp_to_tcp` | 7.13 (6.92–7.49) | 6.94 (6.50–7.59) | 0.68 (0.64–0.71) | | 1.16 (1.07–1.20) | Forwarding, no transforms |
| `tcp_to_blackhole` | 29.24 (29.01–29.40) | 29.22 (29.18–29.50) | 1.20 (1.20–1.21) | | 1.34 (1.34–1.35) | Input handling only, nothing is sent out |
| `regex_mask` | 6.02 (5.84–6.99) | 6.77 (6.25–6.87) | 0.47 (0.47–0.48) | 0.56 (0.55–0.56) | 0.21 (0.21–0.22) | Goose and Rust ranges overlap |
| `set_field` | 4.72 (4.70–4.77) | 4.71 (4.58–4.74) | 0.35 (0.35–0.35) | | 0.65 (0.65–0.67) | Adds one field. Our lines are 2 bytes longer than Vector's, cause not found |
| `syslog_parsing` | 5.49 (5.21–5.58) | 5.60 (5.56–5.61) | 0.30 (0.30–0.30) | | 0.10 (0.10–0.10) | |
| `real_world_1` | 5.54 (5.52–5.56) | 5.62 (5.57–5.62) | 0.30 (0.29–0.30) | | 0.08 (0.08–0.08) | Parsing, filtering and routing. Rust leads slightly |
| `real_ssh_mask` (ours) | 9.32 (9.30–9.38) | 9.12 (9.09–9.18) | 0.55 (0.54–0.55) | 0.64 (0.64–0.65) | 0.26 (0.25–0.26) | Our own test on real logs. Goose leads slightly |
| `real_hdfs_mask` (ours) | 7.82 (7.80–7.87) | 7.68 (7.65–7.71) | 0.53 (0.52–0.53) | | 0.13 (0.13–0.13) | Our own test. Goose leads slightly |
| `real_ssh_syslog` (ours) | 6.61 (6.61–6.66) | 6.57 (6.56–6.57) | 0.31 (0.31–0.32) | | 0.17 (0.17–0.17) | Our own test. Goose leads slightly |
| `tcp_to_http` | 2.73 (2.73–2.74) | 2.67 (2.67–2.68) | 0.69 (0.69–0.70) | | 1.13 (1.08–1.15) | Goose leads slightly |
| `file_to_tcp` | 3.62 (3.11–3.72) | 3.22 (2.91–3.74) | 0.18 (0.17–0.18) | | 0.03 (0.03–0.03) | **Not usable for the tools**, see table 6 |
| `tcp_to_tcp_persistent` | 2.57 (2.40–2.97) | 2.73 (2.43–2.74) | 0.19 (0.19–0.19) | | 0.73 (0.72–0.73) | Disk persistence. The lead between Goose and Rust changed by round |
| `disk_buffer` | 2.37 (2.30–2.55) | 2.40 (2.18–2.85) | 0.19 (0.19–0.19) | | 0.75 (0.74–0.75) | Same config on our servers as the test above |

## 3. Efficiency (thousand lines per second, per CPU core)

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Goose ÷ best tool | Rust ÷ best tool |
|---|---:|---:|---:|---:|---:|---:|---:|
| `tcp_to_tcp` | 4,601 (4,599–4,609) | 4,581 (4,547–4,701) | 210 (203–214) | | 402 (399–412) | 11.5 | 11.4 |
| `tcp_to_blackhole` | 26,882 (26,768–27,282) | 27,389 (27,359–27,612) | 239 (239–239) | | 1,369 (1,337–1,374) | 19.6 | 20.0 |
| `regex_mask` | 2,636 (2,465–2,765) | 2,574 (2,542–2,668) | 129 (128–132) | 160 (159–165) | 163 (159–167) | 16.2 | 15.8 |
| `set_field` | 1,742 (1,715–1,746) | 1,784 (1,748–1,866) | 143 (139–144) | | 313 (311–315) | 5.6 | 5.7 |
| `syslog_parsing` | 1,491 (1,489–1,519) | 1,522 (1,522–1,530) | 99 (98–102) | | 51 (50–51) | 15.1 | 15.4 |
| `real_world_1` | 1,484 (1,482–1,485) | 1,532 (1,528–1,551) | 96 (96–96) | | 45 (44–45) | 15.4 | 15.9 |
| `real_ssh_mask` | 3,832 (3,797–3,940) | 3,567 (3,560–3,681) | 139 (135–139) | 175 (168–176) | 186 (185–186) | 20.6 | 19.2 |
| `real_hdfs_mask` | 3,102 (3,086–3,193) | 2,907 (2,889–2,987) | 133 (132–137) | | 108 (107–110) | 23.4 | 21.9 |
| `real_ssh_syslog` | 2,316 (2,313–2,389) | 2,232 (2,217–2,289) | 103 (102–103) | | 132 (130–135) | 17.5 | 16.9 |
| `tcp_to_http` | 3,606 (3,596–3,731) | 3,247 (3,239–3,340) | 161 (161–162) | | 401 (391–402) | 9.0 | 8.1 |
| `file_to_tcp` | 7,637 (7,261–7,759) | 7,514 (7,141–7,547) | 134 (133–135) | | 293 (242–308) | not usable | not usable |
| `tcp_to_tcp_persistent` | 1,661 (1,645–1,676) | 1,646 (1,626–1,879) | 83 (80–83) | | 343 (338–345) | 4.8 | 4.8 |
| `disk_buffer` | 1,728 (1,531–1,764) | 1,745 (1,488–1,867) | 83 (80–83) | | 343 (343–354) | 5.0 | 5.1 |

**These ratios are not a confirmed result.** The tool configs haven't had an expert review, some have proven faults, and our servers do less work per event (no general event model, routing, TLS or metrics).

## 4. CPU cores used (of 6)

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Comment |
|---|---:|---:|---:|---:|---:|---|
| `tcp_to_tcp` | 1.55 (1.50–1.63) | 1.51 (1.38–1.67) | 3.23 (3.17–3.31) | | 2.90 (2.67–2.92) | |
| `tcp_to_blackhole` | 1.08 (1.08–1.09) | 1.07 (1.07–1.07) | 5.03 (5.02–5.06) | | 0.98 (0.97–1.01) | Vector uses most of the machine, which is also running the generator |
| `regex_mask` | 2.28 (2.11–2.84) | 2.66 (2.34–2.67) | 3.68 (3.53–3.73) | 3.47 (3.36–3.53) | 1.32 (1.32–1.32) | |
| `set_field` | 2.73 (2.70–2.75) | 2.64 (2.45–2.71) | 2.45 (2.45–2.55) | | 2.10 (2.09–2.13) | |
| `syslog_parsing` | 3.68 (3.43–3.75) | 3.68 (3.64–3.68) | 3.02 (2.91–3.03) | | 2.03 (2.03–2.05) | |
| `real_world_1` | 3.73 (3.73–3.75) | 3.67 (3.59–3.68) | 3.06 (3.04–3.07) | | 1.84 (1.84–1.86) | |
| `real_ssh_mask` | 2.45 (2.37–2.45) | 2.56 (2.47–2.57) | 3.92 (3.91–4.04) | 3.70 (3.65–3.79) | 1.37 (1.36–1.38) | |
| `real_hdfs_mask` | 2.53 (2.45–2.54) | 2.65 (2.57–2.65) | 3.97 (3.82–4.00) | | 1.19 (1.17–1.21) | |
| `real_ssh_syslog` | 2.85 (2.79–2.86) | 2.94 (2.87–2.97) | 3.04 (3.02–3.07) | | 1.30 (1.26–1.30) | |
| `tcp_to_http` | 0.76 (0.73–0.76) | 0.83 (0.80–0.83) | 4.30 (4.30–4.34) | | 2.88 (2.68–2.88) | |
| `file_to_tcp` | 0.47 (0.43–0.49) | 0.43 (0.41–0.50) | 1.31 (1.30–1.31) | | 0.09 (0.08–0.10) | Fluent Bit's 0.09 looks like a stall, not a CPU limit; cause unknown |
| `tcp_to_tcp_persistent` | 1.57 (1.43–1.79) | 1.66 (1.29–1.68) | 2.34 (2.32–2.43) | | 2.13 (2.12–2.14) | |
| `disk_buffer` | 1.34 (1.33–1.66) | 1.46 (1.29–1.63) | 2.35 (2.34–2.41) | | 2.15 (2.13–2.17) | |

## 5. Peak memory (MB; lowest median in bold)

| Test | Goose | Rust | Vector | Vector D | Fluent Bit | Comment |
|---|---:|---:|---:|---:|---:|---|
| `tcp_to_tcp` | 370 (310–475) | 315 (151–338) | **99** (98–101) | | 8,836 (8,244–10,923) | **We lose to Vector.** Fluent Bit's figure may be buffering, unverified |
| `tcp_to_blackhole` | **12** (10–13) | 13 (11–13) | 90 (89–91) | | 230 (171–257) | |
| `regex_mask` | 276 (128–365) | 132 (111–429) | **104** (102–105) | 105 (104–105) | 2,033 (1,967–2,068) | **We lose to Vector.** Our figures vary widely |
| `set_field` | **85** (78–88) | 88 (88–91) | 104 (104–105) | | 227 (204–244) | |
| `syslog_parsing` | 45 (40–49) | **39** (36–46) | 108 (107–109) | | 64 (61–65) | |
| `real_world_1` | 43 (38–52) | **41** (35–47) | 107 (105–107) | | 55 (50–61) | |
| `real_ssh_mask` | **23** (21–23) | 25 (24–26) | 103 (101–103) | 105 (105–108) | 1,084 (1,076–1,094) | |
| `real_hdfs_mask` | **24** (24–27) | 29 (24–32) | 104 (102–104) | | 690 (685–696) | |
| `real_ssh_syslog` | **40** (36–47) | 49 (39–101) | 107 (106–107) | | 922 (915–961) | Rust's 101 was one high run |
| `tcp_to_http` | 26 (26–26) | **25** (25–26) | 201 (197–202) | | 9,914 (7,961–10,349) | |
| `file_to_tcp` | 51 (35–60) | **48** (43–49) | 73 (71–75) | | 124 (110–128) | |
| `tcp_to_tcp_persistent` | 427 (396–445) | 417 (395–420) | 119 (119–121) | | **33** (32–34) | **We lose to both tools** |
| `disk_buffer` | 339 (298–381) | 349 (346–401) | 121 (115–122) | | **31** (30–32) | **We lose to both tools** |

We haven't found why our memory is high on these four tests. Kernel socket or file cache is possible but unverified.

## 6. Loss in performance tests (%)

Goose lost 0 on every test here except `tcp_to_blackhole`. Rust did too, apart from up to 0.01% on `tcp_to_http`.

| Test | Vector | Vector D | Fluent Bit | Comment |
|---|---:|---:|---:|---|
| `tcp_to_tcp` | 0.12 (0.07–0.12) | | 0.12 (0–0.15) | The tools' small losses may come from the fixed test window, unverified |
| `tcp_to_blackhole` | 100 | | 100 | Also 100 for ours. It sends nothing out, so this means nothing |
| `regex_mask` | 0.16 (0.15–0.18) | 0.11 (0.06–0.16) | 0.80 (0.68–0.87) | |
| `set_field` | 0.26 (0.21–0.33) | | 0.06 (0.04–0.08) | |
| `syslog_parsing` | 0.35 (0.32–0.38) | | 1.26 (1.06–1.28) | |
| `real_world_1` | 0.31 (0.28–0.34) | | 1.90 (1.46–1.93) | |
| `real_ssh_mask` | 0.31 (0.30–0.33) | 0.36 (0.33–0.38) | 0.95 (0.49–1.23) | |
| `real_hdfs_mask` | 0.32 (0.31–0.36) | | 2.04 (1.95–2.42) | |
| `real_ssh_syslog` | 0.78 (0.58–0.89) | | 1.60 (1.52–2.03) | |
| `tcp_to_http` | 0.06 (0–0.06) | | 0.04 (0–0.11) | |
| `file_to_tcp` | 94.09 (93.66–94.46) | | 99.12 (99.06–99.16) | Mostly backlog at the end of the window, not shown data loss |
| `tcp_to_tcp_persistent` | 0.63 (0.55–0.64) | | 0.05 (0.05–0.06) | |
| `disk_buffer` | 0.58 (0.39–0.60) | | 0.07 (0.05–0.07) | |

PipeBench's receiver only counts lines here. Content was checked separately, as listed in table 9.

## 7. Correctness (runs passed; loss % in rounds 1, 2, 3)

Goose and Rust passed 3 of 3 on all 11 tests with 0% loss. Totals: **Goose 33 of 33, Rust 33 of 33, Vector 23 of 33, Fluent Bit 21 of 33.**

| Test | What it checks | Vector | Fluent Bit | Comment |
|---|---|---|---|---|
| `file_rotate_create` | Rotation by creating a new file | 3 of 3 | 3 of 3 | |
| `file_rotate_truncate` | Rotation by truncation | 3 of 3 | 3 of 3 | |
| `file_truncate` | File truncated directly | **2 of 3**: 0, 0.70, 0 | **0 of 3**: 50.24, 50.08, 50.19 | Fluent Bit's failure is unexplained. Vector's single miss wasn't investigated |
| `file_rotate_restart` | Offline during a rotation | 3 of 3 | 3 of 3 | Lines sent vary by run (29,951 or 30,001), all delivered |
| `tcp_to_tcp_persistent` | Receiver down, then up | **0 of 3**: 5.40, 10.64, 2.68 | **0 of 3**: 90.36, 100, 93.55 | Fluent Bit: config fault. Vector: cause unknown |
| `tcp_to_tcp_persistent_restart` | Subject restarted too | **0 of 3**: 10.74, 6.99, 7.90 | **0 of 3**: 100, 100, 100 | Fluent Bit: mostly config. Vector: not investigated |
| `tcp_to_tcp_persistent_crash` | SIGKILL, then restart | 3 of 3 | 3 of 3 | Only 25,000 lines, against 450,000 in the restart test, so it's a smaller test |
| `disk_buffer_persistence` | Restart with a disk buffer | 3 of 3 | 3 of 3 | |
| `tcp_to_http_persistent` | HTTP receiver down, then up | **0 of 3**: 1.50, 1.58, 1.33 | **0 of 3**: 40.46, 41.17, 41.03 | **Lines sent differ widely**: about 18.0M for ours, 11.8M for Fluent Bit and 2.16M for Vector, so these percentages aren't on the same load. Cause unverified |
| `sighup` | Config reload | 3 of 3 | 3 of 3 | |
| `wrapped_json` | JSON inside a string field | 3 of 3 | 3 of 3 | |

Passing doesn't show that our servers are more correct, because the tools ran with configs that are partly at fault. They also ran after the three rounds, not alongside our servers' runs.

## 8. Reruns to find causes (not counted, 1–2 samples each)

The evidence is in [results/i5-8400t/investigation](results/i5-8400t/investigation).

| Build and test | Change | Loss % | Comment |
|---|---|---:|---|
| Fluent Bit, `tcp_to_tcp_persistent` | `Retry_Limit false` | 0, 0 | Caused by the config |
| Fluent Bit, `tcp_to_tcp_persistent_restart` | Same | 0.06, 0 | Mostly the config; one run would still fail |
| Fluent Bit, `tcp_to_http_persistent` | Storage limit 2G → 8G | 0.41, 0.46 | Mostly the config; would still fail |
| Fluent Bit, `file_truncate` | Debug logging; polling | 50.24, 50.08 | Not explained |
| Vector, `tcp_to_tcp_persistent` | Second sink to count lines | 13.35, 10.27 | Both sinks got equal counts, so the lines never reached them. Vector or the generator could be at fault |

## 9. Batch tool and other checks

Batch timing was pinned to one core. Vector and Fluent Bit weren't in it. Each cell shows wall seconds, then peak memory. Raw rows are in `batch-*.csv` in [results/i5-8400t](results/i5-8400t).

| Data set (rounds) | Goose pre-change | Goose | Rust | Comment |
|---|---:|---:|---:|---|
| HDFS (10) | 6.52 (6.40–6.67), 36.0 MB | 7.31 (7.23–7.78), 26.7 MB | 6.84 (6.73–7.38), 26.4 MB | Goose 0.94× Rust's speed, mark met. Hex scan 12.9% over pre-change against a 10% limit, **missed** |
| BGL (10) | | 3.44 (3.30–3.59), 41.8 MB | 3.06 (2.97–3.30), 41.5 MB | Goose 0.897× Rust against a 0.9× minimum, **narrowly missed** |
| SSH (5) | | 0.62 (0.60–0.65), 24.2 MB | 0.57 (0.56–0.66), 23.9 MB | Rust about 10% faster |
| Escape-heavy (5) | | 0.45 (0.43–0.47), 34.0 MB | 0.49 (0.49–0.63), 33.9 MB | Goose about 10% faster, memory 1.00× Rust, mark met |

Ratios are medians of paired rounds, so they can differ slightly from dividing the medians shown.

| Check | Goose | Rust | Python | Vector, Fluent Bit |
|---|---|---|---|---|
| Behavior tests | All passed | All passed | | Not run |
| Output compared with Vector | 2,286 records, 0 differences | Same | | Vector is the reference |
| Deliberately broken versions caught | 14 of 15 | Not run | | Not run |
| Batch tests | 31 of 31 | 31 of 31 | 31 of 31 | Not run |
| Batch adversarial data | 114 of 114, 150 of 150 | Same | Same | Not run |
| Batch fuzz against Python | 20,000 cases, 0 failures | Same | Reference | Not run |
| Leftover dashed IPs, 655,147 SSH lines | 0 | 0, output byte-identical to Goose | | Not run |

The one broken version that wasn't caught had its SIGPIPE guard removed; the cause wasn't verified during the evaluation.
