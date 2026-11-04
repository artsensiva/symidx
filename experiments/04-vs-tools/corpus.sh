# corpus_files S|M|edge|hdfs|ssh|apache: prints "FORMAT FILE" pairs, in the order of experiment 2's corpus_args.
corpus_files() {
  local C="$ROOT/experiments/02-logxform/corpus/src" T="$ROOT/experiments/02-logxform/test"
  case "$1" in
    S) printf '%s\n' "apache $C/Apache.log" "ssh $C/SSH.log" "hdfs $C/HDFS_head500k.log" ;;
    M) printf '%s\n' "apache $C/Apache.log" "ssh $C/SSH.log" "hdfs $C/HDFS.log" ;;
    edge) printf '%s\n' "hdfs $T/edge.hdfs" "ssh $T/edge.ssh" "apache $T/edge.apache" ;;
    hdfs) echo "hdfs $C/HDFS.log" ;;
    ssh) echo "ssh $C/SSH.log" ;;
    apache) echo "apache $C/Apache.log" ;;
    *) echo "unknown corpus $1" >&2; return 1 ;;
  esac
}
