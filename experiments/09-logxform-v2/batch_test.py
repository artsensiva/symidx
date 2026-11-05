#!/usr/bin/env python3
"""Hand-written expectations for experiment 9's batch rules. usage: batch_test.py WORK_DIR CMD... (each CMD one program, quoted)"""
import json, os, shlex, subprocess, sys

work, cmds = sys.argv[1], sys.argv[2:]
os.makedirs(work, exist_ok=True)
H = b"081109 203518 143 INFO dfs.X: "
DASH = [  # message in, message out
    (b"from ec2-52-80-34-196.cn-north-1.compute.amazonaws.com.cn port", b"from ec2-<ip>.cn-north-1.compute.amazonaws.com.cn port"),
    (b"ip-10-0-0-1 x", b"ip-<ip> x"),
    (b"10-0-0-1", b"<ip>"),
    (b"a 255-255-255-255 b", b"a <ip> b"),
    (b"a 256-1-1-1 b", b"a 256-1-1-1 b"),
    (b"date 2005-06-03-15 x", b"date 2005-06-03-15 x"),
    (b"five 1-2-3-4-5 x", b"five 1-2-3-4-5 x"),
    (b"ab1-2-3-4 x", b"ab<ip> x"),
    (b"getaddrinfo for host229-140-211-80.serverdedicati.aruba.it x", b"getaddrinfo for host<ip>.serverdedicati.aruba.it x"),
    (b"a12345-1-2-3 x", b"a12345-1-2-3 x"),
    (b"rhost=pla75-1-78-194-48-145.fbxo.proxad.net x", b"rhost=pla75-1-<ip>.fbxo.proxad.net x"),
    (b"rhost=hmtnon1497w-lp130-03-70-54-45-110.dsl.bell.ca", b"rhost=hmtnon1497w-lp130-03-<ip>.dsl.bell.ca"),
    (b"a 657-1-127-147 b", b"a 657-1-127-147 b"),
    (b"--1-2-3-4-5", b"--1-<ip>"),
    (b"a.1-2-3-4 b", b"a.<ip> b"),
    (b"v1.2-3-4-5 b", b"v1.<ip> b"),
    (b"x.0x12345678 y", b"x.<hex> y"),
    (b"1-2-3-4x", b"1-2-3-4x"),
    (b"1-2-3-4-x", b"<ip>-x"),
    (b"x-1-2-3-4", b"x-<ip>"),
    (b"--1-2-3-4", b"--<ip>"),
    (b"1-2-3-4 5-6-7-8", b"<ip> <ip>"),
    (b"1.2.3.4 and 5-6-7-8 and 0x12345678", b"<ip> and <ip> and <hex>"),
    (b"1-2-3", b"1-2-3"),
    (b"1000-2-3-4", b"1000-2-3-4"),
    (b"1-2-3-1000", b"1-2-3-1000"),
    (b"9-1-2-3-4 y", b"9-1-2-3-4 y"),
    (b"host_1-2-3-4", b"host_<ip>"),
    (b"caf\xc3\xa9-1-2-3-4", b"caf\xc3\xa9-<ip>"),
]
LIM = 100
LONG = [  # line, its kept/rejected fate with --max-line 100
    (H + b"x" * (LIM - len(H)), True),            # exactly at the limit
    (H + b"x" * (LIM - len(H) + 1), False),       # one over
    (b"y" * 100000, False),                       # far over, and over the read block when multiplied below
]
fails = 0


def run(cmd, data, args=()):
    p, o, r = f"{work}/in", f"{work}/out", f"{work}/rej"
    open(p, "wb").write(data)
    x = subprocess.run(shlex.split(cmd) + ["--out", o, "--rejects", r, *args, "hdfs", p], capture_output=True)
    return x.returncode, open(o, "rb").read(), open(r, "rb").read(), x.stderr


for cmd in cmds:
    name = shlex.split(cmd)[-1].rsplit("/", 1)[-1]
    bad = 0
    for m, want in DASH:
        rc, o, _, _ = run(cmd, H + m + b"\n")
        got = json.loads(o, strict=False)["msg"].encode("utf-8", "surrogateescape") if rc == 0 and o else None
        if got != want:
            print(f"FAIL {name}: {m!r} -> {got!r}, want {want!r}")
            bad += 1
    # The line limit.
    data = b"".join(l + b"\n" for l, _ in LONG) + H + b"after\n"
    rc, o, r, e = run(cmd, data, ["--max-line", str(LIM)])
    want_rej = (H + b"x" * (LIM - len(H) + 1))[:4096] + b"\n" + b"y" * 4096 + b"\n"
    if rc != 0 or o.count(b"\n") != 2 or b"after" not in o or r != want_rej or b"lines=4 kept=2 dropped=0 malformed=2" not in e:
        print(f"FAIL {name}: line limit rc={rc} out={o[:200]!r} rej={r[:60]!r}({len(r)}, want {len(want_rej)}) {e!r}")
        bad += 1
    # Past the limit with no newline at the end of the file, and spanning many read blocks.
    big = H + b"ok\n" + b"z" * (5 << 20)
    rc, o, r, e = run(cmd, big, ["--max-line", "1048576"])
    if rc != 0 or o.count(b"\n") != 1 or r != b"z" * 4096 + b"\n" or b"lines=2 kept=1 dropped=0 malformed=1" not in e:
        print(f"FAIL {name}: unended long line rc={rc} rej={len(r)} {e!r}")
        bad += 1
    print(f"{'FAILED' if bad else 'ok'} {name}: {len(DASH) + 2 - bad} of {len(DASH) + 2}")
    fails += bad
sys.exit(1 if fails else 0)
