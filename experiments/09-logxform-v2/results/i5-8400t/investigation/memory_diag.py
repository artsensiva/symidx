#!/usr/bin/env python3
"""Development diagnosis, not counted: what is the memory PipeBench reports on our servers' high tests?
usage: memory_diag.py PIPEBENCH OUT_TXT. Samples the subject container's cgroup once a second during a harness run,
and reports the breakdown at the peak of PipeBench's own formula, usage minus page cache plus shmem."""
import json, os, subprocess, sys, time
PB, OUT = sys.argv[1], os.path.abspath(sys.argv[2])
TESTS = ["tcp_to_tcp", "regex_mask", "tcp_to_tcp_persistent", "disk_buffer"]
SUBJECTS = ["logxform-goose", "logxform-rust"]
LABEL = "dev-memdiag"
os.chdir(PB)
def rd(p):
    try:
        return open(p).read()
    except OSError:
        return None
def sample(cid, pid):
    base = f"/sys/fs/cgroup/system.slice/docker-{cid}.scope/"
    s, cur = rd(base + "memory.stat"), rd(base + "memory.current")
    if not s or not cur:
        return None
    m = {l.split()[0]: int(l.split()[1]) for l in s.splitlines()}
    m["current"] = int(cur)
    m["used"] = m["current"] - (m.get("file", 0) - m.get("shmem", 0))
    st = rd(f"/proc/{pid}/status") or ""
    m["rss_kb"] = next((int(l.split()[1]) for l in st.splitlines() if l.startswith("VmRSS")), 0)
    return m
lines = []
for t in TESTS:
    for sub in SUBJECTS:
        name = f"bench-subject-{sub}"
        test = f"{t}_performance"
        p = subprocess.Popen(["./bin/harness", "test", "-t", test, "-s", sub, "--hardware", LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        peak, cid, pid, n = None, None, None, 0
        while p.poll() is None:
            time.sleep(1)
            if not cid:
                r = subprocess.run(["docker", "inspect", "-f", "{{.Id}} {{.State.Pid}}", name], capture_output=True, text=True)
                if r.returncode == 0 and r.stdout.split()[1] != "0":
                    cid, pid = r.stdout.split()
                continue
            m = sample(cid, pid)
            if m is None:
                continue
            n += 1
            if peak is None or m["used"] > peak["used"]:
                peak = m
        try:
            rep = [x for x in json.load(open(f"web/results/{LABEL}/{sub}.json"))["results"] if x["test"] == test][-1]["max_mem_mb"]
        except Exception as e:
            rep = f"no result: {type(e).__name__}"
        mb = lambda k: peak.get(k, 0) / 1048576 if peak else 0
        lines.append(f"{t} {sub}: samples {n}, harness peak {rep if isinstance(rep, str) else round(rep)} MB; at the sampled peak: used {mb('used'):.0f}, anon {mb('anon'):.0f}, sock {mb('sock'):.0f}, kernel {mb('kernel'):.0f}, slab {mb('slab'):.0f}, shmem {mb('shmem'):.0f}, excluded file cache {mb('file'):.0f}, process RSS {(peak or {}).get('rss_kb', 0) / 1024:.0f}")
        open(OUT, "w").write("\n".join(lines) + "\n")
print("done")
