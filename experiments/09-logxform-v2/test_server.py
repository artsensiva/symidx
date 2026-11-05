#!/usr/bin/env python3
"""Behavior tests for the logxform server, in any language. usage: test_server.py BINARY [only-these-test-names]
Expected values are written by hand here, independently of the programs. Prints one line per test, and exits 1 on any failure."""
import http.server, json, os, shutil, signal, socket, socketserver, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath(sys.argv[1]); ONLY = sys.argv[2:]
TMP = tempfile.mkdtemp(prefix="lxt"); ports = iter(range(19100, 19900))
fails = []


class Recv:
    """A TCP receiver that keeps everything per connection."""
    def __init__(self, port):
        self.port, self.conns, self.stop = port, [], False
        self.s = socket.socket(); self.s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.s.bind(("127.0.0.1", port)); self.s.listen(64); self.s.settimeout(0.1)
        threading.Thread(target=self.run, daemon=True).start()
    def run(self):
        while not self.stop:
            try: c, _ = self.s.accept()
            except OSError: continue
            b = bytearray(); self.conns.append(b)
            threading.Thread(target=self.pump, args=(c, b), daemon=True).start()
    def pump(self, c, b):
        while True:
            d = c.recv(1 << 20)
            if not d: break
            b.extend(d)
    def all(self): return b"".join(bytes(b) for b in self.conns)
    def close(self): self.stop = True; time.sleep(0.15); self.s.close()


def wait(cond, secs=10):
    t = time.time()
    while time.time() - t < secs:
        if cond(): return True
        time.sleep(0.02)
    return False


class Srv:
    def __init__(self, conf, port=None, name="c"):
        self.path = f"{TMP}/{name}{next(ports)}.conf"
        with open(self.path, "w") as f: f.write(conf)
        self.port = port; self.start()
    def start(self):
        self.p = subprocess.Popen([BIN, "--config", self.path], stderr=subprocess.DEVNULL)
        if self.port: assert wait(lambda: conn_ok(self.port)), "server didn't listen"
    def stop(self, sig=signal.SIGTERM):
        self.p.send_signal(sig)
        try: return self.p.wait(10)
        except subprocess.TimeoutExpired: self.p.kill(); self.p.wait(); return "timeout"


def conn_ok(port):
    try: socket.create_connection(("127.0.0.1", port), 0.2).close(); return True
    except OSError: return False


def send(port, data, close=True):
    c = socket.create_connection(("127.0.0.1", port)); c.sendall(data)
    if close: c.close()
    return c


def tcp_conf(port, sport, xf="none", extra=""):
    return f"source tcp {port}\ntransform {xf}\nsink tcp 127.0.0.1 {sport}\n{extra}\n"


def through(xf, data):
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po, xf), pi)
    n = data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)
    send(pi, data); wait(lambda: r.all().count(b"\n") >= n, 5); time.sleep(0.05); s.stop(); r.close()
    return r.all()


def eq(a, b, what=""):
    assert a == b, f"{what}\n  got  {a[:400]!r}\n  want {b[:400]!r}"


def t_passthrough():
    d = b"".join(b"line %d\n" % i for i in range(200000)); eq(through("none", d), d)

def t_no_final_newline(): eq(through("none", b"a\nb"), b"a\nb\n")

def t_empty_lines(): eq(through("none", b"\n\nx\n\n"), b"\n\nx\n\n")

def t_many_connections():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi)
    cs = [send(pi, b"".join(b"c%d %d\n" % (k, i) for i in range(5000)), close=False) for k in range(100)]
    for c in cs: c.close()
    assert wait(lambda: r.all().count(b"\n") == 500000, 20), f"{r.all().count(b'\n')} lines"
    s.stop(); r.close()
    # Order holds within each input connection.
    for b in r.conns:
        ls = bytes(b).splitlines()
        if ls:
            k = ls[0].split()[0]; eq(ls, [k + b" %d" % i for i in range(5000)])

def t_regex():
    d = b"a CONN=123 b CONN=9\nnone here\nCONN=x CONN=7\n"
    eq(through(r"regex CONN=\d+ CONN=***", d),
       b'{"message":"a CONN=*** b CONN=***"}\n{"message":"none here"}\n{"message":"CONN=x CONN=***"}\n')

def t_json_escapes():
    d = b'q" b\\ t\t c\x01\n\xc3\xa9 ok \xff bad \xe2\x82\n'
    out = through(r"regex zzz y", d).splitlines()
    eq(json.loads(out[0])["message"], 'q" b\\ t\t c\x01')
    eq(json.loads(out[1])["message"], "é ok � bad ��")

