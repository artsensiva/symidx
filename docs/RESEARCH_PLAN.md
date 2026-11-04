# Research plan after the pilot

Set by the project owner on 2026-11-05. It replaces "finish the pilot, then a second version, then PipeBench". Details of the benchmark itself stay in [experiment 8's plan](../experiments/08-pipebench/PLAN.md).

## Principles

1. **This is research into both tools, not a choice between Rust and Goose.** We improve both in turn until a logical conclusion is reached. The pilot's rule B no longer ends the work. Its numbers remain on record.
2. **Code written after a result was seen doesn't make that result valid.** A result counts only if the code, tests and pass marks were all frozen before the run. So a follow-up variant measured after the fact is a lead, not a result. Results from a frozen new version can count.
3. **Results must reflect real use.** A large win over Vector or Fluent Bit is treated as a question about the test until checked, not as a finding.
4. **Independent method, separate hardware, parameters fixed in advance.**

## Stage 1: audit the tests against the tools

Experiment 7 compares batch file-to-file runs, with one script per format, and the two tools run behind our own wrapper. The custom programs don't do what the tools are built for. The audit asks whether our numbers are right and whether they mean anything for real use:

- **Time breakdown:** how much of each tool's time goes to input, parsing, script and output, and how much to our wrapper, which has never been measured.
- **Best configuration from the tools' own documentation:** Fluent Bit with `threaded` input, output `workers`, and a C or Wasm filter, none tried so far. Vector's `file` source in place of `stdin`, its batching, and any native functions that could replace VRL steps.
- **Pinning:** the main results use one core, and both tools are built for several. All-cores results become the main comparison for them.
- **Calibration:** rerun PipeBench's published Vector and Fluent Bit tests before adding our programs. If they don't reproduce, the problem is in our setup.
- **Outside review of our tool configurations:** only if the project owner decides to ask in public.
- **Still open from the pilot:** the Fluent Bit lost reject and the feature table.

**Output:** a corrected tool configuration, and a plain list of what experiment 7 can and can't claim.

## Stage 2: fix the requirements for the new version, before any code

logXform of Goose and the Rust version get the same list:

| Shortcoming found | Requirement |
|---|---|
| Hex scan costs 31% on data with no matches | A per-line cost limit on data with no matches, fixed here in advance |
| IPs inside SSH host names leak | New redaction rules, written before the code, with oracle cases. The tools get them too |
| Input can fill Goose's 2 GiB data stack, with a misleading error | A stated line-length limit, a clear error or a reject, and bounded memory |
| Twice Rust's memory on a very long kept line, and 1.14× on escape-heavy data | Memory limits fixed in advance |
| 1.57× Fluent Bit's memory on BGL | Find the cause, then set a limit |
| No network input, and one thread | A TCP front end and several workers, as PipeBench's subject guide requires |
| Misaligned accesses in generated C | Compiler behavior, so a documented limit while compiler work stays paused. If a requirement can't be met without a compiler change, the owner is asked |

The pilot's checks all stay. Compiler patches stay local.

## Stage 3: implement and freeze

Both versions are implemented, then frozen by commit and binary hash, with Goose going first again. Any change after the freeze means a new version and new runs.

## Stage 4: final evaluation on this machine

Tests and pass marks are committed before the freeze. They include data neither version was developed on, and a new change request. The corrected tool configurations from stage 1 are used.

## Stage 5: independent benchmark

As in experiment 8: PipeBench at a pinned commit, a local rehearsal, then a fresh c7i.4xlarge rented by the project owner, whose price and go-ahead are confirmed first. Published tests are rerun first. PipeBench is run by a vendor of a competing tool, which the report will state.

## When to stop

**Proposed, for the owner to confirm.** Stop when any of these holds:

- Another round improves CPU per event and memory by under 5% on the independent tests.
- No listed shortcoming is left that can be fixed without a compiler change.
- The owner stops the work.

The conclusion then says, test by test, who wins and why, including where the tools win and what the custom programs don't do.
