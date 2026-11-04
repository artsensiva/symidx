#!/usr/bin/env python3
"""Prints a session's tables from its CSV files. usage: summarize.py SESSION_DIR CORPUS_DIR ADVERSARIAL_DIR"""
import csv, os, statistics as st, sys
d, corpus, adv = sys.argv[1:4]
NAMES = ["goose", "rust", "python", "fluentbit", "vector"]
FILES = {"hdfs": corpus + "/HDFS.log", "ssh": corpus + "/SSH.log", "apache": corpus + "/Apache.log",
         "escape_heavy": adv + "/escape_heavy.hdfs", "mostly_filtered": adv + "/mostly_filtered.hdfs"}
def load(stage):
    rows = {}
    for r in csv.DictReader(open(f"{d}/{stage}.csv")):
        rows.setdefault(r["name"], []).append(r)
    return rows
def med(rows, n, k):
    return st.median(float(r[k]) for r in rows[n])
def rng(rows, n, k):
    v = [float(r[k]) for r in rows[n]]
    return min(v), max(v)
print("One core, per stage: MB/s, peak MiB, CPU s/GB, wall range (s), CPU range (s)")
total = {n: [0.0, 0.0, 0.0] for n in NAMES}
sizes = 0
for f, p in FILES.items():
    rows = load(f + "-one-core")
    gb = os.path.getsize(p) / 1e9
    print(f"\n{f} ({gb * 1000:.1f} MB)")
    for n in NAMES:
        w, c, m = med(rows, n, "wall_s"), med(rows, n, "cpu_s"), med(rows, n, "maxrss_kb") / 1024
        print(f"  {n:10} {gb * 1000 / w:7.1f} {m:6.1f} {c / gb:7.1f}  wall {rng(rows, n, 'wall_s')[0]:.2f}-{rng(rows, n, 'wall_s')[1]:.2f}  cpu {rng(rows, n, 'cpu_s')[0]:.2f}-{rng(rows, n, 'cpu_s')[1]:.2f}")
        if f in ("hdfs", "ssh", "apache"):
            t = total[n]; t[0] += w; t[1] += c; t[2] = max(t[2], m)
    if f in ("hdfs", "ssh", "apache"):
        sizes += gb
print(f"\nM total ({sizes * 1000:.0f} MB), sum of per-format medians")
for n in NAMES:
    w, c, m = total[n]
    print(f"  {n:10} {sizes * 1000 / w:7.1f} {m:6.1f} {c / sizes:7.1f}  cpu/goose {c / total['goose'][1]:6.2f}  wall/goose {w / total['goose'][0]:6.2f}")
print("\nHDFS, all cores: wall (s) per round, MB/s from median, peak MiB")
rows = load("hdfs-all-cores"); gb = os.path.getsize(FILES["hdfs"]) / 1e9
for n in rows:
    print(f"  {n:10} {[round(float(r['wall_s']), 1) for r in rows[n]]} {gb * 1000 / med(rows, n, 'wall_s'):7.1f} {med(rows, n, 'maxrss_kb') / 1024:6.1f}")