def t_crlf(): eq(through(r"regex zzz y", b"a\r\nb\n"), b'{"message":"a\\r"}\n{"message":"b"}\n')

def t_set_field():
    o = through("set_field processed_by logxform-pipeline", b"hi \"x\"\n"); j = json.loads(o)
    eq(j["message"], 'hi "x"'); eq(j["processed_by"], "logxform-pipeline"); eq(j["source_type"], "socket"); eq(j["host"], "127.0.0.1")
    assert isinstance(j["port"], int) and j["port"] > 0 and j["timestamp"].endswith("Z") and j["timestamp"][:2] == "20"

def t_syslog_rfc3339():
    o = through("syslog", b"<13>2026-11-05T01:04:00+01:00 myhost myprog[1234]: hello world\n")
    eq(json.loads(o), {"appname": "myprog", "facility": "user", "hostname": "myhost", "message": "hello world", "procid": 1234, "severity": "notice", "timestamp": "2026-11-05T00:04:00Z"})

def t_syslog_bsd():
    o = json.loads(through("syslog", b"<34>Oct 11 22:14:15 mymachine su: 'su root' failed\n"))
    y = time.gmtime().tm_year
    eq(o, {"appname": "su", "facility": "auth", "hostname": "mymachine", "message": "'su root' failed", "severity": "crit", "timestamp": f"{y}-10-11T22:14:15Z"})

def t_syslog_5424():
    o = json.loads(through("syslog", b'<165>1 2003-10-11T22:14:15.003Z h.example.com evntslog 2 ID47 [ex@32473 a="1"] An event\n'))
    eq(o, {"appname": "evntslog", "facility": "local4", "hostname": "h.example.com", "message": "An event", "msgid": "ID47", "procid": 2, "severity": "notice", "ex@32473": {"a": "1"}, "timestamp": "2003-10-11T22:14:15.003Z", "version": 1})

def t_syslog_invalid():
    for bad in [b"no pri at all", b"<999>2026-01-01T00:00:00Z h a: m", b"<13>", b"<13>2026-13-01T00:00:00Z h a: m", b"<13>Xyz 11 22:14:15 h a: m"]:
        j = json.loads(through("syslog", bad + b"\n"))
        eq(j["message"], bad.decode()); eq(j["source_type"], "socket"); eq(j["host"], "127.0.0.1")

def t_syslog_loose():
    o = json.loads(through("syslog", b"<13>2026-11-05T01:04:00Z h no colon tag\n")); eq(o["appname"], "no"); eq(o["message"], "colon tag")
    o = json.loads(through("syslog", b"<13>2026-11-05T01:04:00Z h\n")); eq(o["hostname"], "h"); eq(o["message"], ""); assert "appname" not in o
    o = json.loads(through("syslog", b"<13>2026-11-05T01:04:00Z h p[1]:   spaced\n")); eq(o["message"], "spaced"); eq(o["procid"], 1)

def t_syslog_tag():
    o = through("syslog_tag_debug", b"<15>2026-01-01T00:00:00Z h a: dbg\n<14>2026-01-01T00:00:00Z h a: inf\n").splitlines()
    eq(json.loads(o[0])["dropped"], True); assert "dropped" not in json.loads(o[1]); eq(json.loads(o[0])["severity"], "debug")

def t_wrapped_json():
    d = b'{"ts":1,"msg":"a\\"b","n":[1,{"x":null}]}\nnot json\n{"open":\n'
    o = through("json", d).splitlines()
    eq(o[0], b'{"ts":1,"msg":"a\\"b","n":[1,{"x":null}]}'); eq(json.loads(o[1]), {"message": "not json"}); eq(json.loads(o[2]), {"message": '{"open":'})

def t_blackhole():
    pi = next(ports); s = Srv(f"source tcp {pi}\ntransform none\nsink blackhole\n", pi)
    c = send(pi, b"x" * 300 + b"\n", close=False); send(pi, b"y\n" * 2000000); time.sleep(0.2); c.close(); assert s.p.poll() is None; eq(s.stop(), 0)

def t_backpressure_and_retry():
    # The sink appears late: nothing is lost, and the sender isn't failed.
    pi, po = next(ports), next(ports); s = Srv(tcp_conf(pi, po), pi)
    d = b"".join(b"%d\n" % i for i in range(100000)); send(pi, d); time.sleep(0.5)
    r = Recv(po); assert wait(lambda: len(r.all()) == len(d)), len(r.all()); eq(r.all(), d); s.stop(); r.close()

def t_sink_restart():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi)
    c = send(pi, b"first\n", close=False); assert wait(lambda: r.all() == b"first\n"); r.close()
    for b in list(r.conns): pass
    s.p.send_signal(signal.SIGHUP); time.sleep(0.2); assert s.p.poll() is None; c.close(); s.stop()

