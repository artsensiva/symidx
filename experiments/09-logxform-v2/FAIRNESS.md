# Fairness review

The project owner asked, on 2026-11-05, that no program get an unfair advantage by accident. This is what a review of the code and the test setup found, before any PipeBench round had been run. No counted result had been seen when these changes were made.

## Goose against Rust: fixed

Each of these was a shortcut in how I'd written the Rust version, not something about Rust. All of them favored Goose.

| What was unequal | Effect | Fix |
|---|---|---|
| Rust zero-filled its 256 KiB read buffer on every read | Wasted work on every block | Reads into uninitialized space, as Goose does |
| Rust's JSON scan used SSE2, and Goose's `find_any` picks AVX2 at run time | Half the width on this CPU | Rust picks AVX2 at run time too |
| All Rust workers shared one regex, so all but one took a lock in its cache pool per line. Each Goose worker has its own | Lock traffic on every line | Each Rust worker clones the regex, which gives it its own pool |
| Rust allocated from the heap for each syslog line's time. Goose's scratch is a stack | One allocation per line | One buffer per block |

**In both languages:** the port number is now rendered once per connection instead of being formatted per line.

## Goose against Rust: left in place, and known

- **Each language's own regex engine is used.** That's a real difference between them, and part of what's being compared.
- **Rust has SIMD `memrchr`, and Goose loops by hand to find a block's last newline.** It only passes over part of one line, so it's small, and it's to Rust's advantage.
- **Compilers differ:** clang through Goose's generated C, and rustc's LLVM. Neither uses `-march=native`.
- **Rust's batch tool has no equivalent of Goose's skip for rare redactions.** It runs its scans per line. It's still faster than Goose there.
- **This review was done by the same agent that wrote both.** Someone expert in either language might find more.

## Against Vector and Fluent Bit: favoring ours, and left in place

These can't be removed without changing what's being tested, so the report states them.

- **One sink connection per input connection.** On this machine that's 18 to the receiver, where Vector and Fluent Bit use one or few. It's a legitimate design, and PipeBench doesn't forbid it, but it avoids a bottleneck the others have.
- **Weaker delivery semantics.** A successful TCP write counts as delivered. Neither program waits for the receiver.
- **A block's lines share one timestamp.** Vector's socket source does the same per read, as far as the comparison shows, but we haven't read its code.
- **Fewer features to run.** No metrics, tracing or routing, as the [audit](AUDIT.md) lists.
- **Disk buffer durability:** data is synced at most every 500 ms, and delivered offsets aren't synced. That's safe against a process crash and not against a power cut. We haven't compared this with what the tools do.
- **`tcp_to_tcp` and `tcp_to_blackhole` don't look at each line.** Experiment 8's bar excludes these.

## Against Vector and Fluent Bit: checked

- **Fluent Bit really parses our real-data syslog lines:** 5,000 of 5,000 sampled lines came out parsed and tagged. Its records are smaller because they carry fewer fields, as in PipeBench's own config for that test.
- **Vector's records** match ours on 2,286 of 2,286 compared.
- **Vector's image:** PipeBench uses Alpine, which could hold it back. The evaluation also runs the Debian image on two tests.
- **Run order:** rotates by test and round, because the pilot found a program runs slower straight after certain others.
- **Tool configs:** PipeBench's own are unchanged on its tests. On ours, they follow PipeBench's for the same kind of test.

## Still open

Nobody expert in Vector or Fluent Bit has reviewed the tool configurations, and that remains the largest open question about fairness toward them. Asking means posting publicly, which is the project owner's decision.
