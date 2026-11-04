# corpus_files S|M: prints "FORMAT FILE" pairs, as experiment 2's corpus_args does.
corpus_files() {
  local C="$ROOT/experiments/02-logxform/corpus/src"
  local hdfs=HDFS.log; [ "$1" = S ] && hdfs=HDFS_head500k.log
  printf '%s\n' "apache $C/Apache.log" "ssh $C/SSH.log" "hdfs $C/$hdfs"
}