def t_sighup():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi); c = send(pi, b"a\n", close=False)
    assert wait(lambda: b"a\n" in r.all()); s.p.send_signal(signal.SIGHUP); time.sleep(0.4); assert s.p.poll() is None
    c.sendall(b"b\n"); send(pi, b"c\n"); assert wait(lambda: r.all().count(b"\n") == 3), r.all(); c.close(); s.stop(); r.close()

def t_config_reload():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi); send(pi, b"a\n"); assert wait(lambda: r.all() == b"a\n")
    with open(s.path, "w") as f: f.write(tcp_conf(pi, po, r"regex a b"))
    s.p.send_signal(signal.SIGHUP); time.sleep(0.5); send(pi, b"a\n")
    assert wait(lambda: b'{"message":"b"}\n' in r.all()), r.all(); s.stop(); r.close()

def t_sigterm_exit():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi); eq(s.stop(), 0); r.close()

def t_long_line():
    pi, po = next(ports), next(ports); r = Recv(po); s = Srv(tcp_conf(pi, po), pi)
    d = b"s\n" + b"x" * (70 << 20) + b"\ne\n"; send(pi, d)
    assert wait(lambda: r.all().endswith(b"e\n"), 30), len(r.all()); eq(r.all(), b"s\ne\n", "over-limit line dropped"); s.stop(); r.close()

def t_line_under_limit():
    d = b"s\n" + b"x" * (10 << 20) + b"\ne\n"; eq(through("none", d), d)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"; got = []; fail_first = 0
    def do_POST(self):
        b = self.rfile.read(int(self.headers["Content-Length"]))
        if H.fail_first > 0:
            H.fail_first -= 1; self.send_response(500); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"no"); return
        H.got.append(b); self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass


def http_srv(port):
    H.got = []
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    h = socketserver.ThreadingTCPServer(("127.0.0.1", port), H); h.daemon_threads = True
    threading.Thread(target=h.serve_forever, daemon=True).start(); return h

def t_http():
    pi, po = next(ports), next(ports); h = http_srv(po); s = Srv(f"source tcp {pi}\ntransform none\nsink http 127.0.0.1 {po} /ingest\n", pi)
    d = b"".join(b"%d\n" % i for i in range(200000)); H.fail_first = 2; send(pi, d)
    assert wait(lambda: len(b"".join(H.got)) == len(d)), len(b"".join(H.got)); eq(b"".join(H.got), d); s.stop(); h.shutdown(); h.server_close()

def t_http_down_then_up():
    pi, po = next(ports), next(ports); bd = f"{TMP}/hb{pi}"; s = Srv(f"source tcp {pi}\ntransform none\nsink http 127.0.0.1 {po} /\nbuffer disk {bd}\n", pi)
    d = b"".join(b"%d\n" % i for i in range(50000)); send(pi, d); time.sleep(0.5); h = http_srv(po)
    assert wait(lambda: len(b"".join(H.got)) == len(d)); eq(b"".join(H.got), d); s.stop(); h.shutdown(); h.server_close()


def disk_conf(pi, po, bd, xf="none"): return f"source tcp {pi}\ntransform {xf}\nsink tcp 127.0.0.1 {po}\nbuffer disk {bd}\n"

def t_disk_receiver_down():
    pi, po = next(ports), next(ports); bd = f"{TMP}/b{pi}"; s = Srv(disk_conf(pi, po, bd), pi)
    d = b"".join(b"%d\n" % i for i in range(100000)); send(pi, d); time.sleep(0.5); r = Recv(po)
    assert wait(lambda: len(r.all()) == len(d)), len(r.all()); eq(r.all(), d); wait(lambda: not os.listdir(bd), 3); eq(os.listdir(bd), [], "buffer cleaned"); s.stop(); r.close()

def persist(sig):
    pi, po = next(ports), next(ports); bd = f"{TMP}/b{pi}"; s = Srv(disk_conf(pi, po, bd), pi)
    d = b"".join(b"%d\n" % i for i in range(100000)); send(pi, d); time.sleep(0.5); s.stop(sig)
    r = Recv(po); s.start(); assert wait(lambda: len(r.all()) >= len(d)), len(r.all()); eq(r.all(), d); s.stop(); r.close()

def t_disk_restart(): persist(signal.SIGTERM)
def t_disk_sigkill(): persist(signal.SIGKILL)

def t_disk_transform():
    pi, po = next(ports), next(ports); bd = f"{TMP}/b{pi}"; r = Recv(po); s = Srv(disk_conf(pi, po, bd, r"regex a b"), pi); send(pi, b"a\n")
    assert wait(lambda: r.all() == b'{"message":"b"}\n'), r.all(); s.stop(); r.close()


