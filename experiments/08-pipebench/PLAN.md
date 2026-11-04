# Experiment 8: logXform of Goose in a third-party pipeline benchmark

**Status: planned, 2026-11-04. Starts after the pilot's report.** This is a separate experiment with its own effort limit, so it doesn't change the [pilot's](../07-pilot/SPEC.md) frozen rules.

## Why

The pilot compares batch runs that we designed ourselves. The long-term goal is to compete with Vector and Fluent Bit, so we also want a test we didn't design. [PipeBench](https://github.com/VirtualMetric/PipeBench) (MIT) runs those tools through the same Docker harness, and publishes results for AWS c7i machines.

Its limits, stated up front:
- VirtualMetric maintains it and sells one of the tools it tests.
- Its tests stream over TCP. That's a different workload from the pilot's, and logXform of Goose has no TCP yet.
- Its guide asks for production-style subjects, not single-purpose ones. So this runs in a private fork, and nothing is submitted unless the project owner decides to.

## Programs

Vector and Fluent Bit as PipeBench configures them, **logXform of Goose, and a Rust version with the same design and the same front end.** Without the Rust version, a win only shows that a fixed-purpose tool beats general ones, not anything about Goose.

## Steps

1. **Finish the pilot** (change request, delivery checks, session 2, report).
2. **Rehearse on the local machine.** Pin a PipeBench commit, and run it unchanged for Vector and Fluent Bit. Docker is installed; Go needs installing. This shows the setup works. Local numbers aren't comparable with published ones, since the generator and collector share the same 6 cores as the subject.
3. **Freeze the tests and the bar, then add our programs.** Read each candidate test's files, and record here, before any front-end code exists:
   - the performance tests to attempt, and the reason for leaving out any others;
   - the correctness tests to run, including those expected to fail;
   - the transform each test needs. The tests have their own data and transforms: `regex_mask_performance`, for example, sends 256-byte lines and masks `CONN=\d+`. A hand-written mask isn't a general regex engine, and the results must say so.
4. **Run everything locally,** with all programs on the same PipeBench commit in one session.
5. **Run on a rented c7i.4xlarge** (the project owner's AWS account). Fresh instance, nothing else running. Rerun the published Vector and Fluent Bit tests first; if those don't roughly match the published numbers, our comparison isn't valid until that's explained. Then the frozen list.
6. **Report in this repository,** including every loss and every failed correctness test.

## Method

- **First version, labelled as such.** Weak results are acceptable and get published. They become the to-do list for the next version. Tests aren't dropped or swapped after seeing results.
- **Keep every round.** Rerunning a PipeBench test replaces its previous result, so each round is saved separately, with at least 3 rounds per test.
- **Verify output content.** PipeBench's receiver counts lines and bytes, so a program that skipped its transform could still score well. We sample and check the output of every program ourselves.
- **Report side by side:** total throughput, CPU per event and memory. logXform of Goose is single-threaded and the tools can use all the cores, so it's likely to lose on total throughput on a 16-vCPU machine. That is reported as a loss, not explained away.

## What counts as interesting

At least **1.3× better CPU per event** than the better of Vector and Fluent Bit on at least one processing test (not a plain passthrough), with verified output. That's the pilot's bar. It decides whether the result is worth building on, not whether to run step 5: step 5 is the only check of our setup against published numbers, so it's worth running even after a weak rehearsal.

**About Goose against Rust:** the two are compared on the same tests, and a difference within the spread is reported as no difference.

## Limits

- **Effort cap:** 1 week of work, including the report. At the cap, report what exists and stop.
- **No compiler changes,** as in the pilot. C for sockets is allowed in the Goose version, and counted.
- **Cost:** a c7i.4xlarge at roughly $0.70 an hour, from memory and unchecked, so probably a few dollars. Check the price and the running time before renting.
