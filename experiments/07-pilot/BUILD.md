# How each program in the pilot was built

Everything here runs on one Linux machine: Intel Core i5-8400T (6 cores), kernel 7.0.0, Ubuntu packages. The tools and compilers aren't in the repository: they're under the gitignored `toolchain/`, so this file records what to fetch and how to put it there.

| Program | Version | Source | How it's built or installed | Runs as |
|---|---|---|---|---|
| **logXform of Goose** | Goose v2026.3 release, unpatched; clang 21.1.8 | [goose/sanitize.goose](goose/sanitize.goose) and a 58-line C I/O file, [goose/io.c](goose/io.c) | `goose/fetch-toolchain.sh` at the repository root (sha256-pinned), then [goose/build.sh](goose/build.sh): `goose build sanitize.goose --cc clang` | Single-threaded binary, 124,872 bytes |
| **Rust** | rustc 1.99.1, `memchr` 2.8.3 | [rust/src/main.rs](rust/src/main.rs) | `cargo build --release`, with fat LTO, `codegen-units = 1`, `panic = "abort"` ([Cargo.toml](rust/Cargo.toml)) | Single-threaded binary, 374,816 bytes |
| **Python** | CPython 3.14.4, standard library only | [sanitize.py](sanitize.py) | None | `python3 -I sanitize.py` |
| **Fluent Bit** | 5.1.5 | Pipeline: [tools/fluentbit/pipeline.conf](tools/fluentbit/pipeline.conf), Lua: `tools/fluentbit/*.lua` | Official Ubuntu package `fluent-bit_5.1.5_amd64.deb`, sha256 `e1a9501b6588f28faa16531a19d11e45590a96e2f298a1cfce931ca72aee9615`. Unpacked into `toolchain/vs/fluentbit/x` without root, with `libpq`, which it links to, in `toolchain/vs/fluentbit/lib` | `tail` input, `lua` filter, `file` output, through the wrapper below. Threads: `SANITIZE_THREADS`, or the cores available |
| **Vector** | 0.61.0 | Pipeline: [tools/vector/pipeline.yaml.in](tools/vector/pipeline.yaml.in), VRL: `tools/vector/*.vrl` | Official `vector-0.61.0-x86_64-unknown-linux-gnu.tar.gz`, sha256 `84a27c3ad6b772fdb05bb76ea01a31498bfc8f5e71f32cc78a0d96841f1aa827`. Unpacked into `toolchain/vs/vector/x` | `stdin` source, `remap` with `reroute_dropped`, `filter`, `file` sink, through the wrapper below. Threads as for Fluent Bit |

## Sanitizer builds

For the safety section, and not part of the registered results. `goose.h` comes from the `include` folder of a normal `goose build` under `~/.goose/build/prog`.

- **logXform of Goose:** `goose --standalone -o sanitize.c sanitize.goose`, which puts the runtime in the C file, then `clang -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize=alignment -fno-omit-frame-pointer -I. sanitize.c io.c -lm -lpthread`. Without `--standalone`, the generated C needs a separately built runtime.
- **Rust:** `RUSTC_BOOTSTRAP=1 RUSTFLAGS="-Zsanitizer=address -C linker=clang" cargo build --release --target x86_64-unknown-linux-gnu`.

## The wrapper around the tools

Neither tool has the pilot's command line, atomic `--out`, a rejects file with these rules, a summary line or these exit codes. [tools/sanitize_tool.py](tools/sanitize_tool.py) (144 lines) provides them around one tool process per input, and the spec counts that cost:
- It **is** part of what the tools were measured with: it starts Python, scans input and output once each to count lines, and then waits. That looks small beside the tools' own time, but it hasn't been measured separately.
- **The failure checks they pass, they pass because of the wrapper.** Atomic output and exit codes are the wrapper's work, not the tool's.

## Configuration choices

- **Fluent Bit:** Lua alone is the configuration to beat, as native parsing was slower ([SPEC](SPEC.md), A1, and [experiment 4](../04-vs-tools/REPORT.md)). `Mem_Buf_Limit 64M`, so memory isn't left unbounded. `Refresh_Interval 1` and `Exit_On_Eof` give it a floor of about one second of wall time, which only matters on very short inputs. A C or Wasm filter is untested.
- **Vector:** one VRL program per format, written for correctness, then reviewed against the documentation.
- **Measured with:** [measure_pilot.sh](measure_pilot.sh) `OUT_DIR BIN_DIR WORK_DIR`, using `experiments/03-goose-patches/measure.py`. Corpus: `experiments/02-logxform/corpus/fetch.sh`. Adversarial data: [gen_adversarial.py](gen_adversarial.py).
