#!/usr/bin/env python3
"""check.py must reject what it should. A checker nobody tests is how a bad comparison passes."""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
A = {"ts": "t1", "level": "INFO", "sev": 6, "component": "c", "msg": "m1", "kv": {"a": "1", "b": "2"}}
B = {"ts": "t2", "level": "WARN", "sev": 4, "component": "c", "msg": "m2", "kv": {}}
C = {"ts": "t3", "level": "INFO", "sev": 6, "component": "d", "msg": "m3", "kv": {"x": "y"}}


def w(path, rows):
    with open(path, "w") as f:
        for r in rows:
            f.write((r if isinstance(r, str) else json.dumps(r)) + "\n")


def with_(r, **k):
    return {**r, **k}


def without(r, key):
    return {k: v for k, v in r.items() if k != key}


# name, output rows, extra args, want exit code
CASES = [
    ("identical", [A, B, C], [], 0),
    ("other key order", [dict(reversed(list(A.items()))), B, C], [], 0),
    ("kv order differs", [with_(A, kv={"b": "2", "a": "1"}), B, C], [], 0),
    ("empty kv as []", [A, with_(B, kv=[]), C], [], 0),
    ("empty kv as 0", [A, with_(B, kv=0), C], [], 1),
    ("empty kv as empty string", [A, with_(B, kv=""), C], [], 1),
    ("empty kv as false", [A, with_(B, kv=False), C], [], 1),
    ("empty kv as null", [A, with_(B, kv=None), C], [], 1),
    ("non-empty kv as []", [with_(A, kv=[]), B, C], [], 1),
    ("kv value not a string", [with_(A, kv={"a": 1, "b": "2"}), B, C], [], 1),
    ("kv value differs", [with_(A, kv={"a": "9", "b": "2"}), B, C], [], 1),
    ("extra top-level field", [with_(A, extra="x"), B, C], [], 1),
    ("missing top-level field", [without(A, "msg"), B, C], [], 1),
    ("sev as a float", [with_(A, sev=6.0), B, C], [], 1),
    ("sev as a string", [with_(A, sev="6"), B, C], [], 1),
    ("msg differs", [with_(A, msg="other"), B, C], [], 1),
    ("not JSON", ["{not json", B, C], [], 1),
    ("reordered", [B, A, C], [], 1),
    ("reordered, --unordered", [B, A, C], ["--unordered"], 0),
    ("record missing", [A, C], [], 1),
    ("record missing, allowed", [A, C], ["--allow-missing", "1"], 0),
    ("two missing, one allowed", [C], ["--allow-missing", "1"], 1),
    ("extra record at the end", [A, B, C, C], [], 1),
    ("extra record, --unordered", [A, B, C, C], ["--unordered"], 1),
    ("empty output", [], [], 1),
]

fails = 0
with tempfile.TemporaryDirectory() as d:
    ref, got = os.path.join(d, "ref"), os.path.join(d, "got")
    w(ref, [A, B, C])
    for name, rows, extra, want in CASES:
        w(got, rows)
        rc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "check.py"), ref, got] + extra, stdout=subprocess.DEVNULL).returncode
        if rc != want:
            print(f"FAIL {name}: exit {rc}, want {want}")
            fails += 1
print(f"{len(CASES) - fails} of {len(CASES)} check.py cases passed")
sys.exit(1 if fails else 0)
