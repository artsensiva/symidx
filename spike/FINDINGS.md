# Goose spike findings

Goose v2026.3 (runtime `4d3da949e563`), Linux x64, 2026-11-01. Every program here is run from `spike/`
with `../toolchain/goose-v2026.3-linux-x64/goose`.

**Verdict:** the CLAUDE.md design is feasible as written. One runtime bug in `from_bytes` needs a
workaround in the loader (below), which costs an extra copy of the two small arrays.

## What worked

| Item | Program | Result |
|---|---|---|
| Hello world, in-process | `goose hello.goose` | works (TinyCC) |
| Hello world, `goose build` | `goose build hello.goose --cc clang` | works with clang 21, gcc 15 and the default `cc` |
| Grouped layout, `to_bytes` | `ser.goose` | 68-byte image for 2 files / 2 groups / 3 occurrences |
| `from_bytes` reload into globals | `ser_load.goose ok` | round-trips; dump matches the input |
| In-memory index `(NameGroup&<u32 in groups>)[>..]` over loaded groups | `ser_load.goose ok` | works, indexes in any order |
| `thread_fn` workers + queues | `thread.goose` (`goose build` only) | one flat `Parsed { file, recs: Rec[] }` per file crosses the queue |
| Directory walk via C sidecar | `walk.c` + `thread.build` | `opendir`/`readdir`/`d_type`, `lstat` fallback; skips symlinks |
| Parser per SPEC | `thread.goose` | symbol and `def` counts equal `bench/ref.py` on S, M and raw `cpython/` (which has 2 symlinked `.py` files) |

Walk + parse in 6 workers (no index built): S 21 ms, M 41 ms, L 5.2 s at 33 MB peak RSS.

### Tampering (`ser_load.goose <mode>`)

| Mode | Change | `from_bytes` |
|---|---|---|
| `trunc` | drop the last byte | rejected |
| `namelen` | group name length → 100 | rejected |
| `occcount` | occurrence count → 7 | rejected |
| `fileidx` | occurrence file index = `files.len` | rejected |
| `span` | file `hi` = `paths.len + 1` | rejected |
| `lohi` | file `lo` > `hi` | **accepted**, then a safe abort on the slice |
| `kind` | `kind` → 7 | **accepted** |
| `negline` | line → -3 | **accepted** |

The last three are as expected: `from_bytes` checks structure and each index/bound on its own, not
relations between fields or value ranges. The loader's pass that builds `group_at` must check
`lo <= hi`, `kind <= 1`, `line >= 1`, non-empty names and at least one occurrence (SPEC "Image validation").

## What didn't work, and the workarounds

1. **Bug: `from_bytes` rejects valid index types into an array grown with `append`.**
   Repro: `bug_from_bytes_append.goose` prints `false`; `bug_from_bytes_append_control.goose`, identical
   except the global is filled with `push`, prints `true`. The image bytes are identical and the checked
   cast `as (u32 in bytes)` accepts the same index. Any executed `append` to the target triggers it,
   before or after pushes; an `append` in dead code does not. Same at `-O0`, `-O2`, `--debug`, in-process and
   built. Applies to `u32 in x` and `u32 upto x`. Not reported upstream (no matching issue as of 2026-11-01).
   **Workaround:** grow the pinned globals (`paths`, `files`) with `push` loops, both in `build` and on load.
2. **Pinned globals cannot be assigned whole**, as documented (§3.11): `files, ok = from_bytes(...)` is a
   compile error. So `paths` and `files` load into a local and are pushed into the global (two copies).
   `groups` is not pinned by an index type and loads directly: `groups, ok = from_bytes<NameGroup[>..]>(s)`.
3. **A pinned global cannot be cleared**, so one process can load one image. Fine for the CLI.
4. **Grow-shrink arrays need fixed-size elements**, so a stack of path strings (`u8[][>..<]`) is an error.
   The walk is breadth-first over one byte buffer plus a `Span[>..]` cursor instead.
5. **Resizables never copy implicitly** into a record field or a queue message: `copy(x)` is required even
   where a memcpy happens anyway (`qput(Job { path: copy(full) })`). In the real code, build a group's
   occurrences in a function returning `Occ[>..]`, which constructs at the destination.
6. **Queue types cannot hold index types**, so workers send plain `u32` file ids; the main thread converts
   with a checked `as (u32 in files)`.
7. **`os.goose` has no `lstat`** and its `list_dir`/`is_dir` follow symlinks, hence the C sidecar. An
   `extern fn` cannot hold an opaque `DIR*`, so `opendir`/`readdir` cannot be bound directly; the C does the
   whole listing and appends `<type><name>\n` lines to a builder via `goose.h`'s `gs_bld_append`.

## Doc mismatches and surprises

- **`goose --version` is not an option** ("unknown option"); the command is `goose version`. (My earlier
  instruction to run `goose --version` was wrong.)
