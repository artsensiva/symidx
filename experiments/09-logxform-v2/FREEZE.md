# Freeze

Code, tests and marks frozen on 2026-11-05 at 04:18, before any counted run. Any later change to these means a new version and new runs.

Commit: `ad8406d5f3c5f78b08ab3ec1cc08ae4e9a4de332`

PipeBench commit: `cdb484f6a187384f3589e0bbcda8c1d6d7d0e528`, plus [install.py](pipebench/install.py) and [real_cases.py](pipebench/real_cases.py).

| What | sha256 |
|---|---|
| `goose/logxform.goose` | `fff59a1f7300a34f…` |
| `goose/net.c` | `91c07bc13231f3cd…` |
| `rust/src/main.rs` | `3452016e370d8a8d…` |
| `batch/sanitize.py` | `d0a3aab21a7341aa…` |
| `batch/goose/sanitize.goose` | `907c22e01820311d…` |
| `batch/goose/io.c` | `82f9894398019218…` |
| `batch/rust/src/main.rs` | `53befa91883a5036…` |
| binary `goose/logxform`, 211536 bytes | `688cb85d9cb7eab2…` |
| binary `rust/target/release/logxform`, 1874176 bytes | `70bccd20d52b43e3…` |
| binary `bin/sanitize-goose`, 137432 bytes | `a27bb387e745efee…` |
| binary `bin/sanitize-rust`, 391088 bytes | `e8e41e6ed63b0c9b…` |
| image `logxform-goose:dev`, built here | `e665d08c17b0db53…` |
| image `logxform-rust:dev`, built here | `4189368a05e09530…` |

Goose v2026.3, unpatched, built with clang. Rust 1.99.1. The images are built from source by [docker/](docker/), so image hashes will differ on another machine, and the source hashes are what to check.
