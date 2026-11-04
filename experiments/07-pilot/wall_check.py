#!/usr/bin/env python3
"""Why wall time differs from CPU between logXform of Goose and Rust on HDFS: a diagnostic, not one of the spec's sessions.

usage: wall_check.py BIN_DIR WORK_DIR INPUT OUT.csv
Runs both, in seeded random order, under three conditions: right after each other ("none"), after `sync` ("sync"), and right
after Fluent Bit has written the same output ("after_fluentbit"). Records wall, user and system CPU, and block and context-switch
counts for each run. Must be pinned by the caller. Stops on any failure.
"""
import csv, os, random, resource, subprocess, sys, time

bin_dir, work, path, out_csv = sys.argv[1:5]
here = os.path.dirname(os.path.abspath(__file__))
args = ["--out", work + "/o", "--rejects", work + "/r", "hdfs", path]
cmds = {"goose": [bin_dir + "/sanitize-goose"] + args, "rust": [bin_dir + "/sanitize-rust"] + args}
fluentbit = ["/usr/bin/python3", "-I", here + "/tools/sanitize_tool.py", "fluentbit"] + args


def run(cmd):
    t = time.perf_counter()
    p = subprocess.Popen(cmd, stderr=subprocess.DEVNULL)
    _, status, ru = os.wait4(p.pid, 0)
    wall = time.perf_counter() - t
    if status != 0:
        sys.exit(f"failed: {cmd} {status}")
    return wall, ru


r = random.Random(11)
plan = []
for cond, n in (("none", 10), ("sync", 10), ("after_fluentbit", 4)):
    order = [(cond, name) for name in cmds for _ in range(n)]
    r.shuffle(order)
    plan += order
with open(out_csv, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["condition", "name", "wall_s", "user_s", "sys_s", "inblock", "oublock", "nvcsw", "nivcsw", "maxrss_kb"])
    run(cmds["goose"]), run(cmds["rust"])  # warm the input
    for cond, name in plan:
        if cond == "sync":
            os.sync()
        elif cond == "after_fluentbit":
            run(fluentbit)
        wall, ru = run(cmds[name])
        w.writerow([cond, name, f"{wall:.3f}", f"{ru.ru_utime:.3f}", f"{ru.ru_stime:.3f}", ru.ru_inblock, ru.ru_oublock, ru.ru_nvcsw, ru.ru_nivcsw, ru.ru_maxrss])
        f.flush()
