#!/usr/bin/env python3
"""usage: check.py REFERENCE.ndjson OUTPUT.ndjson [--unordered] [--allow-missing N]

Compares a tool's records with the reference, after parsing each line, so that JSON key order doesn't matter. Everything else does:
every record must have exactly the keys ts, level, sev, component, msg, kv, with the right types, and the only relaxation is
that an empty kv may be [] (Fluent Bit renders an empty Lua table so; SPEC.md). Order must match unless --unordered is given.
--allow-missing N lets up to N reference records be absent, as for Fluent Bit's tail, which drops a final line with no newline;
each one is printed. Exits 1 on any difference. Ordered comparison streams, so it handles the full corpus.
"""
import argparse, json, sys

KEYS = {"ts", "level", "sev", "component", "msg", "kv"}


class Bad(Exception):
    pass


def canon(line, where):
    try:
        r = json.loads(line)
    except ValueError as e:
        raise Bad(f"{where}: not JSON: {e}: {line[:160]!r}")
    if not isinstance(r, dict) or set(r) != KEYS:
        raise Bad(f"{where}: keys {sorted(r) if isinstance(r, dict) else type(r).__name__}, want {sorted(KEYS)}")
    for k in ("ts", "level", "component", "msg"):
        if not isinstance(r[k], str):
            raise Bad(f"{where}: {k} is {type(r[k]).__name__}, want a string")
    if type(r["sev"]) is not int:
        raise Bad(f"{where}: sev is {r['sev']!r}, want an integer")
    kv = r["kv"]
    if kv == []:
        kv = {}
    if not isinstance(kv, dict) or any(not isinstance(v, str) for v in kv.values()):
        raise Bad(f"{where}: kv is {kv!r}, want a map of strings")
    return (r["ts"], r["level"], r["sev"], r["component"], r["msg"], tuple(sorted(kv.items())))


def lines(path):
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for i, line in enumerate(f, 1):
            if line.strip():
                yield canon(line, f"{path}:{i}")


def ordered(ref_path, got_path, allow):
    ref, got = lines(ref_path), lines(got_path)
    n_ref = n_got = 0
    missing = []
    g = next(got, None)
    for r in ref:
        n_ref += 1
        if g == r:
            n_got += 1
            g = next(got, None)
        elif len(missing) < allow:
            missing.append(r)
        else:
            raise Bad(f"record {n_ref} differs:\n  ref: {r}\n  got: {g}")
    if g is not None:
        raise Bad(f"output has records past the reference's end, first: {g}")
    return n_ref, n_got, missing


def unordered(ref_path, got_path, allow):
    from collections import Counter
    a, b = Counter(lines(ref_path)), Counter(lines(got_path))
    extra = list((b - a).elements())
    if extra:
        raise Bad(f"{len(extra)} records not in the reference, first: {extra[0]}")
    missing = list((a - b).elements())
    if len(missing) > allow:
        raise Bad(f"{len(missing)} records missing, allowed {allow}, first: {missing[0]}")
    return sum(a.values()), sum(b.values()), missing


def main():
    p = argparse.ArgumentParser()
    p.add_argument("ref")
    p.add_argument("got")
    p.add_argument("--unordered", action="store_true")
    p.add_argument("--allow-missing", type=int, default=0)
    a = p.parse_args()
    try:
        n_ref, n_got, missing = (unordered if a.unordered else ordered)(a.ref, a.got, a.allow_missing)
    except Bad as e:
        print(f"MISMATCH: {e}")
        return 1
    for m in missing:
        print(f"  allowed missing: {m}")
    print(f"ok: {n_got} of {n_ref} reference records, {'any order' if a.unordered else 'in order'}, {len(missing)} missing")
    return 0


sys.exit(main())
