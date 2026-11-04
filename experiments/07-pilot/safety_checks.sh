#!/usr/bin/env bash
# The rest of the safety section (SPEC A5). usage: safety_checks.sh BIN_DIR CORPUS_DIR WORK_DIR OUT_DIR
set -uo pipefail
B=$1; C=$2; W=$3; OUT=$4; mkdir -p "$W" "$OUT"
HERE=$(cd "$(dirname "$0")" && pwd); R=$OUT/redaction.txt; M=$OUT/memory.txt
# Redaction misses: what the rules leave behind, in the reference's output, which logXform of Goose and Rust match.
: > "$R"
for f in hdfs:HDFS ssh:SSH apache:Apache bgl:BGL; do
  fmt=${f%:*}; path=$C/${f#*:}.log; [ "$fmt" = bgl ] && path=${BGL_LOG:-$W/../bgl/BGL.log}
  "$B/sanitize-goose" "$fmt" "$path" 2>/dev/null > "$W/red.out"
  python3 -I - "$fmt" "$W/red.out" >> "$R" <<'PY'
import collections, re, sys
fmt, path = sys.argv[1:3]
pats = {
  "dotted quad": rb"(?<![0-9.])\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![0-9])",
  "IP in a hostname, with dashes": rb"(?<![0-9-])\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}(?![0-9])",
  "IPv6 with ::": rb"(?<![0-9A-Za-z:])[0-9A-Fa-f]{0,4}::[0-9A-Fa-f:]*[0-9A-Fa-f](?![0-9A-Za-z:])",
  "full IPv6": rb"(?<![0-9A-Za-z:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Za-z:])",
  "0x with other lengths": rb"(?<![0-9A-Za-z])0x[0-9a-fA-F]+(?![0-9A-Za-z])",
}
ct = collections.Counter(); ex = {}
with open(path, "rb") as f:
    for line in f:
        for n, p in pats.items():
            m = re.search(p, line)
            if m:
                ct[n] += 1
                ex.setdefault(n, m.group()[:40])
print(fmt, {n: (ct[n], ex.get(n)) for n in pats})
PY
done
rm -f "$W/red.out"
# Long runs and large inputs.
: > "$M"
H=$C/HDFS.log
rss() { # label command...; reads stdin from the file named in $IN when set
  local label=$1; shift
  if [ -n "${IN:-}" ]; then /usr/bin/time -f "$label %e s %M KB exit %x" "$@" < "$IN" > /dev/null 2>> "$M.err" ; else /usr/bin/time -f "$label %e s %M KB exit %x" "$@" > /dev/null 2>> "$M.err"; fi
  grep -a -E "^$label " "$M.err" | tail -1 >> "$M"
}
: > "$M.err"
for n in goose rust; do
  IN=$H rss "$n-1x-stdin" "$B/sanitize-$n" hdfs -
  for k in 1 2 3 4 5 6 7 8; do cat "$H"; done | /usr/bin/time -f "$n-8x-stdin %e s %M KB exit %x" "$B/sanitize-$n" hdfs - > /dev/null 2>> "$M.err"; grep -a -E "^$n-8x-stdin " "$M.err" | tail -1 >> "$M"
  for sz in 67108864 268435456 1073741824; do
    python3 -I -c "import sys; sys.stdout.buffer.write(b'081109 203518 143 INFO dfs.X: ' + b'x' * $sz)" > "$W/long"
    IN=$W/long rss "$n-line-$sz" "$B/sanitize-$n" hdfs -
    python3 -I -c "import sys; sys.stdout.buffer.write((b'y' * $sz + b'\n') * 2)" > "$W/long"
    IN=$W/long rss "$n-reject-$sz" "$B/sanitize-$n" --rejects "$W/longr" hdfs -
  done
done
rm -f "$W/long" "$W/longr" "$M.err"
cat "$R" | cut -c1-400; cat "$M"
