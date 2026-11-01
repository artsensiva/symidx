#!/usr/bin/env python3
"""Reference implementation of symidx (see bench/SPEC.md). Used only for checksums, not for benchmarks.

    ref.py <dir> [prefix]   -> prints the `find` result over the index of <dir> in SPEC format
"""
import os
import sys

WS = b" \t"
IDENT = set(b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") | set(range(0x80, 0x100))


def skip_ws(line, i):
    while i < len(line) and line[i] in WS:
        i += 1
    return i


def parse_line(line):
    i = skip_ws(line, 0)
    if line.startswith(b"async", i) and i + 5 < len(line) and line[i + 5] in WS:
        i = skip_ws(line, i + 5)
    for kw, kind in ((b"def", "def"), (b"class", "class")):
        if line.startswith(kw, i):
            j = i + len(kw)
            if j < len(line) and line[j] in WS:
                j = skip_ws(line, j)
                k = j
                while k < len(line) and line[k] in IDENT:
                    k += 1
                if k > j:
                    return line[j:k], kind
            return None
    return None


def walk(root):
    stack = [b""]
    while stack:
        rel = stack.pop()
        with os.scandir(os.path.join(root, rel) if rel else root) as it:
            for e in it:
                p = rel + b"/" + e.name if rel else e.name
                if e.is_dir(follow_symlinks=False):
                    stack.append(p)
                elif e.is_file(follow_symlinks=False) and e.name.endswith(b".py"):
                    yield p


def main():
    root = os.fsencode(sys.argv[1])
    prefix = os.fsencode(sys.argv[2]) if len(sys.argv) > 2 else b""
    syms = []
    for rel in walk(root):
        with open(os.path.join(root, rel), "rb") as f:
            for n, line in enumerate(f.read().split(b"\n"), 1):
                r = parse_line(line)
                if r and r[0].startswith(prefix):
                    syms.append((r[0], rel, n, r[1]))
    syms.sort()
    out = sys.stdout.buffer
    for name, rel, n, kind in syms:
        out.write(b"%s\t%s\t%s\t%d\n" % (name, kind.encode(), rel, n))


if __name__ == "__main__":
    main()