- **`varint` is signed (zigzag LEB128)**: line 3 is stored as `06`, line 300 as `d8 04`. The docs call it
  "a LEB128 integer"; the sign isn't mentioned in the tutorial. Consequence: an image can carry a negative
  line that `from_bytes` accepts.
- **Default C compiler:** `goose toolchain` picks `~/.local/bin/cc`, a local wrapper around `zig cc`
  (clang 18), ahead of `/usr/bin/clang` 21. Its binaries are 3.4× larger (238 KB vs 70 KB for hello).
  For reproducible numbers, build with `--cc clang` (system clang 21).
- The tutorial says threads need `goose -o …`; `goose build` (as CLAUDE.md says) also works.
- A C sidecar must `#include <stdbool.h>` itself; `goose.h` doesn't provide `bool`.

## Implications for days 3–5

- Load path: read the file; `from_bytes` paths and files into locals and push them into the globals;
  `from_bytes` groups directly; one pass over `groups` checks the field relations and builds `group_at`.
  All of it counts toward load time.
- Build path: grow `paths`/`files` with `push` only; workers send `Parsed` per file; main sorts and groups.

## Load profile (2026-11-01)

`SYMIDX_PROFILE=1 goose/symidx load <img>` prints each phase on stderr. Warm page cache, one run:

| Phase | M (3.0 MB image) | L (39.3 MB image) |
|---|---|---|
| `read_file` | 2.16 ms, 1.39 GB/s | 27.2 ms, 1.45 GB/s |
| `from_bytes` paths | 0.13 ms, 1.7 GB/s | 4.7 ms, 1.7 GB/s |
| push-copy paths (append-bug workaround) | 0.11 ms, 2.1 GB/s | 4.3 ms, 1.8 GB/s |
| `from_bytes` files | 0.03 ms | 1.0 ms |
| push-copy + `lo <= hi` check, files | 0.03 ms | 0.7 ms |
| `from_bytes` groups | **5.81 ms, 0.47 GB/s** | **57.4 ms, 0.53 GB/s** |
| validate + build `group_at` | 2.00 ms, 1.37 GB/s | 33.5 ms, 0.90 GB/s |
| **total** | **10.2 ms, ~0.3 GB/s** | **128 ms, ~0.3 GB/s** |

The append-bug workaround costs ~2% of load (0.14 ms on M, 5 ms on L).

**Where `from_bytes` groups goes** (`fault_probe.goose`, `load_layouts.goose`): about half is first-touch
page faults on fresh memory, the rest is verify + copy.

- Same call in one process: 1st (fresh memory) 6.1 ms, 2nd (same memory) 3.1 ms on M; 58 / 28 ms on L.
- Page faults cost ~4 µs each here. `perf` is unavailable (`perf_event_paranoid` = 4).
- Not CPU clock ramp-up: spinning 100 ms before the call changes nothing.
- The verifier's scratch is only a bitmap of n/8 bytes (`docs/design/serialization.md`).

**Pre-faulting** with `madvise(MADV_POPULATE_WRITE)` (`prefault.c`), aimed at an empty array's
`bytes_of` view (its stack top). Total read + groups, incl. the madvise, median of 5:

| | none | populate | populate + `MADV_HUGEPAGE` |
|---|---|---|---|
| M | 8.15 ms | 7.03 ms | 5.97 ms (-27%) |
| L | 92.7 ms | 80.7 ms | 74.0 ms (-20%, noisy) |

Not applied to `goose/`: it relies on where the runtime puts an array's elements (undocumented), and
it is Linux-only tuning the Rust versions could equally use.

**Layout alternatives** (`load_layouts.goose`, warm, best of 15, `from_bytes` only):

| Layout | M bytes | M time | L bytes | L time |
|---|---|---|---|---|
| A current: nested `Occ[varint]`, varint line | 2.75 MB | 1.71 ms | 30.2 MB | 18.4 ms |
| B nested fixed `Occ` (9 B) | 3.03 MB | 1.03 ms | 39.0 MB | 10.1 ms |
| C group spans into one fixed `Occ[>..]` (9 B) | 3.60 MB | 0.95 ms | 39.6 MB | 9.6 ms |
| D as C, kind packed into line (8 B) | 3.46 MB | 0.94 ms | 35.5 MB | 8.1 ms |
| memcpy of A | 2.75 MB | 0.11 ms | 30.2 MB | 3.4 ms |

Layout D would also make the occurrence checks nearly free: an unsigned line, and a kind that is
`lk & 1` can't be invalid. But it grows the groups frame by ~26% (+0.7 MB on M), which works against
the image-size target, so it is a design decision, not a fix.

**Conclusion.** "Load at I/O speed" isn't reachable with `from_bytes` as it is: it always copies into
fresh memory, so a load pays two first-touch passes (read buffer + destination) plus a verify walk.
rkyv validates in place over the read buffer and skips the second pass.