def file_srv(d, po, pat="input.log*"):
    os.makedirs(d, exist_ok=True)
    return Srv(f"source file {d}/{pat}\ndata_dir {d}.state\ntransform none\nsink tcp 127.0.0.1 {po}\n")

def lines(a, b): return b"".join(b"%d\n" % i for i in range(a, b))

def appendf(p, data):
    with open(p, "ab") as f: f.write(data)

def t_file_tail():
    d = f"{TMP}/f{next(ports)}"; po = next(ports); r = Recv(po); os.makedirs(d); appendf(d + "/input.log", lines(0, 1000)); s = file_srv(d, po)
    assert wait(lambda: r.all() == lines(0, 1000)); appendf(d + "/input.log", b"1000\n10"); assert wait(lambda: r.all() == lines(0, 1001)); time.sleep(0.2); eq(r.all(), lines(0, 1001), "partial line held back")
    appendf(d + "/input.log", b"01\n"); assert wait(lambda: r.all() == lines(0, 1002)); s.stop(); r.close()

def t_file_rotate_create():
    d = f"{TMP}/f{next(ports)}"; po = next(ports); r = Recv(po); os.makedirs(d); p = d + "/input.log"; appendf(p, lines(0, 1000)); s = file_srv(d, po)
    assert wait(lambda: len(r.all()) >= len(lines(0, 1000))); appendf(p, lines(1000, 1100)); os.rename(p, p + ".1"); appendf(p, lines(1100, 1200))
    assert wait(lambda: r.all().count(b"\n") == 1200), r.all().count(b"\n"); time.sleep(0.2); eq(sorted(r.all().split()), sorted(lines(0, 1200).split())); s.stop(); r.close()

def t_file_truncate():
    d = f"{TMP}/f{next(ports)}"; po = next(ports); r = Recv(po); os.makedirs(d); p = d + "/input.log"; appendf(p, lines(0, 1000)); s = file_srv(d, po)
    assert wait(lambda: len(r.all()) == len(lines(0, 1000))); time.sleep(0.05); os.truncate(p, 0); time.sleep(0.05); appendf(p, lines(1000, 1010))
    assert wait(lambda: r.all() == lines(0, 1010)), r.all()[-60:]; s.stop(); r.close()

def t_file_restart():
    d = f"{TMP}/f{next(ports)}"; po = next(ports); r = Recv(po); os.makedirs(d); p = d + "/input.log"; appendf(p, lines(0, 1000)); s = file_srv(d, po)
    assert wait(lambda: len(r.all()) == len(lines(0, 1000))); s.stop(); appendf(p, lines(1000, 1100)); os.rename(p, p + ".1"); appendf(p, lines(1100, 1200)); s.start()
    assert wait(lambda: r.all().count(b"\n") == 1200), r.all().count(b"\n"); time.sleep(0.3); eq(sorted(r.all().split()), sorted(lines(0, 1200).split()), "no duplicates or loss"); s.stop(); r.close()

def t_file_exact_name():
    d = f"{TMP}/f{next(ports)}"; po = next(ports); r = Recv(po); os.makedirs(d); p = d + "/input.log"; appendf(p, lines(0, 10)); s = file_srv(d, po, "input.log")
    assert wait(lambda: r.all() == lines(0, 10)); shutil.copy(p, p + ".1"); os.truncate(p, 0); time.sleep(0.05); appendf(p, lines(10, 20))
    assert wait(lambda: r.all() == lines(0, 20)), r.all(); time.sleep(0.2); eq(r.all(), lines(0, 20), "a copy isn't read again"); s.stop(); r.close()

def t_bad_config():
    p = f"{TMP}/bad.conf"; open(p, "w").write("nonsense here\n"); eq(subprocess.run([BIN, "--config", p], stderr=subprocess.DEVNULL).returncode, 2)
    eq(subprocess.run([BIN], stderr=subprocess.DEVNULL).returncode, 2)


tests = [(k[2:], v) for k, v in list(globals().items()) if k.startswith("t_")]
for name, fn in tests:
    if ONLY and name not in ONLY: continue
    t0 = time.time()
    try: fn(); print(f"ok   {name} ({time.time() - t0:.1f}s)", flush=True)
    except BaseException as e: fails.append(name); print(f"FAIL {name}: {str(e)[:600]}", flush=True)
shutil.rmtree(TMP, ignore_errors=True)
print(f"{'FAILED ' + str(fails) if fails else 'all passed'}"); sys.exit(1 if fails else 0)
