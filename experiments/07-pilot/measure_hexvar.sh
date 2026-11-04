#!/usr/bin/env bash
# Follow-up to the change request: registered hex scan against three variants, built from data/change/hexvar-{a,b,c}.patch into toolchain/pilot/hexvar/bin.
set -euo pipefail
cd /home/artem/symidx; X=experiments/07-pilot; T=toolchain/pilot; O=$X/data/change; W=$T/work; V=$T/hexvar/bin; B=$T/bin-change
P="python3 -I experiments/03-goose-patches/measure.py"; H=experiments/02-logxform/corpus/src/HDFS.log
a="--out $W/o --rejects $W/r hdfs $H"
taskset -c 3 $P 10 $O/hexvar-hdfs.csv "goose_registered=$B/sanitize-goose $a" "goose_a=$V/goose-a $a" "goose_b=$V/goose-b $a" "rust=$B/sanitize-rust $a"
a="--out $W/o --rejects $W/r bgl $T/bgl/BGL.log"
taskset -c 3 $P 10 $O/hexvar-bgl.csv "goose_registered=$B/sanitize-goose $a" "goose_a=$V/goose-a $a" "goose_b=$V/goose-b $a" "rust=$B/sanitize-rust $a"
a="--out $W/o --rejects $W/r hdfs $H"
taskset -c 3 $P 10 $O/hexvar-c-hdfs.csv "goose_registered=$B/sanitize-goose $a" "goose_c=$V/goose-c $a" "goose_base=$T/bin/sanitize-goose $a" "rust=$B/sanitize-rust $a"
a="--out $W/o --rejects $W/r bgl $T/bgl/BGL.log"
taskset -c 3 $P 10 $O/hexvar-c-bgl.csv "goose_registered=$B/sanitize-goose $a" "goose_c=$V/goose-c $a" "rust=$B/sanitize-rust $a"
