#!/usr/bin/env python3
"""Medians across rounds, one table per test. usage: summarize.py RESULTS/LABEL [--published PIPEBENCH_WEB_RESULTS/HARDWARE]"""
import glob, json, os, statistics as st, sys
d = sys.argv[1]; pub = sys.argv[3] if len(sys.argv) > 3 else None
rows = {}
for p in glob.glob(f"{d}/round-*/*.json"):
    t, s = os.path.basename(p)[:-5].split(".")
    rows.setdefault(t, {}).setdefault(s, []).append(json.load(open(p)))
SUBJ = ["logxform-goose", "logxform-rust", "vector", "fluent-bit"]
def published(s, t):
    if not pub: return None
    try:
        return next(r for r in json.load(open(f"{pub}/{s}.json"))["results"] if r["test"] == t)
    except (OSError, StopIteration):
        return None
for t in sorted(rows):
    corr = "correctness" in t
    print(f"\n### {t}\n")
    if corr:
        print("| Program | Rounds | Passed | Lines in | Lines out | Loss % |\n|---|---|---|---|---|---|")
    else:
        print("| Program | Rounds | Lines/s, median (range) | CPU cores | Lines/s per core | Peak memory (MB) | Loss % |" + (" Published lines/s |" if pub else "") + "\n|---|---|---|---|---|---|---|" + ("---|" if pub else ""))
    for s in SUBJ:
        rs = rows[t].get(s)
        if not rs: continue
        if corr:
            ok = sum(1 for r in rs if r.get("passed") or r.get("verdict") == "PASS")
            r = rs[-1]
            print(f"| {s} | {len(rs)} | {ok} | {r['lines_in']:,} | {r['lines_out']:,} | {r['loss_percent']:.2f} |")
            continue
        eps = [r["lines_per_sec"] for r in rs]; cpu = st.median(r["avg_cpu_percent"] for r in rs) / 100
        per = st.median(r["lines_per_sec"] / max(r["avg_cpu_percent"] / 100, 0.01) for r in rs)
        mem = st.median(r["max_mem_mb"] for r in rs); loss = st.median(r["loss_percent"] for r in rs)
        row = f"| {s} | {len(rs)} | {st.median(eps):,.0f} ({min(eps):,.0f}–{max(eps):,.0f}) | {cpu:.2f} | {per:,.0f} | {mem:,.0f} | {loss:.2f} |"
        if pub:
            q = published(s, t); row += f" {q['lines_per_sec']:,.0f} |" if q else " – |"
        print(row)
