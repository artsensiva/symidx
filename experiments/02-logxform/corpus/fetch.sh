#!/usr/bin/env bash
# The pinned logxform corpus (experiments/02-logxform/SPEC.md, "Corpus"): Loghub archives from Zenodo
# record 8196385, every archive and every input file checked against its sha256, and every log checked to
# be ASCII. Idempotent: what's already there and verified is kept. Linux and macOS.
#   experiments/02-logxform/corpus/fetch.sh      — writes experiments/02-logxform/corpus/src/
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
. "$ROOT/bench/lib.sh"
SRC="$HERE/src"
mkdir -p "$SRC"
cd "$SRC"
URL=https://zenodo.org/api/records/8196385/files

check() {   # check <file> <sha256>
  local got; got=$(sha256 < "$1")
  [ "$got" = "$2" ] || { echo "sha256 mismatch for $1: got $got, want $2" >&2; return 1; }
}
fetch() {   # fetch <archive> <sha256>
  if [ -s "$1" ] && check "$1" "$2" 2> /dev/null; then return; fi
  echo "downloading $1"
  curl -fsSL --retry 3 -o "$1.part" "$URL/$1/content"
  mv "$1.part" "$1"
  check "$1" "$2"
}
fetch HDFS_v1.zip   04f919f2185821f23f045dca611a7586429bdabc601bd7b43f30005f8e289b01
fetch SSH.tar.gz    296610a35773f58b7c295e5407fc5ccdf48beb3c544fc14a6309addf904a2712
fetch Apache.tar.gz f2cb5014453c8a0f71596838e1639a2131ff6d360839ad280409f621a6cac452

extract() { # extract <log> <sha256> <command...>
  local log=$1 want=$2; shift 2
  if [ -s "$log" ] && check "$log" "$want" 2> /dev/null; then return; fi
  echo "extracting $log"
  "$@"
  check "$log" "$want"
}
extract Apache.log 23e616a1ed529bab9b20b9bc345d37035061eee971d246102bcc4937e51a039b tar xzf Apache.tar.gz Apache.log
extract SSH.log    89eee9e36c182722f9fadc6e5617a4818ffc66109e7e222b8f9e8b78fc3aa2f3 tar xzf SSH.tar.gz SSH.log
extract HDFS.log   0783096174d7832c618337f9609e06e04abd86ddd7089b3c12b407e63bfebc52 unzip -o -q HDFS_v1.zip HDFS.log
extract HDFS_head500k.log c0c06bcb8af8b361f4d48f6732a3263d06c2a717539e218c2ad45a2225f2b915 \
  sh -c 'head -n 500000 HDFS.log > HDFS_head500k.log'

# ASCII only: printable bytes, tab, CR and LF.
for f in Apache.log SSH.log HDFS.log HDFS_head500k.log; do
  if LC_ALL=C grep -q "$(printf '[^\t\r -~]')" "$f"; then echo "$f: non-ASCII or control bytes" >&2; exit 1; fi
done
echo "corpus ok: $SRC"
