# Experiment 6: why Goose logxform trails tuned Rust at six threads

Step 4 of the product plan. Written 2026-11-04 before these measurements. This stage only measures: no design is chosen until the numbers are in.
Current state: at `-t 6` on M, Goose logxform is about 0.57× tuned Rust's throughput with 1.3× the memory
([report](../../docs/GOOSE_LOGXFORM_REPORT.md)). The improvement plan's gap 3 target is ≥ 0.9× and RSS ≤ 1.1×, with a stop below 0.75× after a prototype.

## Questions

1. **Scaling.** Where does each program's throughput stop growing, from 1 to 6 threads?
2. **The main thread.** It reads, copies each batch out, receives and copies each result, and writes. Is it saturated, so that it caps everything?
3. **Workers.** How much of their time is processing, waiting or queue operations?
4. **Cost of one queue message.** Hypothesis, not yet measured: `gs_qput` calls `malloc` per message, a batch is about 9 MB, and first-touch page faults (about 4 µs each here) may
   cost several times the memcpy. So this is measured directly, and page faults are counted against tuned Rust's.

## Method

- `timed/`: experiment 2's Goose logxform plus stage timers (`clock_ns`, per batch, so their cost is negligible), built with `step2-fixes`. Output must still match the reference on S.
- Scaling: Goose logxform with fixes and tuned Rust at `-t 1, 2, 3, 4, 6`, M, `measure.py`, 3 rounds, unpinned.
- Minor page faults and context switches from GNU time, both programs at `-t 6`.
- `qbench.goose`: one thread sends messages of a given size to another and back, so a message's cost is measured alone.

## Decision rule

Set before seeing the numbers. Each candidate fix gets a pre-registered target before it's built:
- If the main thread is busy at least 80% of the time at `-t 6`, it's the bottleneck, and the first design reduces its work.
- If page faults are a clear majority of a queue message's cost, the first design reuses message storage (no language change).
- If workers are mostly waiting while main isn't saturated, look at the queue's locking.

## Results (added after measuring)

**Scaling, 3 rounds, random order, load average about 1–3** (`run.sh`, raw in `data/`). This is the run the method above asked for.

| Threads | Goose logxform with fixes: throughput, RSS, CPU | Tuned Rust: throughput, RSS, CPU | Goose ÷ Rust |
|---|---|---|---|
| 1 | 259 MB/s, 36 MiB, 6.4 s | 236 MB/s, 38 MiB, 7.0 s | 1.10× |
| 2 | 433 MB/s, 168 MiB, 9.0 s | 482 MB/s, 132 MiB, 7.3 s | 0.90× |
| 3 | 569 MB/s, 249 MiB, 10.3 s | 703 MB/s, 189 MiB, 7.4 s | 0.81× |
| 4 | 665 MB/s, 328 MiB, 11.0 s | 903 MB/s, 252 MiB, 7.7 s | 0.74× |
| 6 | 673 MB/s, 514 MiB, 11.5 s | 1,082 MB/s, 366 MiB, 7.9 s | **0.62×** |

**Stages.** The tables below were taken first, from single or paired runs; `data/stages.txt` and `data/qbench.txt` are a repeat that agrees with them to within about 10%, apart from one 9 MB send figure (3.4 ms there, 2.2 ms here).
Goose logxform with fixes, M, unpinned, load average 1–2, 2 runs per thread count unless noted. Sums over workers are CPU-like, so they can exceed wall time.

| Threads | Wall | Main: read + scan | Main: send batches | Main: receive | Main: out-of-order buffer | Workers: `process`, sum | Workers: waiting for a batch, sum | Workers: send result, sum |
|---|---|---|---|---|---|---|---|---|
| 2 | 3.71–3.76 s | 0.48–0.52 s | 0.51–0.56 s | 2.64–2.69 s | 0.01 s | 6.4 s | 0.5 s | 0.5 s |
| 3 | 2.74–2.79 s | 0.62–0.70 s | 0.83–0.89 s | 1.14–1.23 s | 0.03 s | 6.8 s | 0.7 s | 0.8 s |
| 4 | 2.34–2.40 s | 0.77–0.81 s | 0.94 s | 0.54–0.56 s | 0.06 s | 7.4–7.5 s | 0.9 s | 1.1 s |
| 5 | 2.48–2.64 s | 0.88–0.95 s | 0.92–0.95 s | 0.49–0.53 s | 0.13 s | 8.6–9.2 s | 2.3–2.5 s | 1.4 s |
| 6 | 2.52–2.84 s | 0.96–1.03 s | 0.87–0.97 s | 0.48–0.56 s | 0.15–0.21 s | 9.0–10.9 s | 4.4–4.6 s | 1.5–1.8 s |

