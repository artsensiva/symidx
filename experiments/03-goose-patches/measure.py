#!/usr/bin/env python3
"""Paired, randomly interleaved runs of two or more commands.

usage: measure.py ROUNDS OUT.csv NAME=CMD [NAME=CMD ...]
CMD is split on spaces (no shell); leading ENV:KEY=VAL tokens set that command's environment, and a "" token is an empty argument. Each round runs every command twice, in a fresh random order: once
spawned directly for wall time, once under GNU time for peak RSS (KiB, %M). wait4's ru_maxrss can't be
used: posix_spawn shares this interpreter's memory until exec, so it never reports less than Python's
own peak (~13 MB). One untimed run of each first. stdout goes to /dev/null. Prints each command's median and, for each against the first, the median of paired ratios
with a bootstrap 95% interval.
"""
import os, random, statistics, sys, time

def run(cmd):
    env, argv = cmd
    devnull = os.open(os.devnull, os.O_WRONLY)
    t0 = time.perf_counter()
    pid = os.posix_spawn(argv[0], argv, env, file_actions=[(os.POSIX_SPAWN_DUP2, devnull, 1)])
    _, status, ru = os.wait4(pid, 0)
    t = time.perf_counter() - t0
    os.close(devnull)
    if os.waitstatus_to_exitcode(status) != 0:
        sys.exit(f"failed: {' '.join(argv)}")
    return t

def rss(cmd, tmp):
    env, argv = cmd
    devnull = os.open(os.devnull, os.O_WRONLY)
    tv = ["/usr/bin/time", "-f", "%M", "-o", tmp] + argv
    pid = os.posix_spawn(tv[0], tv, env, file_actions=[(os.POSIX_SPAWN_DUP2, devnull, 1)])
    _, status, _ = os.wait4(pid, 0)
    os.close(devnull)
    if os.waitstatus_to_exitcode(status) != 0:
        sys.exit(f"failed: {' '.join(argv)}")
    return int(open(tmp).read().split()[-1])

def parse(c):
    env = dict(os.environ)
    toks = c.split()
    for t in toks:
        if t.startswith("ENV:"):
            k, v = t[4:].split("=", 1)
            env[k] = v
    return env, ["" if t == '""' else t for t in toks if not t.startswith("ENV:")]

def boot(xs, n=2000):
    r = random.Random(1)
    ms = sorted(statistics.median(r.choices(xs, k=len(xs))) for _ in range(n))
    return ms[int(0.025 * n)], ms[int(0.975 * n)]

def main():
    rounds, out = int(sys.argv[1]), sys.argv[2]
    cmds = [a.split("=", 1) for a in sys.argv[3:]]
    cmds = [(n, parse(c)) for n, c in cmds]
    tmp = out + ".time"
    for _, c in cmds:
        run(c)
    res = {n: [] for n, _ in cmds}
    for i in range(rounds):
        order = cmds[:]
        random.shuffle(order)
        for n, c in order:
            res[n].append((i, run(c), rss(c, tmp)))
    with open(out, "w") as f:
        f.write("name,round,wall_s,maxrss_kb\n")
        for n, rows in res.items():
            for i, t, m in rows:
                f.write(f"{n},{i},{t:.6f},{m}\n")
    base = cmds[0][0]
    for n, rows in res.items():
        line = f"{n:12} wall {statistics.median(r[1] for r in rows) * 1e3:9.2f} ms  rss {statistics.median(r[2] for r in rows):8.0f} KiB"
        if n != base:
            for k, label in ((1, "wall"), (2, "rss")):
                ratios = [a[k] / b[k] for a, b in zip(rows, res[base])]
                lo, hi = boot(ratios)
                line += f"  {label}/{base} {statistics.median(ratios):.3f} [{lo:.3f}, {hi:.3f}]"
        print(line)
    os.unlink(tmp)

main()
