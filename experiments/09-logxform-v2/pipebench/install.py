#!/usr/bin/env python3
"""Adds logxform-goose and logxform-rust to a PipeBench checkout as subjects. Idempotent. usage: install.py PIPEBENCH_DIR
Only adds: the subjects, a config per case, and their names in each case's list. Nothing about the harness or a test changes."""
import os, re, sys

P = sys.argv[1]
TCP = "source tcp 9000\n"
OUT = "sink tcp receiver 9001\n"
BUF = "buffer disk /var/lib/logxform/buf\n"
SET = "transform set_field processed_by logxform-pipeline\n"
REGEX = "transform regex CONN=\\d+ CONN=***\n"
FILES = "data_dir /var/lib/logxform/state\n"
CASES = {
    "tcp_to_tcp_performance": TCP + OUT,
    "tcp_to_blackhole_performance": TCP + "sink blackhole\n",
    "regex_mask_performance": TCP + REGEX + OUT,
    "set_field_performance": TCP + SET + OUT,
    "syslog_parsing_performance": TCP + "transform syslog\n" + OUT,
    "real_world_1_performance": TCP + "transform syslog_tag_debug\n" + OUT,
    "tcp_to_http_performance": TCP + "sink http receiver 9001 /\n",
    "file_to_tcp_performance": "source file /data/input*\n" + FILES + OUT,
    "tcp_to_tcp_persistent_performance": TCP + OUT + BUF,
    "disk_buffer_performance": TCP + OUT + BUF,
    "file_rotate_create_correctness": "source file /data/input.log*\n" + FILES + OUT,
    "file_rotate_truncate_correctness": "source file /data/input.log\n" + FILES + OUT,
    "file_truncate_correctness": "source file /data/input.log\n" + FILES + OUT,
    "file_rotate_restart_correctness": "source file /data/input.log*\n" + FILES + OUT,
    "tcp_to_tcp_persistent_correctness": TCP + OUT + BUF,
    "tcp_to_tcp_persistent_restart_correctness": TCP + OUT + BUF,
    "tcp_to_tcp_persistent_crash_correctness": TCP + OUT + BUF,
    "disk_buffer_persistence_correctness": TCP + OUT + BUF,
    "tcp_to_http_persistent_correctness": TCP + "sink http receiver 9001 /\n" + BUF,
    "sighup_correctness": TCP + OUT,
    "wrapped_json_correctness": TCP + "transform json\n" + OUT,
}
NAMES = ["logxform-goose", "logxform-rust"]

p = f"{P}/internal/config/subject.go"
s = open(p).read()
if '"logxform-goose"' not in s:
    entry = "".join(f'''	"{n}": {{
		Name:       "{n}",
		Image:      "{n}",
		Version:    "dev",
		ConfigPath: "/etc/logxform/logxform.conf",
		Command:    []string{{"--config", "/etc/logxform/logxform.conf"}},
	}},
''' for n in NAMES)
    # Vector's Debian image too, in case PipeBench's Alpine one holds Vector back. Used only by the check in real_cases.py.
    entry += '''	"vector-debian": {
		Name:       "vector-debian",
		Image:      "timberio/vector",
		Version:    "0.54.0-debian",
		ConfigPath: "/etc/vector/vector.toml",
		Command:    []string{"--config", "/etc/vector/vector.toml"},
	},
'''
    s, k = re.subn(r'(\n\t"vector": \{)', lambda m: "\n" + entry + m.group(1)[1:], s, count=1)
    assert k == 1
    open(p, "w").write(s)
for case, conf in CASES.items():
    d = f"{P}/cases/{case}"
    for n in NAMES:
        with open(f"{d}/configs/{n}.conf", "w") as f:
            f.write(conf)
    y = open(f"{d}/case.yaml").read()
    if "logxform-goose" not in y:
        y, k = re.subn(r"^subjects:\n", "subjects:\n" + "".join(f"  - {n}\n" for n in NAMES), y, count=1, flags=re.M)
        assert k == 1, case
        open(f"{d}/case.yaml", "w").write(y)
print("installed", len(CASES), "cases")
