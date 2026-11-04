#!/usr/bin/env python3
"""A program under test against gen_adversarial.py's expectations, and requirement 6's failure cases (SPEC A2).

usage: check_oracle.py CASES_DIR SCRATCH_DIR CMD [ARG ...]
Exits 1 on any failure, listing each one.
"""
import glob, os, subprocess, sys, time

cases, scratch = sys.argv[1], sys.argv[2]
cmd = sys.argv[3:]
os.makedirs(scratch, exist_ok=True)
fails = []
passed = 0


def check(name, cond, detail=""):
    global passed
    if cond:
        passed += 1
    else:
        fails.append(f"{name}: {detail}")


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return f"first difference at byte {i}: got {a[max(0, i - 30):i + 40]!r}, want {b[max(0, i - 30):i + 40]!r}"
    return f"lengths differ: got {len(a)}, want {len(b)}; {'got' if len(a) > len(b) else 'want'} continues {(a if len(a) > len(b) else b)[n:n + 60]!r}"


inputs = sorted(p for p in glob.glob(os.path.join(cases, "*")) if p.rsplit(".", 1)[1] in ("hdfs", "ssh", "apache"))
for path in inputs:
    base, fmt = path.rsplit(".", 1)
    name = os.path.basename(base)
    out, rej = os.path.join(scratch, "out"), os.path.join(scratch, "rej")
    p = subprocess.run(cmd + ["--out", out, "--rejects", rej, fmt, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check(f"{name}: exit", p.returncode == 0, f"exit {p.returncode}: {p.stderr[-200:]!r}")
    got = open(out, "rb").read() if os.path.exists(out) else b"<no file>"
    want = open(base + ".expected", "rb").read()
    check(f"{name}: output", got == want, first_diff(got, want) if got != want else "")
    got = open(rej, "rb").read() if os.path.exists(rej) else b"<no file>"
    want = open(base + ".rejects", "rb").read()
    check(f"{name}: rejects", got == want, first_diff(got, want) if got != want else "")
    want = open(base + ".summary", "rb").read().strip()
    check(f"{name}: summary", want in p.stderr, f"got {p.stderr[-120:]!r}, want {want!r}")
    p2 = subprocess.run(cmd + [fmt, path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    check(f"{name}: stdout equals --out", p2.stdout == open(base + ".expected", "rb").read(), "differs")
    with open(path, "rb") as f:
        p3 = subprocess.run(cmd + [fmt, "-"], stdin=f, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    check(f"{name}: stdin equals file", p3.stdout == open(base + ".expected", "rb").read(), "differs")
    for f in (out, rej):
        if os.path.exists(f):
            os.unlink(f)

# Several inputs in one run, in order.
a, b = os.path.join(cases, "redaction"), os.path.join(cases, "levels")
p = subprocess.run(cmd + ["apache", a + ".apache", "hdfs", b + ".hdfs"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
check("two inputs, in order", p.stdout == open(a + ".expected", "rb").read() + open(b + ".expected", "rb").read(), "differs")

# Requirement 6 and the rest of SPEC A2.
good = os.path.join(cases, "levels.hdfs")
bad = os.path.join(cases, "apache_fields.apache")
out = os.path.join(scratch, "fail-out")
for f in (out, out + ".tmp"):
    if os.path.exists(f):
        os.unlink(f)
p = subprocess.run(cmd + ["--out", out, "hdfs", os.path.join(scratch, "does-not-exist")], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
check("missing input: exit 3", p.returncode == 3, f"exit {p.returncode}")
check("missing input: a message", len(p.stderr) > 0, "no message")
check("missing input: no output file", not os.path.exists(out) and not os.path.exists(out + ".tmp"), "file left behind")
p = subprocess.run(cmd + ["--out", out, "hdfs", good, "hdfs", os.path.join(scratch, "does-not-exist")], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
check("second input missing: exit 3, no output file", p.returncode == 3 and not os.path.exists(out) and not os.path.exists(out + ".tmp"), f"exit {p.returncode}")
p = subprocess.run(cmd + ["--out", os.path.join(scratch, "no-such-dir", "x"), "hdfs", good], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
check("unwritable --out: exit 3", p.returncode == 3, f"exit {p.returncode}")
with open("/dev/full", "wb") as full:
    p = subprocess.run(cmd + ["hdfs", good], stdout=full, stderr=subprocess.PIPE)
check("disk full on stdout: exit 3", p.returncode == 3, f"exit {p.returncode}")
big = os.path.join(cases, "nothing_filtered.hdfs")
pr = subprocess.Popen(cmd + ["hdfs", big], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
pr.stdout.read(10)
pr.stdout.close()
err = pr.stderr.read()
rc = pr.wait()
check("closed pipe: exit 3 with a message", rc == 3 and len(err) > 0, f"exit {rc}, stderr {err[-80:]!r}")
# Killed partway, --out's file must not exist: it appears only by the final rename. Input stays open on a pipe, so this doesn't depend on speed.
pk = subprocess.Popen(cmd + ["--out", out, "hdfs", "-"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
line = open(good, "rb").readline()
try:
    pk.stdin.write(line * 400000)
    pk.stdin.flush()
except BrokenPipeError:
    pass
time.sleep(1.0)
pk.kill()
pk.wait()
pk.stdin = None
check("killed partway: no final output file", not os.path.exists(out), "the final file exists before the run finished")
for f in (out, out + ".tmp"):
    if os.path.exists(f):
        os.unlink(f)
p = subprocess.run(cmd + ["--out", out, "--max-reject-rate", "0.1", "apache", bad], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
check("reject rate exceeded: exit 1, no output file", p.returncode == 1 and not os.path.exists(out) and not os.path.exists(out + ".tmp"), f"exit {p.returncode}")
check("reject rate exceeded: summary still printed", b"lines=" in p.stderr, "no summary")
p = subprocess.run(cmd + ["--max-reject-rate", "0.9", "apache", bad], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
check("reject rate within limit: exit 0", p.returncode == 0, f"exit {p.returncode}")
p = subprocess.run(cmd + ["--max-reject-rate", "0", "hdfs", os.path.join(cases, "empty.hdfs")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
check("zero lines never fail the rate", p.returncode == 0, f"exit {p.returncode}")
for argv, name in (([], "no arguments"), (["hdfs"], "format without path"), (["nope", good], "unknown format"), (["--nope", "x", "hdfs", good], "unknown option"), (["--max-reject-rate", "abc", "hdfs", good], "bad rate")):
    p = subprocess.run(cmd + argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check(f"bad command line, {name}: exit 2", p.returncode == 2, f"exit {p.returncode}")

for f in fails:
    print("FAIL", f)
print(f"{passed} of {passed + len(fails)} checks passed")
sys.exit(1 if fails else 0)
