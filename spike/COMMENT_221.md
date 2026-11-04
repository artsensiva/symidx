<!-- SUPERSEDED, NEVER POSTED. Upstream's first analysis showed the design below is unsound: a const slice doesn't stop writes through its
     owner, so the bytes must be frozen. The reply actually posted: https://github.com/aardappel/goose/issues/221#issuecomment-6627423981
     Original note: draft comment for https://github.com/aardappel/goose/issues/221.
     Numbers: bench/REPORT.md and experiments/02-logxform/REPORT.md at symidx v1.2.1. -->

Following up on this request with an offer, rather than more argument.

**Would you accept a contribution here?** I'd like to prototype a verified, zero-copy view and measure it
against the symidx benchmark from the original report. To make it concrete, something like:

```goose
fn view_bytes<T[>..]>(bytes: u8[:]) -> const T[:], bool   // verified in place; a read-only view rooted at `bytes`
```

As I read `docs/design/serialization.md` §6, `from_bytes` already verifies in one or two linear passes,
and then copies. So the prototype would run the existing verifier and return a const view instead of
copying. The parts I'd need your guidance on before writing any code:

1. Is a view rooted at the input slice (the way `bytes_of`'s result is rooted at its array) the right
   ownership model? Or should it be a new kind of root, for memory Goose didn't allocate, such as an mmap
   held by a C sidecar?
2. Variable-size elements can't be indexed. Is a view you can iterate, plus a separate index array (as
   symidx builds its `group_at` today), acceptable for a first version?
3. The verifier's bitmap scratch (one bit per payload byte): would it be fine on a statement-scoped stack,
   as it is today?
4. Would you prefer this as a design note first, a branch, or a PR against `master`?

**How I'd measure it.** symidx's harness (https://github.com/artsensiva/symidx, `bench/run.sh`) compares
Goose with rkyv over mmap, with byte-identical output checked by sha256 on Linux and macOS. Today, on the
M corpus, Goose's selective serving RSS is 11.4 MB against 5.6 MB (2.0×), and warm load is 12.2 ms against
1.3 ms. On L it's 116 MB against 44 MB, and 134 ms against 5.3 ms. Before starting, I'd fix a target and
a stop rule:
- target: serving RSS within 1.2× of rkyv's, and warm load within 2×;
- stop: if RSS stays above 1.5× on L, I'd report that and stop.

You'd get the numbers whichever way it goes.

**Smaller things from a second experiment**, in case they're useful. This is a log-processing benchmark,
https://github.com/artsensiva/symidx/tree/main/experiments/02-logxform, where Goose ran at 0.88× of an
arena-based Rust version single-threaded in the main run (0.93–1.03× across neutral rebuilds, 0.96× with
the best build flags on each side). A phase-timed profile attributes most of the gap to three
library-level things, each measured in that report's "Profile" section:
- `json::plain`'s early-exit byte loop doesn't vectorize. A compare-free form that does gained about 11% overall;
- bounds checks are kept in counted byte loops.

I'd be glad to send a small PR for the first if you want it. Building inline variable-size records
cost nothing extra there, which was nice to confirm.
