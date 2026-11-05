#!/usr/bin/env python3
"""Prints PipeBench results for chosen subjects. usage: show.py RESULTS_DIR/HARDWARE SUBJECT..."""
import json, sys
d, subs = sys.argv[1], sys.argv[2:]
rows = {}
for s in subs:
    try:
        for r in json.load(open(f"{d}/{s}.json"))["results"]:
            rows.setdefault(r["test"], {})[s] = r
    except OSError:
        pass
for t in sorted(rows):
    print(t)
    for s in subs:
        r = rows[t].get(s)
        if r:
            cpu = r["avg_cpu_percent"] / 100
            eps = r["lines_per_sec"]
            print(f"  {s:16} lines/s {eps:>11,.0f}  cpu {cpu:6.2f} cores  lines/s per core {eps / cpu if cpu else 0:>11,.0f}  mem {r['max_mem_mb']:>8.1f} MB  loss {r['loss_percent']:6.2f}%  in {r['lines_in']:>11,} out {r['lines_out']:>11,}")
