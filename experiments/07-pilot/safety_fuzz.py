#!/usr/bin/env python3
"""Malformed-input run for the safety section (SPEC A5): seeded mutations of real and adversarial lines.

usage: safety_fuzz.py BIN_DIR CORPUS_DIR BGL_LOG ADVERSARIAL_DIR WORK_DIR CASES TOOL_CASES OUT.txt
Each case is a small file of mutated lines. logXform of Goose and Rust must match the Python reference exactly: exit code, output,
rejects and summary. Every program must exit by itself with a code from the spec, never on a signal. The tools run on TOOL_CASES
of them, for crashes only, since their outputs differ on invalid bytes, as already recorded. Stops at no failure; lists them all.
"""
import os, random, shutil, subprocess, sys

bin_dir, corpus, bgl, adv, work, cases, tool_cases, out_path = sys.argv[1:9]
cases, tool_cases = int(cases), int(tool_cases)
here = os.path.dirname(os.path.abspath(__file__))
os.makedirs(work, exist_ok=True)
SEEDS = {"hdfs": corpus + "/HDFS.log", "ssh": corpus + "/SSH.log", "apache": corpus + "/Apache.log", "bgl": bgl}
r = random.Random(20261104)
pools = {}
for fmt, p in SEEDS.items():
    with open(p, "rb") as f:
        size = os.path.getsize(p)
        lines = []
        for _ in range(4000):
            f.seek(r.randrange(max(1, size - 4096)))
            f.readline()
            line = f.readline().rstrip(b"\n")
            if line:
                lines.append(line)
    # Lines the rules care about, which random sampling rarely finds.
    pools[fmt] = lines
pools["bgl"] += [b"- 1 2005.06.03 - 2005-06-03-15.42.50.363779 RAS APP INFO iar=0x00544eb8", b"AL 1 2005.06.03 N 2005-06-03-15.42.50.363779 N NULL APP SEVERE 1.2.3.4"]
BYTES = [0, 9, 10, 13, 32, 34, 45, 46, 48, 58, 61, 91, 92, 93, 120, 127, 128, 192, 255]
TOKENS = [b"0x12345678", b"0x", b"1.2.3.4", b"=", b": ", b"[", b"]", b" ", b"  ", b"\r", b"\t", b"\xff\xfe", b"blk_", b"blk_-", b"RAS ", b"NULL ", b"APP ", b"\\", b'"', b"%s%n", b"\x00"]


def mutate(s):
    b = bytearray(s)
    for _ in range(r.randrange(1, 5)):
        k = r.randrange(8)
        i = r.randrange(len(b) + 1)
        if k == 0 and b:
            b[min(i, len(b) - 1)] = r.randrange(256)
        elif k == 1 and b:
            b[min(i, len(b) - 1)] = r.choice(BYTES)
        elif k == 2:
            del b[i:]
        elif k == 3:
            del b[:i]
        elif k == 4:
            b[i:i] = r.choice(TOKENS)
        elif k == 5 and b:
            j = r.randrange(len(b))
            del b[min(i, j):max(i, j)]
        elif k == 6:
            b[i:i] = r.choice(TOKENS) * r.randrange(1, 2000)
        else:
            b[i:i] = bytes(r.randrange(256) for _ in range(r.randrange(1, 64)))
    return bytes(b)


def make(fmt, path):
    with open(path, "wb") as f:
        for _ in range(r.randrange(1, 300)):
            s = r.choice(pools[fmt])
            f.write(mutate(s) if r.random() < 0.8 else s)
            f.write(b"\n")
        if r.random() < 0.3:
            f.write(mutate(r.choice(pools[fmt])))


def run(cmd, fmt, path):
    o, j = work + "/o", work + "/j"
    for x in (o, j):
        if os.path.exists(x):
            os.unlink(x)
    p = subprocess.run(cmd + ["--out", o, "--rejects", j, fmt, path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=600)
    read = lambda x: open(x, "rb").read() if os.path.exists(x) else None
    return p.returncode, read(o), read(j), p.stderr


ref = ["/usr/bin/python3", "-I", here + "/sanitize.py"]
prog = {"goose": [bin_dir + "/sanitize-goose"], "rust": [bin_dir + "/sanitize-rust"]}
tools = {"fluentbit": ["/usr/bin/python3", "-I", here + "/tools/sanitize_tool.py", "fluentbit"], "vector": ["/usr/bin/python3", "-I", here + "/tools/sanitize_tool.py", "vector"]}
fails, signals, n_lines = [], {}, 0
names = list(SEEDS)
keep = work + "/failing"
for c in range(cases):
    fmt = names[c % len(names)]
    path = f"{work}/case.{fmt}"
    make(fmt, path)
    rc, o, j, e = run(ref, fmt, path)
    if rc not in (0, 1, 3):
        fails.append((c, fmt, "python", rc))
    for name, cmd in prog.items():
        res = run(cmd, fmt, path)
        if res[0] < 0:
            signals[name] = signals.get(name, 0) + 1
        if res[0] != rc or res[1] != o or res[2] != j or res[3] != e:
            fails.append((c, fmt, name, res[0]))
            os.makedirs(keep, exist_ok=True)
            shutil.copy(path, f"{keep}/{c}.{name}.{fmt}")
    if c < tool_cases:
        for name, cmd in tools.items():
            res = run(cmd, fmt, path)
            if res[0] < 0 or res[0] not in (0, 1, 3):
                signals[name] = signals.get(name, 0) + 1
                fails.append((c, fmt, name, res[0]))
with open(out_path, "w") as f:
    f.write(f"cases={cases} tool_cases={tool_cases} failures={len(fails)} signals={signals}\n")
    for x in fails[:50]:
        f.write(f"{x}\n")
print(open(out_path).read()[:1500])
sys.exit(1 if fails else 0)
