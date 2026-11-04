#!/usr/bin/env python3
"""Corrupted-image test: base and patched symidx must agree on every image, and neither may crash.

usage: corrupt.py BASE_BIN PATCHED_BIN IMAGE SCRATCH_DIR [FLIPS]
Mutations: truncations (every 1/64 of the file, plus the first 64 bytes), FLIPS seeded random single-byte
changes, and one trailing byte. For each, both binaries run `find <img> ""`; their exit codes and stdout
must match, and no run may end on a signal.
"""
import hashlib, os, random, subprocess, sys

base, patched, img, scratch = sys.argv[1:5]
flips = int(sys.argv[5]) if len(sys.argv) > 5 else 300
data = open(img, "rb").read()
n = len(data)
cases = [("trunc%d" % k, data[:k]) for k in sorted(set(list(range(64)) + [n * i // 64 for i in range(64)]))]
r = random.Random(7)
for i in range(flips):
    k = r.randrange(n)
    b = bytearray(data)
    b[k] = (b[k] + r.randrange(1, 256)) % 256
    cases.append(("flip%d@%d" % (i, k), bytes(b)))
cases.append(("trailing", data + b"\0"))

path = os.path.join(scratch, "corrupt.img")
stats = {"reject": 0, "accept": 0}
bad = 0
for name, blob in cases:
    with open(path, "wb") as f:
        f.write(blob)
    res = []
    for exe in (base, patched):
        p = subprocess.run([exe, "find", path, ""], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        res.append((p.returncode, hashlib.sha256(p.stdout).hexdigest()))
    crashed = any(rc < 0 for rc, _ in res)
    if crashed or res[0] != res[1]:
        bad += 1
        print("MISMATCH" if not crashed else "CRASH", name, res[0][0], res[1][0])
    else:
        stats["accept" if res[0][0] == 0 else "reject"] += 1
print(f"{len(cases)} images: {stats['reject']} rejected by both, {stats['accept']} accepted by both, {bad} bad")
sys.exit(1 if bad else 0)