| CPU, one run each | Goose logxform with fixes: wall, user, sys, minor faults | Tuned Rust: wall, user, sys, minor faults |
|---|---|---|
| `-t 1` | 6.46 s, 6.12, 0.25, 8,708 | 7.02 s, 6.76, 0.24, 9,377 |
| `-t 2` | 3.73 s, 8.42, 0.40, 68,390 | 3.38 s, 6.89, 0.33, 33,563 |
| `-t 4` | 2.37 s, 10.28, 0.82, 164,941 | 1.79 s, 7.04, 0.44, 63,215 |
| `-t 6` | 2.79 s, 10.37, 1.05, 255,167 | 1.80 s, 7.44, 0.54, 93,802 |

| One queue message, alone (`qbench`) | Round trip | Send | Receive, including the echo's work |
|---|---|---|---|
| 64 KiB | 33 µs | 7 µs | 26 µs |
| 1 MiB | 441 µs | 132 µs | 308 µs |
| 9 MB (a typical batch) | 6.7 ms | 2.2 ms | 4.5 ms |
| 40 MB | 75 ms | 30 ms | 45 ms |

A warm 9 MB `memcpy` here takes about 0.83 ms (measured from Python, so approximate).

**Answers.**
1. **Scaling.** Goose logxform stops improving at 4 threads: 665 to 673 MB/s from 4 to 6, while workers' waiting grows fivefold. Tuned Rust keeps improving, 903 to 1,082 MB/s. (A single run above suggested Rust was flat too. The 3-round run shows that was noise.)
2. **The main thread is the bottleneck, by the rule above.** At 6 threads, reading, sending, and the out-of-order buffer account for about 80% of its time, and receiving is the rest. Since a receive at that point rarely waits, it's mostly copying, so main is close to fully busy from 4 threads on.
3. **Workers** idle because main can't feed them. Waiting is about a third of their time at 6 threads.
4. **A message's cost.** Not mainly page faults, so that rule doesn't fire. A 9 MB send takes about 2.6× a warm `memcpy`, and page faults explain part of it. Goose takes 2.7× Rust's faults at 6 threads, but its extra system time is about 0.5 s, against about 2.9 s of extra user time.

**A finding that wasn't predicted.** Goose's total CPU grows 80% from 1 to 6 threads, Rust's 13%. All three directions of copying are part of it: each byte crosses a queue with up to three copies, in both directions, about 10 GB in all for this 1.66 GB input. Also, the sum of workers' `process` time grows from about 5.9 s at one thread to 9–11 s at six, even though `process` itself doesn't copy across queues. Competition for cache and memory bandwidth from those copies is the likely reason, not confirmed.

## Proposed next step (not built; awaiting outside review)

**Workers read their own input.** The main thread splits each file into byte ranges at line boundaries and sends each worker an offset and a length, not the bytes. Each worker reads its range itself. That removes reading, scanning and sending from
the main thread (about 70% of its time at 6 threads) and every input copy. No language or compiler change is needed.

- **Estimate, not a measurement:** 1.6–2.0 s at 6 threads, about 0.75–0.95× tuned Rust as it stands. Main would be left with about 0.6 s of receiving and buffering, and workers' `process` sum (9–11 s now) should fall, if its growth comes from copy traffic, as suspected.
- **Costs.** It works on files, not pipes or stdin, which would keep today's path. It leaves experiment 2's spec, where main reads and a batch is 65,536 lines, so it needs its own benchmark, with output still byte-identical.
- **Fairness.** Rust gets the same design, and results are given against both Rust versions.
- **Target (gap 3's):** ≥ 0.9× tuned Rust at `-t 6`, RSS ≤ 1.1×. **Stop:** below 0.75× after this prototype, which would point to the alternative below.
- **Alternative: transferring ownership of a message's storage** in the runtime, so no bytes are copied in either direction. It would also help output, which the proposal doesn't touch, but it changes the language's model, so it needs upstream's agreement.
