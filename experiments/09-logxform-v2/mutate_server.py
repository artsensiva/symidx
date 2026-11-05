#!/usr/bin/env python3
"""Do the server's behavior tests catch bugs? Builds the Goose server with one bug each, and runs test_server.py. usage: mutate_server.py GOOSE WORK_DIR"""
import os, shutil, subprocess, sys
GOOSE, W = sys.argv[1], os.path.abspath(sys.argv[2])
HERE = os.path.dirname(os.path.abspath(__file__))
G, C = "logxform.goose", "net.c"
M = [
    ("backslash not escaped", G, """else if c == '\\\\' { out.append("\\\\\\\\"); }""", """else if c == '\\\\' { out.append("\\\\"); }"""),
    ("facility from the wrong bits", G, "FACS[pri >> 3]", "FACS[(pri >> 2) & 23]"),
    ("time zone offset ignored", G, "+ s - off, frac)", "+ s, frac)"),
    ("delivered offset not saved", G, "acked += nl + 1;\n                    lx_put8(ack, acked);", "acked += nl + 1;"),
    ("truncation not noticed", G, "if size < off { off = 0; buf.clear(); lx_put8(ckpt, 0); }", ""),
    ("checkpoint not saved", G, "off += if nl < 0 { n } else { e };\n        lx_put8(ckpt, off);", "off += if nl < 0 { n } else { e };"),
    ("failed send treated as delivered", G, "if lx_term() { return false; }\n        sleep_ms(100);", "return true;"),
    ("line limit not enforced", G, 'if buf.len > MAX_LINE { write_stderr("logxform: line over the limit dropped\\n"); buf.clear(); skipping = true; }\n            continue;', "continue;"),
    ("final partial line lost", G, "if buf.len > 0 && !skipping { buf.push('\\n'); }\n        }\n        let nl = last_nl(buf[buf.len - n", "}\n        let nl = last_nl(buf[buf.len - n"),
    ("debug severity not tagged", G, "if tag_debug && sev == 7", "if tag_debug && sev == 6"),
    ("non-2xx HTTP treated as success", G, "if r.len < 12 || r[9] != '2' { return false; }", ""),
    ("SIGHUP not handled", C, "signal(SIGHUP, on_hup);", ""),
    ("SIGPIPE not ignored", C, "signal(SIGPIPE, SIG_IGN);", ""),
    ("replay not started", G, "thread_spawn(disk_sender, str(cfg.buf_dir, \"/\", stem[..dot])[..], low, false, copy(cfg));", ""),
    ("reader tied to the sink", G, "thread_spawn(disk_sender, base[..], 0, true, copy(cfg));", "thread_spawn(disk_sender, base[..], 0, true, copy(cfg)); sleep_ms(3000);"),
]
caught = 0
for name, f, old, new in M:
    d = f"{W}/m"; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    for x in (G, C, "logxform.build"):
        shutil.copy(f"{HERE}/goose/{x}", d)
    s = open(f"{d}/{f}").read()
    if s.count(old) != 1:
        print(f"NOT APPLIED  {name} ({s.count(old)} matches)", flush=True); continue
    open(f"{d}/{f}", "w").write(s.replace(old, new))
    b = subprocess.run([GOOSE, "build", G, "--cc", "clang", "--stack-reserve", "1G", "-o", "logxform"], cwd=d, capture_output=True, text=True)
    if b.returncode:
        print(f"NO BUILD     {name}: {b.stdout[-160:]}{b.stderr[-160:]}", flush=True); continue
    try:
        t = subprocess.run([sys.executable, "-I", f"{HERE}/test_server.py", f"{d}/logxform"], capture_output=True, text=True, timeout=240)
        bad = [l.split()[1].rstrip(":") for l in t.stdout.splitlines() if l.startswith("FAIL")]
    except subprocess.TimeoutExpired:
        bad = ["timeout"]
    subprocess.run(["pkill", "-x", "logxform"])
    caught += bool(bad)
    print(f"{'CAUGHT' if bad else 'MISSED'}       {name}: {', '.join(bad[:4])}", flush=True)
print(f"{caught} of {len(M)} caught")
