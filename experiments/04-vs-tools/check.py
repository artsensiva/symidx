#!/usr/bin/env python3
"""usage: check.py REFERENCE.ndjson OUTPUT.ndjson
Compares records after normalizing: each line is parsed, kv becomes a sorted map, [] counts as an empty kv.
Reports the record counts, whether the multisets match, and whether the order matches too."""
import json, sys

def load(path):
    out = []
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            kv = r.get("kv") or {}
            out.append(json.dumps([r.get("ts"), r.get("level"), r.get("sev"), r.get("component"), r.get("msg"), sorted(kv.items())], ensure_ascii=False))
    return out

ref, got = load(sys.argv[1]), load(sys.argv[2])
same = sorted(ref) == sorted(got)
print(f"records ref={len(ref)} got={len(got)} multiset={'ok' if same else 'DIFFERENT'} order={'same' if ref == got else 'differs'}")
if not same:
    a, b = sorted(ref), sorted(got)
    from collections import Counter
    ca, cb = Counter(a), Counter(b)
    for x in list((ca - cb))[:3]: print("  only in ref:", x[:220])
    for x in list((cb - ca))[:3]: print("  only in got:", x[:220])
    sys.exit(1)
