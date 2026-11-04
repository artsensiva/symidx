#!/usr/bin/env python3
"""Adversarial test data for the pilot, each case with its expected results (SPEC A2).

usage: gen_adversarial.py OUT_DIR
Writes, for each case: NAME.FORMAT (input), NAME.expected (stdout), NAME.rejects, NAME.summary. Deterministic.

This is the oracle, so it must not share a parser with the programs under test. It parses nothing: every line is assembled from
known parts, and its expected output is assembled from the same parts by the separate writer below. Every expectation is stated
as data. If a program and this file disagree, one of them misreads the spec, and a person has to decide which.
"""
import os
import random
import sys

HEX = b"0123456789abcdef"
SHORT = {0x22: b'\\"', 0x5c: b"\\\\", 0x08: b"\\b", 0x0c: b"\\f", 0x0a: b"\\n", 0x0d: b"\\r", 0x09: b"\\t"}
SEVERITY = {b"FATAL": 2, b"ERROR": 3, b"WARN": 4, b"NOTICE": 5, b"INFO": 6, b"DEBUG": 7, b"TRACE": 7}


def j(s):
    out = bytearray(b'"')
    for c in s:
        if c in SHORT:
            out += SHORT[c]
        elif c < 0x20:
            out += b"\\u00" + bytes([HEX[c >> 4], HEX[c & 15]])
        else:
            out.append(c)
    return bytes(out) + b'"'


def record(ts, level, comp, msg, kv):
    pairs = b",".join(j(k) + b":" + j(v) for k, v in kv)
    return b'{"ts":"' + ts + b'","level":"' + level + b'","sev":' + str(SEVERITY[level]).encode() + b',"component":' + j(comp) + b',"msg":' + j(msg) + b',"kv":{' + pairs + b"}}\n"


class Case:
    def __init__(self, name, fmt):
        self.name, self.fmt = name, fmt
        self.input = bytearray()
        self.expected = bytearray()
        self.rejects = bytearray()
        self.lines = self.kept = self.dropped = self.malformed = 0

    def kept_line(self, line, out, end=b"\n"):
        self.input += line + end
        self.expected += out
        self.lines += 1
        self.kept += 1

    def dropped_line(self, line, end=b"\n"):
        self.input += line + end
        self.lines += 1
        self.dropped += 1

    def bad_line(self, line, end=b"\n"):
        self.input += line + end
        self.rejects += line + (b"\r" if end == b"\r\n" else b"") + b"\n"
        self.lines += 1
        self.malformed += 1

    def write(self, d):
        base = os.path.join(d, self.name)
        for suffix, data in (("." + self.fmt, self.input), (".expected", self.expected), (".rejects", self.rejects)):
            with open(base + suffix, "wb") as f:
                f.write(data)
        with open(base + ".summary", "w") as f:
            f.write(f"lines={self.lines} kept={self.kept} dropped={self.dropped} malformed={self.malformed}\n")


H_TS = b"081109 203518 "
H_ISO = b"2008-11-09T20:35:18Z"


def hdfs(msg, comp=b"dfs.X", level=b"INFO", pid=b"143"):
    return H_TS + pid + b" " + level + b" " + comp + b": " + msg


def hdfs_rec(msg, comp=b"dfs.X", level=b"INFO", pid=b"143", kv=()):
    return record(H_ISO, level, comp, msg, [(b"pid", pid)] + list(kv))


def ssh(msg, host=b"LabSZ", prog=b"sshd", pid=b"7"):
    return b"Dec 10 06:55:46 " + host + b" " + prog + b"[" + pid + b"]: " + msg


def ssh_rec(msg, level=b"INFO", host=b"LabSZ", prog=b"sshd", pid=b"7", kv=()):
    return record(b"2017-12-10T06:55:46Z", level, prog, msg, [(b"host", host), (b"pid", pid)] + list(kv))


def apache(msg, l=b"error"):
    return b"[Sun Dec 04 04:47:44 2005] [" + l + b"] " + msg


def apache_rec(msg, level=b"ERROR", kv=()):
    return record(b"2005-12-04T04:47:44Z", level, b"httpd", msg, list(kv))


