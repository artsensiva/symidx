#!/usr/bin/env python3
"""Sends the same lines through Vector (PipeBench's own transforms) and a logxform binary, and compares the records field by field.
usage: compare_vector.py LOGXFORM_BINARY WORK_DIR. Needs Docker. Fields set from the moment of receipt or the connection are compared by type only."""
import json, os, random, socket, subprocess, sys, threading, time

BIN, W = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(W, exist_ok=True)
CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
rnd = random.Random(9)
def text(n): return "".join(rnd.choice(CHARS) for _ in range(n))
def real(p, n):
    if not os.path.exists(p): return []
    size = os.path.getsize(p); out = []
    with open(p, "rb") as f:
        for _ in range(n):
            f.seek(rnd.randrange(max(1, size - 4096))); f.readline()
            l = f.readline().rstrip(b"\n").decode("utf-8", "replace")
            if l: out.append(l)
    return out

C = "/home/artem/symidx/experiments/02-logxform/corpus/src"
RAW = [text(256) for _ in range(300)] + ["a CONN=123 b CONN=9", "CONN=x CONN=7", 'quote " back \\ tab\t', "café €"] + real(C + "/SSH.log", 300) + real(C + "/HDFS.log", 300)
SYS = [f"<13>2026-11-05T01:04:{i % 60:02d}Z myhost myprog[1234]: {text(200)}" for i in range(200)]
SYS += [f"<{p}>Oct 11 22:14:{p % 60:02d} mymachine su: 'su root' failed" for p in range(0, 192, 7)]
SYS += ['<165>1 2003-10-11T22:14:15.003Z h.example.com evntslog - ID47 [ex@32473 a="1"] An event', "<34>1 2003-10-11T22:14:15Z mymachine su 123 ID47 - msg here", "<13>2026-11-05T01:04:00+01:00 h p[9]: with offset", "<15>2026-11-05T01:04:00Z h dbg[1]: a debug", "<14>2026-11-05T01:04:00.123456Z h p: fraction", "<13>Nov  5 01:04:00 h p: single digit day", "no pri here", "<999>bad pri", "<13>2026-13-45T00:00:00Z h p: bad date", "<13>2026-11-05T01:04:00Z h no colon tag", "<13>2026-11-05T01:04:00Z h"]
BODY = lambda src: src
CASES = {
    "regex_mask": (RAW, r"""[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
del(.host)
del(.port)
del(.source_type)
del(.timestamp)
.message = replace(string!(.message), r'CONN=\d+', "CONN=***")
'''""", "transform regex CONN=\\d+ CONN=***"),
    "set_field": (RAW, """[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
.processed_by = "logxform-pipeline"
'''""", "transform set_field processed_by logxform-pipeline"),
    "syslog_parsing": (SYS, """[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
. = parse_syslog!(.message)
'''""", "transform syslog"),
    "real_world_1": (SYS, """[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
. = parse_syslog!(.message)
if .severity == "debug" {
  .dropped = true
}
'''""", "transform syslog_tag_debug"),
}
IMAGE = "timberio/vector:0.54.0-alpine"
VOLATILE = {"host", "port", "timestamp", "source_type"}

def collect(port, n, secs=25):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", port)); s.listen(8); s.settimeout(0.5)
    bufs = []
    def pump(c, b):
        while True:
            d = c.recv(65536)
            if not d: return
            b.extend(d)
    t0 = time.time()
    def run():
        while time.time() - t0 < secs:
            try: c, _ = s.accept()
            except OSError: continue
            b = bytearray(); bufs.append(b); threading.Thread(target=pump, args=(c, b), daemon=True).start()
    threading.Thread(target=run, daemon=True).start()
    return bufs, s

def feed(port, lines):
    for _ in range(200):
        try: c = socket.create_connection(("127.0.0.1", port)); break
        except OSError: time.sleep(0.1)
    c.sendall("".join(l + "\n" for l in lines).encode()); c.close()

def wait_lines(bufs, n, secs=20):
    t0 = time.time()
    while time.time() - t0 < secs and sum(b.count(b"\n") for b in bufs) < n: time.sleep(0.1)
    time.sleep(0.5)
    return b"".join(bytes(b) for b in bufs).splitlines()

def strip(rec, case):
    # Fields that depend on the moment of receipt or the connection.
    if "source_type" not in rec:
        return rec
    assert isinstance(rec["port"], int) and rec["host"] == "127.0.0.1" and rec["source_type"] == "socket" and len(rec["timestamp"]) == 30, rec
    return {k: v for k, v in rec.items() if k not in VOLATILE}

fails = total = 0
port = 29000
for case, (lines, xf, ours) in CASES.items():
    port += 10; pi, pv, po = port, port + 1, port + 2
    # Vector.
    conf = f"{W}/{case}.toml"
    open(conf, "w").write(f"""[sources.in]
type = "socket"
mode = "tcp"
address = "0.0.0.0:{pi}"
{xf}
[sinks.out]
type = "socket"
mode = "tcp"
inputs = ["t"]
address = "127.0.0.1:{pv}"
encoding.codec = "json"
[sinks.out.framing]
method = "newline_delimited"
""")
    bufs, s = collect(pv, len(lines))
    name = f"lx-cmp-{case}".replace("_", "-")
    subprocess.run(["docker", "rm", "-f", name], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", name, "--network", "host", "-v", f"{conf}:/etc/vector/vector.toml:ro", IMAGE, "--config", "/etc/vector/vector.toml"], capture_output=True, check=True)
    feed(pi, lines); v = wait_lines(bufs, len(lines)); subprocess.run(["docker", "rm", "-f", name], capture_output=True); s.close()
    # logxform.
    conf2 = f"{W}/{case}.conf"
    open(conf2, "w").write(f"source tcp {pi + 5}\n{ours}\nsink tcp 127.0.0.1 {po}\n")
    bufs, s = collect(po, len(lines))
    p = subprocess.Popen([BIN, "--config", conf2], stderr=subprocess.DEVNULL)
    feed(pi + 5, lines); o = wait_lines(bufs, len(lines)); p.terminate(); p.wait(); s.close()
    bad = 0; shown = 0
    if len(v) != len(lines) or len(o) != len(lines): print(f"{case}: counts: input {len(lines)}, vector {len(v)}, ours {len(o)}"); bad += 1
    for i, (a, b) in enumerate(zip(v, o)):
        ja, jb = json.loads(a), json.loads(b)
        sa, sb = strip(ja, case), strip(jb, case)
        if sa != sb:
            bad += 1
            if shown < 6:
                shown += 1; print(f"  {case} line {i}: {lines[i][:90]!r}\n    vector {json.dumps(sa)[:230]}\n    ours   {json.dumps(sb)[:230]}")
    total += len(lines); fails += bad
    print(f"{case}: {len(lines) - bad} of {len(lines)} records match Vector's")
print("records", total, "differences", fails); sys.exit(1 if fails else 0)
