# logxform harness helpers, sourced after bench/lib.sh. bash 3.2 compatible.
X="$ROOT/experiments/02-logxform"
CORPUS="$X/corpus/src"
IMPLS_ALL="goose rust-arena rust-idiomatic"

# corpus_args <S|M|L|edge>: the logxform arguments of a corpus (SPEC "Corpus").
corpus_args() {
  local m="apache $CORPUS/Apache.log ssh $CORPUS/SSH.log hdfs $CORPUS/HDFS.log"
  case "$1" in
    S) echo "apache $CORPUS/Apache.log ssh $CORPUS/SSH.log hdfs $CORPUS/HDFS_head500k.log" ;;
    M) echo "$m" ;;
    L) echo "$m $m $m $m" ;;
    edge) echo "hdfs $X/test/edge.hdfs ssh $X/test/edge.ssh apache $X/test/edge.apache" ;;
    *) echo "unknown corpus $1" >&2; return 1 ;;
  esac
}

# corpus_bytes <size>: total input bytes (files counted as often as they're named).
corpus_bytes() {
  local n=0 f
  set -- $(corpus_args "$1")
  while [ $# -gt 1 ]; do n=$((n + $(file_size "$2"))); shift 2; done
  echo "$n"
}

bin_of() {
  case "$1" in
    goose) echo "$X/goose/logxform" ;;
    rust-*) echo "$X/$1/target/release/logxform" ;;
  esac
}

# Logical cores available: the PIN set's size, else nproc (sysctl on macOS).
cores() {
  if [ -n "${PIN:-}" ]; then echo "$PIN" | tr ',' '\n' | awk -F- 'NF == 2 {n += $2 - $1 + 1; next} {n++} END {print n}'
  elif command -v nproc > /dev/null; then nproc
  else sysctl -n hw.logicalcpu; fi
}

# want_sum <size>: recorded sha256 and summary line for a corpus (ref-checksums.txt).
want_sum() { awk -v s="$1" '$1 == s {print $2}' "$X/ref-checksums.txt"; }
want_summary() { awk -v s="$1" '$1 == s {$1 = ""; $2 = ""; sub(/^  /, ""); print}' "$X/ref-checksums.txt"; }
