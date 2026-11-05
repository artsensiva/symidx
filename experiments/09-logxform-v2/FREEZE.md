# Freeze

Second freeze, 2026-11-05 at 04:47, after the [fairness review](FAIRNESS.md) and before any PipeBench round. The first, at `ad8406d`, was stopped with no PipeBench result, and its batch timings weren't read before this freeze. The batch tool's code is the same in both, so those timings stand. Any later change to these means a new version and new runs.

Commit: `e763a39773c55a1dcb423e3643d7ee56f9f8f33c`

PipeBench commit: `cdb484f6a187384f3589e0bbcda8c1d6d7d0e528`, plus [install.py](pipebench/install.py) and [real_cases.py](pipebench/real_cases.py).

| What | sha256 |
|---|---|
| `goose/logxform.goose` | `157d0afa62bb3d0e…` |
| `goose/net.c` | `91c07bc13231f3cd…` |
| `rust/src/main.rs` | `badfd04a4555e810…` |
| `batch/sanitize.py` | `d0a3aab21a7341aa…` |
| `batch/goose/sanitize.goose` | `907c22e01820311d…` |
| `batch/goose/io.c` | `82f9894398019218…` |
| `batch/rust/src/main.rs` | `53befa91883a5036…` |
| binary `goose/logxform`, 211536 bytes | `a2ba7900d82e6ac6…` |
| binary `rust/target/release/logxform`, 1877000 bytes | `9bd496709ff9683a…` |
| binary `bin/sanitize-goose`, 137432 bytes | `a27bb387e745efee…` |
| binary `bin/sanitize-rust`, 391088 bytes | `e8e41e6ed63b0c9b…` |
| image `logxform-goose:dev`, built here | `808453cb12963934…` |
| image `logxform-rust:dev`, built here | `2838e59d0f0de043…` |

Goose v2026.3, unpatched, built with clang. Rust 1.99.1. The images are built from source by [docker/](docker/), so image hashes will differ on another machine, and the source hashes are what to check.