def escape_heavy():
    c = Case("escape_heavy", "hdfs")
    r = random.Random(1)
    alphabet = [b'"', b"\\", b"\t", b"\x01", b"\x1f", b"\x08", b"\x0c", b"\x7f", b"a", b"z"]
    for _ in range(200000):
        msg = b"".join(r.choice(alphabet) for _ in range(r.randrange(30, 180)))
        c.kept_line(hdfs(msg), hdfs_rec(msg))
    return c


def long_lines():
    c = Case("long_lines", "hdfs")
    for n in (70000, 1 << 20, (1 << 20) + 1, 3 << 20, 8 << 20):
        msg = (b"x" * 63 + b" ") * (n // 64)
        c.kept_line(hdfs(msg), hdfs_rec(msg))
        c.kept_line(hdfs(b"between"), hdfs_rec(b"between"))
    c.bad_line(b"z" * (2 << 20))
    return c


def invalid_utf8():
    c = Case("invalid_utf8", "ssh")
    for b in range(0x80, 0x100):
        msg = b"bad " + bytes([b]) + b" byte k=" + bytes([b, b])
        c.kept_line(ssh(msg), ssh_rec(msg, kv=[(b"k", bytes([b, b]))]))
    return c


def empty():
    return Case("empty", "hdfs")


def only_newlines():
    c = Case("only_newlines", "ssh")
    for _ in range(3):
        c.bad_line(b"")
    return c


def no_newline():
    c = Case("no_newline", "apache")
    c.kept_line(apache(b"first"), apache_rec(b"first"))
    c.kept_line(apache(b"final, no newline"), apache_rec(b"final, no newline"), end=b"")
    return c


def crlf():
    c = Case("crlf", "ssh")
    c.kept_line(ssh(b"one CR"), ssh_rec(b"one CR"), end=b"\r\n")
    c.kept_line(ssh(b"two CRs\r"), ssh_rec(b"two CRs\r"), end=b"\r\n")
    c.kept_line(ssh(b"CR in\rthe middle"), ssh_rec(b"CR in\rthe middle"))
    c.bad_line(b"not a line", end=b"\r\n")
    return c


def filtered():
    a = Case("mostly_filtered", "hdfs")
    r = random.Random(2)
    for i in range(100000):
        if r.random() < 0.99:
            a.dropped_line(hdfs(b"noise %d" % i, comp=b"dfs.FSDataset"))
        else:
            a.kept_line(hdfs(b"kept %d" % i, comp=b"dfs.FSDataset", level=b"WARN"), hdfs_rec(b"kept %d" % i, comp=b"dfs.FSDataset", level=b"WARN"))
    b = Case("nothing_filtered", "hdfs")
    for i in range(100000):
        b.kept_line(hdfs(b"kept %d" % i), hdfs_rec(b"kept %d" % i))
    return [a, b]


def levels():
    c = Case("levels", "hdfs")
    for level, keep in ((b"TRACE", 0), (b"DEBUG", 0), (b"INFO", 1), (b"WARN", 1), (b"ERROR", 1), (b"FATAL", 1)):
        (c.kept_line(hdfs(b"m", level=level), hdfs_rec(b"m", level=level)) if keep else c.dropped_line(hdfs(b"m", level=level)))
    for comp in (b"dfs.DataNode$PacketResponder", b"dfs.FSDataset"):
        c.dropped_line(hdfs(b"m", comp=comp))
        c.kept_line(hdfs(b"m", comp=comp, level=b"WARN"), hdfs_rec(b"m", comp=comp, level=b"WARN"))
    return c


def hdfs_fields():
    c = Case("hdfs_fields", "hdfs")
    for bad in (b"", b"081109 203518 143 INFO dfs.X", b"081109 203518 143 INFO : empty component", b"081109 203518 143 INFO a b: space in component",
                b"081109 203518 143 NOTICE dfs.X: not an hdfs level", b"081109 203518 143 info dfs.X: lower case", b"081109 203518 x INFO dfs.X: pid", b"081109  203518 143 INFO dfs.X: two spaces",
                b"081309 203518 143 INFO dfs.X: month 13", b"080009 203518 143 INFO dfs.X: month 0", b"081100 203518 143 INFO dfs.X: day 0", b"081132 203518 143 INFO dfs.X: day 32",
                b"081109 243518 143 INFO dfs.X: hour 24", b"081109 206018 143 INFO dfs.X: minute 60", b"081109 203560 143 INFO dfs.X: second 60", b"08110 203518 143 INFO dfs.X: short date"):
        c.bad_line(bad)
    c.kept_line(b"081131 235959 1 INFO a:b: colon in component", record(b"2008-11-31T23:59:59Z", b"INFO", b"a:b", b"colon in component", [(b"pid", b"1")]))
    c.kept_line(hdfs(b""), hdfs_rec(b""))
    c.kept_line(b"000101 000000 0 INFO c: m", record(b"2000-01-01T00:00:00Z", b"INFO", b"c", b"m", [(b"pid", b"0")]))
    return c


def ssh_fields():
    c = Case("ssh_fields", "ssh")
    for bad in (b"", b"Foo 10 06:55:46 h p[1]: bad month", b"dec 10 06:55:46 h p[1]: lower month", b"Dec 00 06:55:46 h p[1]: day 0", b"Dec 32 06:55:46 h p[1]: day 32", b"Dec  0 06:55:46 h p[1]: space then 0",
                b"Dec 10 24:55:46 h p[1]: hour", b"Dec 10 06:60:46 h p[1]: minute", b"Dec 10 06:55:60 h p[1]: second", b"Dec 10 06:55:46 h p[]: empty pid", b"Dec 10 06:55:46 h p[x]: pid", b"Dec 10 06:55:46 h [1]: empty prog",
                b"Dec 10 06:55:46  p[1]: empty host", b"Dec 10 06:55:46 h p[1] no colon", b"Dec 10 06:55:46 h p[1]:no space"):
        c.bad_line(bad)
    r = lambda ts, m, **k: c.kept_line(ts, ssh_rec(m, **k))
    c.kept_line(b"Jan  5 01:02:03 h p[1]: space day", record(b"2018-01-05T01:02:03Z", b"INFO", b"p", b"space day", [(b"host", b"h"), (b"pid", b"1")]))
    c.kept_line(b"Jun 30 01:02:03 h p[1]: june is 2018", record(b"2018-06-30T01:02:03Z", b"INFO", b"p", b"june is 2018", [(b"host", b"h"), (b"pid", b"1")]))
    c.kept_line(b"Jul 01 01:02:03 h p[1]: july is 2017", record(b"2017-07-01T01:02:03Z", b"INFO", b"p", b"july is 2017", [(b"host", b"h"), (b"pid", b"1")]))
    for msg, level in ((b"error: x", b"ERROR"), (b"fatal: x", b"FATAL"), (b"Failed x", b"WARN"), (b"Invalid user x", b"WARN"), (b"reverse mapping x", b"WARN"), (b"Failed", b"INFO"), (b"error:x", b"INFO"), (b"x error: y", b"INFO"), (b"", b"INFO")):
        r(ssh(msg), msg, level=level)
    return c


def apache_fields():
    c = Case("apache_fields", "apache")
    for bad in (b"", b"[Foo Dec 04 04:47:44 2005] [error] weekday", b"[Sun Foo 04 04:47:44 2005] [error] month", b"[Sun Dec 00 04:47:44 2005] [error] day 0", b"[Sun Dec 32 04:47:44 2005] [error] day 32",
                b"[Sun Dec  4 04:47:44 2005] [error] space day", b"[Sun Dec 04 24:47:44 2005] [error] hour", b"[Sun Dec 04 04:60:44 2005] [error] minute", b"[Sun Dec 04 04:47:60 2005] [error] second",
                b"[Sun Dec 04 04:47:44 05] [error] short year", b"[Sun Dec 04 04:47:44 2005] [nope] level", b"[Sun Dec 04 04:47:44 2005] [error]", b"[Sun Dec 04 04:47:44 2005]  [error] two spaces", b"no timestamp"):
        c.bad_line(bad)
    for l, level in ((b"emerg", b"FATAL"), (b"alert", b"FATAL"), (b"crit", b"FATAL"), (b"error", b"ERROR"), (b"warn", b"WARN"), (b"notice", b"NOTICE"), (b"info", b"INFO")):
        c.kept_line(apache(b"m", l=l), apache_rec(b"m", level=level))
    c.dropped_line(apache(b"m", l=b"debug"))
    c.kept_line(apache(b""), apache_rec(b""))
    return c


def redaction():
    c = Case("redaction", "apache")
    for raw, red in ((b"10.250.19.102", b"<ip>"), (b"/10.250.19.102:54106", b"/<ip>:54106"), (b"74.82.254.191.ifibertv.com", b"<ip>.ifibertv.com"), (b"1.2.3.4.5", b"1.2.3.4.5"), (b"1.2.3", b"1.2.3"),
                     (b"1.2.3.4...", b"<ip>..."), (b"x1.2.3.4y", b"x<ip>y"), (b".1.2.3.4", b".1.2.3.4"), (b"1234.2.3.4", b"1234.2.3.4"), (b"1.2.3.1234", b"1.2.3.1234"), (b"1..2.3.4", b"1..2.3.4"),
                     (b"1.2.3.4 5.6.7.8", b"<ip> <ip>"), (b"1.2.3.4,5.6.7.8,9.9.9.9", b"<ip>,<ip>,<ip>"), (b"999.999.999.999", b"<ip>"), (b"blk_-160899", b"blk_-160899"), (b"a.b.c.d", b"a.b.c.d"), (b"-1.2.3.4", b"-<ip>")):
        c.kept_line(apache(raw), apache_rec(red))
    return c


def pairs():
    c = Case("pairs", "apache")
    for raw, kv in ((b"a=1 b=2", [(b"a", b"1"), (b"b", b"2")]), (b"a=1 b=2 a=3", [(b"a", b"3"), (b"b", b"2")]), (b"=x", []), (b"a=", [(b"a", b"")]), (b"a=b=c", [(b"a", b"b=c")]),
                    (b"a b=1", [(b"b", b"1")]), (b"a!=1", []), (b"a.b-c_d9=v", [(b"a.b-c_d9", b"v")]), (b"  a=1  ", [(b"a", b"1")]), (b"\ta=1", []), (b'k="v"', [(b"k", b'"v"')]), (b"p=\\", [(b"p", b"\\")])):
        c.kept_line(apache(raw), apache_rec(raw, kv=kv))
    # Pairs are taken after redaction, and message pairs override the format's, keeping its position.
    c.kept_line(apache(b"src=1.2.3.4"), apache_rec(b"src=<ip>", kv=[(b"src", b"<ip>")]))
    c.input += b""
    return c


def format_pairs():
    c = Case("format_pairs", "hdfs")
    for raw, extra in ((b"blk_123 x", [(b"blk", b"blk_123")]), (b"x blk_-5 y", [(b"blk", b"blk_-5")]), (b"blk_-12a", [(b"blk", b"blk_-12")]), (b"blk_", []), (b"blk_-", []), (b"blk_x", []),
                       (b"xblk_1", []), (b"blk_ blk_5", []), (b"blk_1 blk_2", [(b"blk", b"blk_1")])):
        c.kept_line(hdfs(raw), hdfs_rec(raw, kv=extra))
    c.kept_line(hdfs(b"pid=9 z=1"), record(H_ISO, b"INFO", b"dfs.X", b"pid=9 z=1", [(b"pid", b"9"), (b"z", b"1")]))
    c.kept_line(hdfs(b"blk_7 blk=mine"), record(H_ISO, b"INFO", b"dfs.X", b"blk_7 blk=mine", [(b"pid", b"143"), (b"blk", b"mine")]))
    return c


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    cases = [escape_heavy(), long_lines(), invalid_utf8(), empty(), only_newlines(), no_newline(), crlf(), levels(), hdfs_fields(), ssh_fields(), apache_fields(), redaction(), pairs(), format_pairs()] + filtered()
    for c in cases:
        c.write(d)
    print(f"{len(cases)} cases in {d}")


main()
