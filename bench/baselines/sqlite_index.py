#!/usr/bin/env python3
"""SQLite baseline: a table (name, kind, file, line) with an index on name.

    sqlite_index.py build <dir> -o <db>   -> parses with bench/ref.py's rules, inserts, indexes
    sqlite_index.py find <db> <prefix>    -> same output format and order as `symidx find`

Names and paths are BLOBs, so comparison and ordering are bytewise like SPEC. Not interned:
this is the plain schema a team would write first. Build time is dominated by Python parsing;
the time spent in SQLite alone (insert + index) is printed separately.
"""
import os
import sqlite3
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ref  # noqa: E402  (bench/ref.py)


def build(root, db):
    if os.path.exists(db):
        os.remove(db)
    rootb = os.fsencode(root)
    rows = []
    nfiles = 0
    for rel in ref.walk(rootb):
        nfiles += 1
        with open(os.path.join(rootb, rel), "rb") as f:
            for n, line in enumerate(f.read().split(b"\n"), 1):
                r = ref.parse_line(line)
                if r:
                    rows.append((r[0], 0 if r[1] == "def" else 1, rel, n))
    t = time.perf_counter()
    con = sqlite3.connect(db)
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    con.execute("CREATE TABLE syms (name BLOB NOT NULL, kind INTEGER NOT NULL, file BLOB NOT NULL, line INTEGER NOT NULL)")
    con.executemany("INSERT INTO syms VALUES (?, ?, ?, ?)", rows)
    con.execute("CREATE INDEX syms_name ON syms (name, file, line)")
    con.commit()
    con.close()
    print(f"symbols={len(rows)} files={nfiles} sqlite_ms={(time.perf_counter() - t) * 1000:.1f}")


def find(db, prefix):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    p = os.fsencode(prefix)
    if p:
        # Smallest blob greater than every blob starting with p: strip trailing 0xff bytes, bump the last.
        q = p.rstrip(b"\xff")
        if q:
            hi = q[:-1] + bytes([q[-1] + 1])
            cur = con.execute("SELECT name, kind, file, line FROM syms WHERE name >= ? AND name < ? ORDER BY name, file, line", (p, hi))
        else:
            cur = con.execute("SELECT name, kind, file, line FROM syms WHERE name >= ? ORDER BY name, file, line", (p,))
    else:
        cur = con.execute("SELECT name, kind, file, line FROM syms ORDER BY name, file, line")
    out = sys.stdout.buffer
    kinds = (b"def", b"class")
    for name, kind, file, line in cur:
        out.write(b"%s\t%s\t%s\t%d\n" % (name, kinds[kind], file, line))


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "build" and sys.argv[3] == "-o":
        build(sys.argv[2], sys.argv[4])
    elif len(sys.argv) == 4 and sys.argv[1] == "find":
        find(sys.argv[2], sys.argv[3])
    else:
        sys.exit("usage: sqlite_index.py build <dir> -o <db> | find <db> <prefix>")
