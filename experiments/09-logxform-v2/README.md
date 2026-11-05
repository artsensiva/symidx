# logXform of Goose as a pipeline server

A small log pipeline server in Goose, and a Rust version with the same design, built to be tested in [PipeBench](https://github.com/VirtualMetric/PipeBench), a third-party benchmark that also runs Vector and Fluent Bit. Rules: [SPEC.md](SPEC.md). Frozen code: [FREEZE.md](FREEZE.md). Whether the comparison means anything: [AUDIT.md](AUDIT.md). Results: [REPORT.md](REPORT.md).

## What's here

| Path | What it is |
|---|---|
| [goose/](goose/) | The server in Goose, with a C file for sockets and system calls |
| [rust/](rust/) | The same server in Rust |
| [batch/](batch/) | The pilot's batch tool, with its known problems fixed, in Python, Goose and Rust |
| [test_server.py](test_server.py) | Behavior tests for either server, with expected values written by hand |
| [compare_vector.py](compare_vector.py) | Compares our output with Vector's, record by record |
| [mutate_server.py](mutate_server.py) | Puts a bug in the server, to see if the tests notice |
| [batch_test.py](batch_test.py), [batch_fuzz.py](batch_fuzz.py) | The batch tool's new rules, and malformed input against Python |
| [docker/](docker/), [pipebench/](pipebench/) | Images built from source, and everything that adds our subjects to PipeBench |
| [run_freeze.sh](run_freeze.sh) | The whole evaluation on the owner's machine |
| [third_party.sh](third_party.sh) | The whole evaluation on any other machine |
| [results/](results/) | Every run of every round |

## A config

```text
source tcp 9000
transform regex CONN=\d+ CONN=***
sink tcp receiver 9001
buffer disk /var/lib/logxform/buf
```

- **`source`:** `tcp PORT`, or `file /dir/name`, where a trailing `*` follows every name with that prefix. File sources also take `data_dir DIR` for checkpoints.
- **`transform`:** `none`, `regex PATTERN REPLACEMENT`, `set_field KEY VALUE`, `syslog`, `syslog_tag_debug`, or `json`. Patterns and replacements can't hold spaces.
- **`sink`:** `tcp HOST PORT`, `http HOST PORT PATH`, or `blackhole`.
- **`buffer`:** optional, `disk DIR`.

Run it with `logxform --config FILE`. SIGTERM stops it, and SIGHUP rereads the config for new connections.

## Running on another machine

`third_party.sh` does all of it on a fresh Ubuntu 22.04 or 24.04 x86_64 machine, using the frozen commit. It rents nothing: someone has to start the machine.

```bash
curl -fsSL -o third_party.sh https://raw.githubusercontent.com/artsensiva/symidx/main/experiments/09-logxform-v2/third_party.sh
bash third_party.sh c7i.4xlarge      # after installing Docker it asks you to log in again and rerun it
```

Use the exact instance type as the label, so the summary can compare with the published numbers.

**What it costs, for a c7i.4xlarge:** on-demand in us-east-1 was listed at $0.714 an hour on 2026-11-05 by [Holori](https://calculator.holori.com/aws/ec2/c7i.4xlarge/us-east-1), [Cloudchipr](https://instances.cloudchipr.com/aws/ec2/c7i.4xlarge) and [DoiT](https://compute.doit.com/spot/us-east-1/c7i.large). Three rounds should take about 7 hours including setup, so about $5, plus a little for the disk. That time comes from this machine, so it's an estimate. Check the AWS price page first. Give it at least 100 GB of disk, and don't use Spot, which can be interrupted.

**Limits of that test:** PipeBench runs the generator, receiver and collector on the same machine as the subject, as published results do. An instance from a cloud provider is independent hardware, but we'd still be the ones running the test. PipeBench's maintainer sells a competing tool. Submitting results to PipeBench is a separate decision, and its guide asks for production-style subjects, which this isn't yet.
