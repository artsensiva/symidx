#!/usr/bin/env python3
"""Fluent Bit or Vector behind the pilot's command line (SPEC A2). What the tool can't do itself is done here, and its cost counts against the tool.

usage: sanitize_tool.py vector|fluentbit [--out FILE] [--rejects FILE] [--max-reject-rate R] FORMAT PATH [FORMAT PATH ...]

The summary has to be reconstructed: kept and malformed from the lines written, dropped by subtraction, since neither tool reports these counts.
Stdin is copied to a temporary file first (Fluent Bit's tail needs a file; Vector reads each input by redirection).
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../.."))
VECTOR = ROOT + "/toolchain/vs/vector/x/vector-x86_64-unknown-linux-gnu/bin/vector"
FB = ROOT + "/toolchain/vs/fluentbit"


def usage():
    sys.stderr.write("usage: sanitize_tool.py vector|fluentbit [--out FILE] [--rejects FILE] [--max-reject-rate R] FORMAT PATH ...\n")
    sys.exit(2)


def count_lines(path):
    n = last = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            n += b.count(b"\n")
            last = b[-1]
    return n + (1 if last not in (0, 10) else 0)


def run_vector(fmt, path, out, rej, work):
    with open(HERE + "/vector/pipeline.yaml.in") as f:
        conf = f.read().replace("@DIR@", HERE + "/vector").replace("@FORMAT@", fmt).replace("@OUT@", out).replace("@REJ@", rej)
    cfg = os.path.join(work, "v.yaml")
    with open(cfg, "w") as f:
        f.write(conf)
    threads = os.environ.get("SANITIZE_THREADS", str(len(os.sched_getaffinity(0))))
    with open(path, "rb") as stdin:
        return subprocess.run([VECTOR, "--quiet", "--threads", threads, "--config", cfg], stdin=stdin, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def run_fluentbit(fmt, path, out, rej, work):
    env = dict(os.environ, LD_LIBRARY_PATH=FB + "/lib", FB_DIR=HERE + "/fluentbit", FORMAT=fmt, FILE=path, OUT_DIR=work, OUT_FILE=os.path.basename(out), REJ_FILE=os.path.basename(rej))
    return subprocess.run([FB + "/x/opt/fluent-bit/bin/fluent-bit", "-q", "-c", HERE + "/fluentbit/pipeline.conf"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def move(src, dst):
    """A rename when both are on one filesystem, so the file appears whole; else a copy under a temporary name, then a rename."""
    try:
        os.replace(src, dst)
    except OSError:
        shutil.copyfile(src, dst + ".tmp")
        os.replace(dst + ".tmp", dst)


def main(argv):
    if not argv or argv[0] not in ("vector", "fluentbit"):
        usage()
    tool, argv = argv[0], argv[1:]
    out_path = rej_path = rate = None
    while argv and argv[0].startswith("--"):
        if len(argv) < 2:
            usage()
        if argv[0] == "--out":
            out_path = argv[1]
        elif argv[0] == "--rejects":
            rej_path = argv[1]
        elif argv[0] == "--max-reject-rate":
            try:
                rate = float(argv[1])
            except ValueError:
                usage()
        else:
            usage()
        argv = argv[2:]
    if not argv or len(argv) % 2 or any(f not in ("hdfs", "ssh", "apache") for f in argv[0::2]):
        usage()
    # Beside the output when there is one, so that the final move is a rename.
    work = tempfile.mkdtemp(prefix="sanitize-", dir=os.path.dirname(os.path.abspath(out_path)) if out_path and os.path.isdir(os.path.dirname(os.path.abspath(out_path))) else None)
    try:
        final = os.path.join(work, "final")
        rejects = os.path.join(work, "rejects-final")
        lines = 0
        with open(final, "wb") as fo, open(rejects, "wb") as fr:
            for i, (fmt, path) in enumerate(zip(argv[0::2], argv[1::2])):
                if path == "-":
                    path = os.path.join(work, "stdin")
                    with open(path, "wb") as t:
                        shutil.copyfileobj(sys.stdin.buffer, t)
                if not os.path.exists(path):
                    sys.stderr.write(f"sanitize: cannot open {path}\n")
                    return 3
                lines += count_lines(path)
                o, r = os.path.join(work, f"o{i}"), os.path.join(work, f"r{i}")
                rc = (run_vector if tool == "vector" else run_fluentbit)(fmt, path, o, r, work)
                if rc != 0:
                    sys.stderr.write(f"sanitize: {tool} exited {rc}\n")
                    return 3
                # One input needs no concatenating, which saves the tool a whole copy of its output.
                single = len(argv) == 2
                for src, dst, target in ((o, fo, final), (r, fr, rejects)):
                    if os.path.exists(src):
                        if single:
                            os.replace(src, target)
                        else:
                            with open(src, "rb") as f:
                                shutil.copyfileobj(f, dst)
                            os.unlink(src)
        kept, malformed = count_lines(final), count_lines(rejects)
        if rej_path:
            try:
                move(rejects, rej_path)
            except OSError as e:
                sys.stderr.write(f"sanitize: {e}\n")
                return 3
        sys.stderr.write(f"lines={lines} kept={kept} dropped={lines - kept - malformed} malformed={malformed}\n")
        if rate is not None and lines and malformed / lines > rate:
            sys.stderr.write("sanitize: reject rate exceeded\n")
            return 1
        try:
            if out_path:
                move(final, out_path)
            else:
                with open(final, "rb") as f:
                    shutil.copyfileobj(f, sys.stdout.buffer)
                sys.stdout.buffer.flush()
        except OSError as e:
            sys.stderr.write(f"sanitize: {e}\n")
            if out_path and os.path.exists(out_path + ".tmp"):
                os.unlink(out_path + ".tmp")
            try:
                os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
            except OSError:
                pass
            return 3
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


sys.exit(main(sys.argv[1:]))
