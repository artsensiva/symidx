<!-- Draft comment for https://github.com/aardappel/goose/issues/63. NOT POSTED: the project owner decides. -->

This would be useful to us, and we'd be glad to help with it. We want to ship a Goose log parser inside
other programs: a Fluent Bit filter plugin first, then plain C hosts. A `.so` flag covers packaging. Two
more things decide whether that works in a host, and I'd like your view before anyone writes code.

1. **Threads.** The reference says exported functions "are not thread-safe: call them from the thread that
   called `goose_init`". A host often calls from its own worker threads, and has several. `thread_fn`
   workers already get their own data stacks and globals at spawn. Would you accept the same model for
   exported calls: a runtime per calling thread, set up on first call or by an explicit attach and detach?
   Or would you prefer an explicit context handle passed to each call?
2. **Failed checks.** Today a failed bounds check in an exported call ends the host's process.
   `thread_spawn_contained` already turns that into an error for workers. Would the same containment make
   sense for exported calls, returning an error code to the host? What can the host safely do with that
   thread's runtime afterwards: keep calling, or tear it down and attach again?
3. **More than one library.** If a process loads two Goose `.so` files, should each have its own runtime
   state, with its symbols kept private? Is anything in the runtime process-wide today that would
   get in the way?
4. **Form.** Would you rather see a design note, a branch, or a PR?

**How we'd test it.** A C host calls a log-parsing kernel one batch per call from 4 threads at once. The
output has to be byte-identical to the same program's `-t 4` mode, at 0.9× its throughput or better, with no
host-side locking, and a malformed-input case that fails a check must leave the host running. If that
turns out to need locking around every call, we'd report it and stop.

The kernel and harness are at https://github.com/artsensiva/symidx/tree/main/experiments/02-logxform.
There's no embedding prototype yet, so nothing to review so far. You'd get the numbers whichever way it goes.
