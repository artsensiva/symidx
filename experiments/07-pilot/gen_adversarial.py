#!/usr/bin/env python3
"""Adversarial test data for the pilot, each case with its expected results (SPEC A2).

usage: gen_adversarial.py OUT_DIR [--change | --change-ascii]
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


# With --change-ascii, kept lines with bytes above 127, or with no final newline, are left out. So tools that can't keep those bytes,
# which is already recorded, still get checked on everything else, since a first failure hides the rest of a case.
ASCII_ONLY = "--change-ascii" in sys.argv


class Case:
    def __init__(self, name, fmt):
        self.name, self.fmt = name, fmt
        self.input = bytearray()
        self.expected = bytearray()
        self.rejects = bytearray()
        self.lines = self.kept = self.dropped = self.malformed = 0

    def kept_line(self, line, out, end=b"\n"):
        if ASCII_ONLY:
            if max(line, default=0) > 127:
                return
            end = end or b"\n"
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


# The change request (SPEC A6). Generated only with --change, beside the base cases, so the base oracle stays as it was.
B_DT = b"2005-06-03-15.42.50.363779"
B_ISO = b"2005-06-03T15:42:50Z"
BGL_LEVELS = ((b"INFO", b"INFO"), (b"WARNING", b"WARN"), (b"ERROR", b"ERROR"), (b"SEVERE", b"ERROR"), (b"FATAL", b"FATAL"), (b"FAILURE", b"FATAL"))


def bgl(msg, comp=b"KERNEL", level=b"INFO", label=b"-", node=b"R02-M1", node2=b"R02-M1", typ=b"RAS", dt=B_DT, epoch=b"1117838570", date=b"2005.06.03"):
    head = [label, epoch, date, node, dt]
    if node2 is not None:
        head.append(node2)
    line = b" ".join(head + [typ, comp, level])
    return line if msg is None else line + b" " + msg


def bgl_rec(msg, comp=b"KERNEL", level=b"INFO", node=b"R02-M1", alert=None, kv=()):
    base = [(b"node", node)] + ([(b"alert", alert)] if alert else [])
    return record(B_ISO, level, comp, b"" if msg is None else msg, base + list(kv))


def change_bgl():
    c = Case("change_bgl", "bgl")
    for raw, mapped in BGL_LEVELS:
        c.kept_line(bgl(b"a message", level=raw), bgl_rec(b"a message", level=mapped))
    # An empty message: the line ends at the level, or a space follows it.
    c.kept_line(bgl(None, level=b"FATAL"), bgl_rec(None, level=b"FATAL"))
    c.kept_line(bgl(b"", level=b"FATAL"), bgl_rec(b"", level=b"FATAL"))
    c.kept_line(bgl(b"m", label=b"KERNDTLB"), bgl_rec(b"m", alert=b"KERNDTLB"))
    c.kept_line(bgl(b"m", typ=b"NULL"), bgl_rec(b"m"))
    # NODE2 absent only when NODE is -, and the next token is a type.
    for t in (b"RAS", b"NULL"):
        c.kept_line(bgl(b"Kill job 1", node=b"-", node2=None, typ=t, level=b"FATAL"), bgl_rec(b"Kill job 1", node=b"-", level=b"FATAL"))
    c.kept_line(bgl(b"m", node=b"-", node2=b"X"), bgl_rec(b"m", node=b"-"))
    c.bad_line(bgl(b"m", node2=None))
    c.bad_line(bgl(b"m", node=b"-", node2=b"RAS"))
    # The filter: APP only, exact, after mapping; and the base spec's per-component minimums still apply.
    for raw, mapped, keep in ((b"INFO", b"INFO", False), (b"WARNING", b"WARN", False), (b"ERROR", b"ERROR", True), (b"SEVERE", b"ERROR", True), (b"FATAL", b"FATAL", True), (b"FAILURE", b"FATAL", True)):
        if keep:
            c.kept_line(bgl(b"m", comp=b"APP", level=raw), bgl_rec(b"m", comp=b"APP", level=mapped))
        else:
            c.dropped_line(bgl(b"m", comp=b"APP", level=raw))
    for comp in (b"app", b"APPX", b"XAPP"):
        c.kept_line(bgl(b"m", comp=comp), bgl_rec(b"m", comp=comp))
    c.dropped_line(bgl(b"m", comp=b"dfs.FSDataset"))
    c.kept_line(bgl(b"m", comp=b"dfs.FSDataset", level=b"WARNING"), bgl_rec(b"m", comp=b"dfs.FSDataset", level=b"WARN"))
    # Message pairs, redaction, and pairs overriding the format's, keeping position.
    c.kept_line(bgl(b"a=1 src=1.2.3.4 iar=0x00544eb8"), bgl_rec(b"a=1 src=<ip> iar=<hex>", kv=[(b"a", b"1"), (b"src", b"<ip>"), (b"iar", b"<hex>")]))
    c.kept_line(bgl(b"node=mine z=1", label=b"AL"), record(B_ISO, b"INFO", b"KERNEL", b"node=mine z=1", [(b"node", b"mine"), (b"alert", b"AL"), (b"z", b"1")]))
    c.kept_line(bgl(b"alert=mine"), bgl_rec(b"alert=mine", kv=[(b"alert", b"mine")]))
    c.kept_line(bgl(b"two  spaces \"q\" \\"), bgl_rec(b"two  spaces \"q\" \\"))
    # Fields that aren't checked, and bytes in fields that aren't output.
    c.kept_line(bgl(b"m", epoch=b"0", date=b"1999.13.40"), bgl_rec(b"m"))
    c.kept_line(bgl(b"m", node2=b"\x0f.\xc2\xb2\xff"), bgl_rec(b"m"))
    c.kept_line(bgl(b"bad \xff byte k=\xfe"), bgl_rec(b"bad \xff byte k=\xfe", kv=[(b"k", b"\xfe")]))
    c.kept_line(bgl(b"m", node=b"\xff\"n"), bgl_rec(b"m", node=b"\xff\"n"))
    # Malformed.
    for bad in (bgl(b"m", level=b"TRACE"), bgl(b"m", level=b"WARN"), bgl(b"m", level=b"info"), bgl(b"m", typ=b"X"), bgl(b"m", epoch=b"12a"), bgl(b"m", epoch=b""),
                bgl(b"m", date=b"2005-06-03"), bgl(b"m", date=b"2005.6.03"), bgl(b"m", date=b"2005.06.0x"), bgl(b"m", dt=b"2005-13-03-15.42.50.363779"),
                bgl(b"m", dt=b"2005-00-03-15.42.50.363779"), bgl(b"m", dt=b"2005-06-32-15.42.50.363779"), bgl(b"m", dt=b"2005-06-00-15.42.50.363779"),
                bgl(b"m", dt=b"2005-06-03-24.42.50.363779"), bgl(b"m", dt=b"2005-06-03-15.60.50.363779"), bgl(b"m", dt=b"2005-06-03-15.42.60.363779"),
                bgl(b"m", dt=b"2005-06-03-15.42.50.36377"), bgl(b"m", dt=b"2005-06-03-15.42.50.3637790"), bgl(b"m", dt=b"2005-06-03-15.42.50"),
                bgl(b"m", dt=b"2005-06-03 15.42.50.363779"), bgl(b"m", dt=b"2005-06-03-15:42:50.363779"), bgl(b"m", dt=b"2005-06-03-15.42.50.36377x"),
                bgl(b"m", label=b""), bgl(b"m", node=b""), bgl(b"m", node2=b""), bgl(b"m", comp=b""), b"", b"-", b"- 1117838570 2005.06.03 R02-M1",
                bgl(None, level=b""), b"- 1117838570 2005.06.03 - 2005-12-01-06.37.41.417709 time for a single RAS KERNEL INFO 0 microseconds"):
        c.bad_line(bad)
    c.bad_line(bgl(b"m").replace(b" ", b"\t", 1))
    c.kept_line(bgl(b"last"), bgl_rec(b"last"), end=b"")
    return c


def change_bgl_crlf():
    c = Case("change_bgl_crlf", "bgl")
    c.kept_line(bgl(b"m"), bgl_rec(b"m"), end=b"\r\n")
    c.kept_line(bgl(None), bgl_rec(None), end=b"\r\n")
    c.bad_line(bgl(b"m", typ=b"X"), end=b"\r\n")
    c.dropped_line(bgl(b"m", comp=b"APP"), end=b"\r\n")
    return c


HEX_CASES = (
    (b"0x00544eb8,", b"<hex>,", []), (b"0x00544EB8", b"<hex>", []), (b"iar=0x00544eb8", b"iar=<hex>", [(b"iar", b"<hex>")]),
    (b"0x123456789", None, []), (b"0x1234567", None, []), (b"a0x12345678", None, []), (b"00x12345678", None, []), (b"0X12345678", None, []),
    (b"0x1234567g", None, []), (b"0x12345678g", None, []), (b"0x0x12345678", None, []), (b"0x123456780x12345678", None, []),
    (b"_0x12345678", b"_<hex>", []), (b"(0x12345678)", b"(<hex>)", []), (b"0x12345678 0xabcdef01", b"<hex> <hex>", []), (b"0x12345678-0xABCDEF01", b"<hex>-<hex>", []),
    (b"at 0x12345678", b"at <hex>", []), (b"1.2.3.4 0x12345678", b"<ip> <hex>", []), (b"1.2.3.0x12345678", b"<ip>x12345678", []), (b"0x12.3.4.5", b"0x<ip>", []),
    (b"\xff0x12345678\xff", b"\xff<hex>\xff", []), (b"x=0x12345678,y=2", b"x=<hex>,y=2", [(b"x", b"<hex>,y=2")]), (b"=0x12345678", b"=<hex>", []),
)


def change_hex():
    h, s, a, b = Case("change_hex_hdfs", "hdfs"), Case("change_hex_ssh", "ssh"), Case("change_hex_apache", "apache"), Case("change_hex_bgl", "bgl")
    for raw, red, kv in HEX_CASES:
        red = raw if red is None else red
        h.kept_line(hdfs(raw), hdfs_rec(red, kv=kv))
        s.kept_line(ssh(raw), ssh_rec(red, kv=kv))
        a.kept_line(apache(raw), apache_rec(red, kv=kv))
        b.kept_line(bgl(raw), bgl_rec(red, kv=kv))
    # Only msg is redacted, not other fields.
    s.kept_line(ssh(b"m", host=b"0x12345678"), ssh_rec(b"m", host=b"0x12345678"))
    h.kept_line(hdfs(b"m", comp=b"0x12345678"), hdfs_rec(b"m", comp=b"0x12345678"))
    b.kept_line(bgl(b"m", node=b"0x12345678", label=b"0x12345678"), bgl_rec(b"m", node=b"0x12345678", alert=b"0x12345678"))
    # In other formats APP is an ordinary component.
    s.kept_line(ssh(b"m", prog=b"APP"), ssh_rec(b"m", prog=b"APP"))
    h.kept_line(hdfs(b"m", comp=b"APP"), hdfs_rec(b"m", comp=b"APP"))
    return [h, s, a, b]


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    cases = [escape_heavy(), long_lines(), invalid_utf8(), empty(), only_newlines(), no_newline(), crlf(), levels(), hdfs_fields(), ssh_fields(), apache_fields(), redaction(), pairs(), format_pairs()] + filtered()
    if "--change" in sys.argv[2:] or ASCII_ONLY:
        cases += [change_bgl(), change_bgl_crlf()] + change_hex()
    for c in cases:
        c.write(d)
    print(f"{len(cases)} cases in {d}")


main()
