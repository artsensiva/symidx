import os
import re
import sys

MONTHS = {m: i + 1 for i, m in enumerate(b"Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}
MON_RE = b"|".join(MONTHS)

HDFS_RE = re.compile(rb"(\d\d)(\d\d)(\d\d) (\d\d)(\d\d)(\d\d) (\d+) (TRACE|DEBUG|INFO|WARN|ERROR|FATAL) ")
SSH_RE = re.compile(rb"(" + MON_RE + rb") ( \d|\d\d) (\d\d):(\d\d):(\d\d) ([^ ]+) ([^ \[]+)\[(\d+)\]: ")
APACHE_RE = re.compile(rb"\[(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (" + MON_RE + rb") (\d\d) (\d\d):(\d\d):(\d\d) (\d{4})\] "
                       rb"\[(emerg|alert|crit|error|warn|notice|info|debug)\] ")
APACHE_LEVEL = {b"emerg": b"FATAL", b"alert": b"FATAL", b"crit": b"FATAL", b"error": b"ERROR",
                b"warn": b"WARN", b"notice": b"NOTICE", b"info": b"INFO", b"debug": b"DEBUG"}

RANK = {b"TRACE": 0, b"DEBUG": 1, b"INFO": 2, b"NOTICE": 3, b"WARN": 4, b"ERROR": 5, b"FATAL": 6}
SEV = {b"FATAL": 2, b"ERROR": 3, b"WARN": 4, b"NOTICE": 5, b"INFO": 6, b"DEBUG": 7, b"TRACE": 7}
MIN_LEVEL = {b"dfs.DataNode$PacketResponder": RANK[b"WARN"], b"dfs.FSDataset": RANK[b"WARN"]}
DEFAULT_MIN = RANK[b"INFO"]

RUN_RE = re.compile(rb"(?<![0-9.])[0-9][0-9.]*")
IP_RE = re.compile(rb"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}")
BLK_RE = re.compile(rb"blk_-?[0-9]+")
KEY_RE = re.compile(rb"[A-Za-z0-9_.-]+")
ESC_RE = re.compile(rb'[\x00-\x1f"\\]')
SHORT = {0x22: b'\\"', 0x5C: b"\\\\", 0x08: b"\\b", 0x0C: b"\\f", 0x0A: b"\\n", 0x0D: b"\\r", 0x09: b"\\t"}


def ts_of(y, mo, d, h, mi, s):
    """RFC 3339 UTC, or None when a field is out of range (SPEC "Timestamp ranges")."""
    if not (1 <= mo <= 12 and 1 <= d <= 31 and h <= 23 and mi <= 59 and s <= 59):
        return None
    return b"%04d-%02d-%02dT%02d:%02d:%02dZ" % (y, mo, d, h, mi, s)


def parse_hdfs(line):
    m = HDFS_RE.match(line)
    if not m:
        return None
    g = m.groups()
    ts = ts_of(2000 + int(g[0]), int(g[1]), int(g[2]), int(g[3]), int(g[4]), int(g[5]))
    rest = line[m.end():]
    i = rest.find(b": ")
    if ts is None or i <= 0 or b" " in rest[:i]:
        return None
    comp, msg = rest[:i], rest[i + 2:]
    pairs = [(b"pid", g[6])]
    for tok in msg.split(b" "):
        if tok.startswith(b"blk_"):
            b = BLK_RE.match(tok)
            if b:
                pairs.append((b"blk", b.group()))
            break
    return ts, g[7], comp, msg, pairs


def parse_ssh(line):
    m = SSH_RE.match(line)
    if not m:
        return None
    mon, day, h, mi, s, host, prog, pid = m.groups()
    mo = MONTHS[mon]
    ts = ts_of(2017 if mo >= 7 else 2018, mo, int(day), int(h), int(mi), int(s))
    if ts is None:
        return None
    msg = line[m.end():]
    if msg.startswith(b"error: "):
        level = b"ERROR"
    elif msg.startswith(b"fatal: "):
        level = b"FATAL"
    elif msg.startswith((b"Failed ", b"Invalid user ", b"reverse mapping ")):
        level = b"WARN"
    else:
        level = b"INFO"
    return ts, level, prog, msg, [(b"host", host), (b"pid", pid)]


def parse_apache(line):
    m = APACHE_RE.match(line)
    if not m:
        return None
    mon, d, h, mi, s, y, lv = m.groups()
    ts = ts_of(int(y), MONTHS[mon], int(d), int(h), int(mi), int(s))
    if ts is None:
        return None
    return ts, APACHE_LEVEL[lv], b"httpd", line[m.end():], []


PARSERS = {"hdfs": parse_hdfs, "ssh": parse_ssh, "apache": parse_apache}


def redact_run(m):
    run = m.group()
    core = run.rstrip(b".")
    if IP_RE.fullmatch(core):
        return b"<ip>" + run[len(core):]
    return run


def esc(s):
    if not ESC_RE.search(s):
        return s
    out = bytearray()
    for c in s:
        if c in SHORT:
            out += SHORT[c]
        elif c < 0x20:
            out += b"\\u%04x" % c
        else:
            out.append(c)
    return bytes(out)


def render(ts, level, comp, msg, kv):
    parts = [b'{"ts":"', ts, b'","level":"', level, b'","sev":', b"%d" % SEV[level],
             b',"component":"', esc(comp), b'","msg":"', esc(msg), b'","kv":{']
    first = True
    for k, v in kv.items():
        if not first:
            parts.append(b",")
        first = False
        parts += [b'"', esc(k), b'":"', esc(v), b'"']
    parts.append(b"}}\n")
    return b"".join(parts)


def usage():
    sys.stderr.write("usage: sanitize.py [--out FILE] [--rejects FILE] [--max-reject-rate R] FORMAT PATH [FORMAT PATH ...]\n")
    sys.exit(2)


def run(pairs, out, rejects):
    lines = kept = dropped = malformed = 0
    for fmt, path in pairs:
        parse = PARSERS[fmt]
        buf = []
        f = sys.stdin.buffer if path == "-" else open(path, "rb")
        for raw in f:
            line = raw[:-1] if raw.endswith(b"\n") else raw
            bad = line
            if line.endswith(b"\r"):
                line = line[:-1]
            lines += 1
            r = parse(line)
            if r is None:
                malformed += 1
                if rejects:
                    rejects.write(bad + b"\n")
                continue
            ts, level, comp, msg, pairs_ = r
            if RANK[level] < MIN_LEVEL.get(comp, DEFAULT_MIN):
                dropped += 1
                continue
            kept += 1
            msg = RUN_RE.sub(redact_run, msg)
            kv = dict(pairs_)
            for tok in msg.split(b" "):
                p = tok.find(b"=")
                if p >= 1 and KEY_RE.fullmatch(tok[:p]):
                    kv[tok[:p]] = tok[p + 1:]
            buf.append(render(ts, level, comp, msg, kv))
            if len(buf) >= 65536:
                out.write(b"".join(buf))
                buf = []
        out.write(b"".join(buf))
        if path != "-":
            f.close()
    return lines, kept, dropped, malformed


def main(argv):
    out_path = rejects_path = None
    max_rate = None
    while argv and argv[0].startswith("--"):
        if len(argv) < 2:
            usage()
        if argv[0] == "--out":
            out_path = argv[1]
        elif argv[0] == "--rejects":
            rejects_path = argv[1]
        elif argv[0] == "--max-reject-rate":
            try:
                max_rate = float(argv[1])
            except ValueError:
                usage()
        else:
            usage()
        argv = argv[2:]
    if not argv or len(argv) % 2 or any(f not in PARSERS for f in argv[0::2]):
        usage()
    tmp = None
    try:
        rejects = open(rejects_path, "wb") if rejects_path else None
        if out_path:
            tmp = out_path + ".tmp"
            out = open(tmp, "wb")
        else:
            out = sys.stdout.buffer
        lines, kept, dropped, malformed = run(list(zip(argv[0::2], argv[1::2])), out, rejects)
        out.flush()
        if rejects:
            rejects.close()
    except OSError as e:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
        sys.stderr.write("sanitize: %s\n" % e)
        try:
            sys.stdout = None
            os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
        except OSError:
            pass
        sys.exit(3)
    sys.stderr.write("lines=%d kept=%d dropped=%d malformed=%d\n" % (lines, kept, dropped, malformed))
    if max_rate is not None and lines and malformed / lines > max_rate:
        if tmp:
            out.close()
            os.unlink(tmp)
        sys.stderr.write("sanitize: reject rate %.6f exceeds %s\n" % (malformed / lines, max_rate))
        sys.exit(1)
    if tmp:
        out.close()
        os.replace(tmp, out_path)


if __name__ == "__main__":
    main(sys.argv[1:])
