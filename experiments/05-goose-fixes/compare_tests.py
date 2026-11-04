#!/usr/bin/env python3
"""usage: compare_tests.py BASE.log PATCHED.log
Compares two runs of Goose's test/run_tests.py by the names of their failing tests and each section's totals, not by totals alone.
Temporary directory names are normalized away. Exits 1 if they differ."""
import re, sys


def read(path):
    fails, sections = set(), {}
    for line in open(path, errors="replace"):
        line = line.rstrip()
        m = re.match(r"(?:[\w ,()/-]+: )?FAIL (.+)", line)
        if m:
            fails.add(re.sub(r"\b[\w-]+-[a-z0-9_]{8}\b", "<tmp>", m.group(1)))
        m = re.match(r"== (.+?): (.+)$", line)
        if m:
            sections[m.group(1)] = m.group(2)
    return fails, sections


a, sa = read(sys.argv[1])
b, sb = read(sys.argv[2])
print(f"failing tests: base {len(a)}, patched {len(b)}")
for x in sorted(a - b):
    print(f"  only in base: {x}")
for x in sorted(b - a):
    print(f"  only in patched: {x}")
for k in sorted(set(sa) | set(sb)):
    if sa.get(k) != sb.get(k):
        print(f"  section differs: {k}: base {sa.get(k)}, patched {sb.get(k)}")
same = a == b and sa == sb
print("same failing tests and section totals" if same else "DIFFERENT")
sys.exit(0 if same else 1)
