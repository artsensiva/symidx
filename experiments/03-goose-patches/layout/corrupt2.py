#!/usr/bin/env python3
"""Corrupted-image test for one image and the modes that read it.

usage: corrupt2.py IMAGE SCRATCH_DIR FLIPS NAME=CMD [NAME=CMD ...]
CMD is `[ENV:KEY=VAL ...] binary`; each runs as `binary find <img> ""`. Mutations: truncations (the first 64
lengths and every 1/64 of the file), FLIPS seeded single-byte changes, one trailing byte. No run may end on
a signal, every truncation and the trailing byte must be rejected, and all modes must give the same exit
code, and the same output when they exit 0.
"""
import hashlib, os, random, subprocess, sys

img, scratch, flips = sys.argv[1], sys.argv[2], int(sys.argv[3])
modes = []
for a in sys.argv[4:]:
    name, cmd = a.split("=", 1)
    toks = cmd.split()
    env = dict(os.environ)
    for t in toks:
        if t.startswith("ENV:"):
            k, v = t[4:].split("=", 1)
            env[k] = v
    modes.append((name, [t for t in toks if not t.startswith("ENV:")], env))
data = open(img, "rb").read()
n = len(data)
cases = [("trunc%d" % k, data[:k], True) for k in sorted(set(list(range(64)) + [n * i // 64 for i in range(64)]))]
r = random.Random(11)
for i in range(flips):
    k = r.randrange(n)
    b = bytearray(data)
    b[k] = (b[k] + r.randrange(1, 256)) % 256
    cases.append(("flip%d@%d" % (i, k), bytes(b), False))
cases.append(("trailing", data + b"\0", True))
path = os.path.join(scratch, "corrupt2.img")
acc = rej = bad = 0
for name, blob, must_reject in cases:
    with open(path, "wb") as f:
        f.write(blob)
    res = []
    for mname, argv, env in modes:
        p = subprocess.run(argv + ["find", path, ""], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        res.append((mname, p.returncode, hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else ""))
    codes = {(rc, h) for _, rc, h in res}
    if any(rc < 0 for _, rc, _ in res) or len(codes) != 1 or (must_reject and res[0][1] == 0):
        bad += 1
        print("BAD", name, [(m, rc) for m, rc, _ in res])
    elif res[0][1] == 0:
        acc += 1
    else:
        rej += 1
print(f"{len(cases)} images: {rej} rejected by all, {acc} accepted by all, {bad} bad")
sys.exit(1 if bad else 0)
