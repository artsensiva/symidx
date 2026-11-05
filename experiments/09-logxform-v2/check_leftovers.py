#!/usr/bin/env python3
"""The 0-leftover mark, on the frozen batch binaries. usage: check_leftovers.py WORK_DIR SSH_LOG OUT_TXT BINARY...

A leftover is four decimal numbers from 0 to 255 joined by '-', with no digit directly before or after.
The count is deliberately strict: anything found is listed for review, and nothing is excused here.
"""
import hashlib, os, re, subprocess, sys

N = r"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
LEFT = re.compile(rb"(?<![0-9])(?=(" + (N + "-").encode() * 3 + N.encode() + rb"))(?=\1(?![0-9]))")


def main(work, ssh, out, binaries):
    os.makedirs(work, exist_ok=True)
    lines = []
    for b in binaries:
        o, r = os.path.join(work, "left.out"), os.path.join(work, "left.rej")
        code = subprocess.run([b, "--out", o, "--rejects", r, "ssh", ssh], stdout=subprocess.DEVNULL).returncode
        data = open(o, "rb").read()
        hits = [m for m in LEFT.finditer(data)]
        lines.append(f"{os.path.basename(b)}: exit {code}, {data.count(b'\n')} lines out, {len(hits)} leftovers, sha256 {hashlib.sha256(data).hexdigest()}")
        for m in hits[:20]:
            lines.append("  " + data[max(0, m.start() - 30):m.start() + 40].decode("latin-1").replace("\n", " | "))
    open(out, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
