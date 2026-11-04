#!/usr/bin/env python3
"""Paired, randomly interleaved runs of two or more commands.

usage: measure.py ROUNDS OUT.csv NAME=CMD [NAME=CMD ...]
CMD is split on spaces (no shell); leading ENV:KEY=VAL tokens set that command's environment, and a "" token is an empty argument.
Each round runs every command twice, in a fresh random order: once spawned directly for wall time, once under GNU time for peak RSS
(KiB, %M) and CPU seconds (user + system). So wall time and CPU come from different launches, and their quotient isn't one run's utilization;
time_wall_s is GNU time's own coarse wall time for the launch that gave RSS and CPU. wait4's ru_maxrss can't be used: posix_spawn shares this
interpreter's memory until exec, so it never reports less than Python's own peak (~13 MB). One untimed run of each first. stdout goes to
/dev/null. Any non-zero exit stops the whole measurement.

Writes OUT.csv, one row per command per round, with its position in the round, start time and 1-minute load, and OUT.csv.meta.json, with
each command's argv, environment changes and the executable's sha256. Prints each command's median and, for each against the first, the
median of paired ratios with their range. With so few rounds, that range is what the data supports; it is not a confidence interval.
"""
import hashlib, json, os, platform, random, statistics, sys, time

def run(cmd):
    env, argv, _ = cmd
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
    env, argv, _ = cmd
    devnull = os.open(os.devnull, os.O_WRONLY)
    tv = ["/usr/bin/time", "-f", "%M %U %S %e", "-o", tmp] + argv
    pid = os.posix_spawn(tv[0], tv, env, file_actions=[(os.POSIX_SPAWN_DUP2, devnull, 1)])
    _, status, _ = os.wait4(pid, 0)
    os.close(devnull)
    if os.waitstatus_to_exitcode(status) != 0:
        sys.exit(f"failed: {' '.join(argv)}")
    m, u, sy, e = open(tmp).read().split()[-4:]
    return int(m), float(u) + float(sy), float(e)

def parse(c):
    env = dict(os.environ)
    toks = c.split()
    for t in toks:
        if t.startswith("ENV:"):
            k, v = t[4:].split("=", 1)
            env[k] = v
    argv = ["" if t == '""' else t for t in toks if not t.startswith("ENV:")]
    extra = {t[4:].split("=", 1)[0]: t[4:].split("=", 1)[1] for t in toks if t.startswith("ENV:")}
    return env, argv, extra

def load1():
    with open("/proc/loadavg") as f:
        return float(f.read().split()[0])

def sha256(path):
    try:
        with open(path, "rb") as f:
            return hashlib.file_digest(f, "sha256").hexdigest()
    except OSError:
        return None

def main():
    rounds, out = int(sys.argv[1]), sys.argv[2]
    cmds = [a.split("=", 1) for a in sys.argv[3:]]
    cmds = [(n, parse(c)) for n, c in cmds]
    tmp = out + ".time"
    for _, c in cmds:
        run(c)
    with open(out + ".meta.json", "w") as f:
        json.dump({"started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "rounds": rounds, "machine": platform.platform(),
                   "commands": {n: {"argv": c[1], "env": c[2], "sha256": sha256(c[1][0])} for n, c in cmds}}, f, indent=1)
    res = {n: [] for n, _ in cmds}
    for i in range(rounds):
        order = cmds[:]
        random.shuffle(order)
        for pos, (n, c) in enumerate(order):
            start, load = time.time(), load1()
            wall = run(c)
            res[n].append((i, wall) + rss(c, tmp) + (pos, start, load))
    with open(out, "w") as f:
        f.write("name,round,wall_s,maxrss_kb,cpu_s,time_wall_s,position,start_unix,load1\n")
        for n, rows in res.items():
            for i, t, m, cpu, e, pos, start, load in rows:
                f.write(f"{n},{i},{t:.6f},{m},{cpu:.2f},{e:.2f},{pos},{start:.3f},{load:.2f}\n")
    base = cmds[0][0]
    for n, rows in res.items():
        line = f"{n:12} wall {statistics.median(r[1] for r in rows) * 1e3:9.2f} ms  rss {statistics.median(r[2] for r in rows):8.0f} KiB"
        if n != base:
            for k, label in ((1, "wall"), (2, "rss")):
                ratios = [a[k] / b[k] for a, b in zip(rows, res[base])]
                line += f"  {label}/{base} {statistics.median(ratios):.3f} (range {min(ratios):.3f}-{max(ratios):.3f})"
        print(line)
    os.unlink(tmp)

main()
