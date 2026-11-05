#!/usr/bin/env python3
"""Adds our own test cases to a PipeBench checkout, on real log lines, because the published cases send one repeated template line
and their mask regex can never match it. These are ours, not PipeBench's, and the report labels them so.
usage: real_cases.py PIPEBENCH_DIR CORPUS_SRC_DIR"""
import os, re, sys

P, C = sys.argv[1:3]


def sample(path, n):
    """n lines spread evenly through the file, without carriage returns."""
    with open(path, "rb") as f:
        lines = f.read().splitlines()
    step = max(1, len(lines) // n)
    return [l.rstrip(b"\r") for l in lines[::step][:n]]


def pri(line):
    """A syslog priority that follows what the line says, so severities vary as in a real stream."""
    if b"Failed" in line or b"error" in line:
        return b"<36>"
    if b"pam_unix" in line:
        return b"<39>"
    return b"<38>"


IP = r"\d+\.\d+\.\d+\.\d+"
HEAD = """duration: 60s
warmup: 15s

generator:
  mode: tcp
  target: "subject:9000"
  rate: 0
  line_size: 256
  format: raw
  sample_file: sample.log

receiver:
  mode: tcp
  listen: ":9001"

subjects:
  - vector
  - fluent-bit
  - logxform-goose
  - logxform-rust

configurations:
  default:
    description: "%s"
"""
VEC_TCP = """[sources.in]
type = "socket"
mode = "tcp"
address = "0.0.0.0:9000"
decoding.codec = "bytes"
framing.method = "newline_delimited"

"""
VEC_OUT = """
[sinks.out]
type = "socket"
mode = "tcp"
inputs = ["t"]
address = "receiver:9001"
encoding.codec = "json"
[sinks.out.framing]
method = "newline_delimited"
"""
FB = """[SERVICE]
    Flush        1
    Log_Level    warn
%s
[INPUT]
    Name         tcp
    Listen       0.0.0.0
    Port         9000
    Format       none
    Chunk_Size   256k
    Buffer_Size  512k
%s
[OUTPUT]
    Name         tcp
    Match        *
    Host         receiver
    Port         9001
    Format       json_lines
"""


def case(name, desc, lines, vector_xf, fb_filters, fb_service, fb_extra, ours):
    d = f"{P}/cases/{name}"
    os.makedirs(f"{d}/configs/fluent-bit", exist_ok=True)
    with open(f"{d}/sample.log", "wb") as f:
        f.write(b"\n".join(lines) + b"\n")
    with open(f"{d}/case.yaml", "w") as f:
        f.write(f'name: {name}\ntype: performance\ndescription: "{desc}"\n\n' + HEAD % desc)
    with open(f"{d}/configs/vector.toml", "w") as f:
        f.write(VEC_TCP + vector_xf + VEC_OUT)
    with open(f"{d}/configs/fluent-bit/fluent-bit.conf", "w") as f:
        f.write(FB % (fb_service, fb_filters))
    for fn, text in fb_extra.items():
        with open(f"{d}/configs/fluent-bit/{fn}", "w") as f:
            f.write(text)
    for n in ("logxform-goose", "logxform-rust"):
        with open(f"{d}/configs/{n}.conf", "w") as f:
            f.write(f"source tcp 9000\n{ours}\nsink tcp receiver 9001\n")


MASK_V = f"""[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
del(.host)
del(.port)
del(.source_type)
del(.timestamp)
.message = replace(string!(.message), r'{IP}', "<ip>")
'''
"""
MASK_FB = """
[FILTER]
    Name         lua
    Match        *
    Script       /fluent-bit/etc/mask.lua
    Call         mask
"""
MASK_LUA = """function mask(tag, timestamp, record)
    if record["log"] then
        record["log"] = string.gsub(record["log"], "%d+%.%d+%.%d+%.%d+", "<ip>")
    end
    return 2, timestamp, record
end
"""
ssh, hdfs = sample(f"{C}/SSH.log", 200000), sample(f"{C}/HDFS.log", 200000)
for name, desc, lines in (("real_ssh_mask_performance", "Real SSH log lines, masking IPs with a regex", ssh), ("real_hdfs_mask_performance", "Real HDFS log lines, masking IPs with a regex", hdfs)):
    case(name, desc, lines, MASK_V, MASK_FB, "", {"mask.lua": MASK_LUA}, f"transform regex {IP} <ip>")

SYS_V = """[transforms.t]
type = "remap"
inputs = ["in"]
source = '''
. = parse_syslog!(.message)
if .severity == "debug" {
  .dropped = true
}
'''
"""
SYS_FB = """
[FILTER]
    Name         parser
    Match        *
    Key_Name     log
    Parser       syslog-real
    Reserve_Data On

[FILTER]
    Name         lua
    Match        *
    Script       /fluent-bit/etc/tag_debug.lua
    Call         tag_debug
"""
PARSERS = r"""[PARSER]
    Name         syslog-real
    Format       regex
    Regex        ^\<(?<pri>[0-9]+)\>(?<time>[A-Z][a-z]{2} +[0-9]+ [0-9:]+) (?<host>[^ ]+) (?<ident>[a-zA-Z0-9_\/\.\-]+)(?:\[(?<pid>[0-9]+)\])?:? (?<message>.*)$
    Time_Key     time
    Time_Format  %b %d %H:%M:%S
"""
TAG = """function tag_debug(tag, ts, record)
    local pri = tonumber(record["pri"])
    if pri and (pri % 8 == 7) then
        record["dropped"] = true
    end
    return 2, ts, record
end
"""
case("real_ssh_syslog_performance", "Real SSH log lines with a syslog priority, parsed, tagging debug", [pri(l) + l for l in ssh], SYS_V, SYS_FB, "    Parsers_File parsers.conf\n", {"parsers.conf": PARSERS, "tag_debug.lua": TAG}, "transform syslog_tag_debug")
print("added 3 cases;", len(ssh), "SSH lines,", len(hdfs), "HDFS lines")
