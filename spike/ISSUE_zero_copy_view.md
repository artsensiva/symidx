<!-- Filed as https://github.com/aardappel/goose/issues/221 on 2026-11-03. Kept here as filed. -->
# Feature request: a verified, zero-copy view over foreign bytes (e.g. an mmap)

Thanks for Goose. `from_bytes` is the nicest serialization story I've used: one call, a verifier
generated from the type, and a corrupt file is a `false` rather than a wild reference. This request is
about the one place where it costs a lot, serving memory, with measurements from a small comparison project.

## Context

[symidx](https://github.com/artsensiva/symidx) is a code-symbol index (name → kind, file, line) built three
ways with byte-identical output: Goose, idiomatic Rust (serde + bincode), and "expert" Rust (rkyv 0.8 over
an mmap, bytecheck plus an explicit validation pass). The Goose image is the most compact of the three,
thanks to inline `u8[varint]` names and `varint` fields. While building it we also hit #177
(`from_bytes` and `append`).

The full write-up is in `bench/REPORT.md` there. The main problem is **serving memory**: a long-running
tool (a language server, an index) keeps the loaded data resident for its whole life, and with `from_bytes`
that costs about twice the image.

| Peak RSS while serving one selective query | Goose (`read_file` + `from_bytes`) | Rust (rkyv over mmap) |
|---|---|---|
| 3 MB image, Linux | 11.4 MB | 5.6 MB |
| 39 MB image, Linux | 116 MB | 44 MB |
| 3 MB image, macOS (CI VM) | 10.6 MB | 3.5 MB |

So serving memory is 2.0–3.1× higher, although Goose's image is 1.1–1.2× smaller. Load time follows the
same cause. With a warm page cache:

| Load, warm cache | Goose | Rust (rkyv over mmap) |
|---|---|---|
| 3 MB image | 12.2 ms | 1.3 ms |
| 39 MB image | 134 ms | 5.3 ms |

That's 10–25× slower. For completeness, with a cold cache (3 MB image, CI runners, 3 runs) reading from
storage dominates both: 18.4 vs 9.3 ms on Linux (2×) and 122 vs 120 ms on a macOS VM (parity). Cold load
isn't the problem; resident memory and warm restarts are.

## Where the cost comes from

Profiling the 3 MB case with a warm cache (`SYMIDX_PROFILE=1` in `goose/symidx.goose`):

- `from_bytes` copies the payload into the result, so the read buffer and the copy are resident at once.
  Serving costs at least about 2× the image.
- About half of the `from_bytes` time is first-touch page faults on the destination. The same call into
  already-faulted memory is 2× faster. The verify walk itself runs at about 1 GB/s, which is fine.
- `read_file` alone on the 39 MB image (27 ms) is 5× rkyv's whole load. Nothing after the read can win that back.

The verifier isn't the problem. The copy, and the lack of any way to point at bytes the program
didn't allocate, are.

## Proposal

A sibling of `from_bytes` that verifies and then returns a view instead of a copy:

```goose
fn view_bytes<T[>..]>(bytes: const u8[:]) -> const T[:], bool   // verified in place; [] and false if not
```

- **Semantics:** the same verifier as `from_bytes`, and the same framing. The result is a read-only slice
  rooted at `bytes`' root, so the existing root rules keep it from outliving the bytes. Nothing is copied,
  and it is never writable, like a `bytes_of` view today.
- **Alignment:** Goose layouts are packed, so a view needs no alignment fix-ups. That's simpler than in rkyv,
  where alignment is a recurring source of errors.
- **Foreign memory:** a view only helps if the bytes needn't be copied in first. Something like
  `os::map_file(path) -> const u8[:], bool`, owned by the variable it's bound to and unmapped at scope exit,
  would make an mmap an ordinary root. `read_file` into a buffer would also work, and still saves one of
  the two copies.
- **Index types:** this is the part that needs real design, and I may well be missing a simpler answer.
  `u32 in files` names a global array, but a view's indices would point into another view. Options:
  - allow `in` to name a global `const T[:]` that was itself produced by `view_bytes`, and verify the
    dependent view after it (the order is the program's, as it is for `from_bytes` today);
  - or allow index types relative to a view parameter, checked at `view_bytes` time.

  Without either, views would still serve images whose links are self-relative, and that's already
  most of the serialization chapter's examples.

## Possible extension: segmented verification

For very large images, verification could optionally be deferred per segment. Measured on the Rust side,
validating 1024-entry chunks only when a query first touches them cut peak RSS for a selective query on
the 39 MB image from 43 MB to 12 MB. The price is that "loaded" no longer means "fully verified". This is
optional, and separable from the main proposal.

## Why it matters

The pitch in the tutorial ("your data is already a file format") is exactly what a fast-starting tool
wants: a language server, an index, a cache. With a verified view, Goose would keep its compactness and
safety and match zero-copy loaders on serving memory and warm start-up time. Today it loses the comparison
on those two metrics, so we went with Rust for the larger project. I'd be glad to test a prototype against this
benchmark.
