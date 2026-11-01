#!/usr/bin/env bash
# Замеры symidx: build (время + пиковая RAM), размер образа, load, find, контрольная сумма.
#   bench/run.sh [S M L]            — размеры корпуса (по умолчанию все)
#   IMPLS="goose rust-expert" ...   — какие реализации (по умолчанию все три; отсутствующие пропускаются)
#   COLD=1                          — сбрасывать page cache перед load/find (нужен sudo без пароля)
#   RUNS=10                         — число прогонов hyperfine
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZES=("${@:-S M L}"); SIZES=(${SIZES[*]})
IMPLS=(${IMPLS:-goose rust-idiomatic rust-expert})
RUNS=${RUNS:-10}
PREFIXES=(get_ test Model _)
OUT="$ROOT/bench/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

bin_of() {
  case "$1" in
    goose) echo "$ROOT/goose/symidx" ;;
    rust-*) echo "$ROOT/$1/target/release/symidx" ;;
  esac
}

PREPARE=()
if [ "${COLD:-0}" = 1 ]; then
  sudo -n true || { echo "COLD=1 требует sudo без пароля" >&2; exit 1; }
  PREPARE=(--prepare 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null')
fi

# Эталонные контрольные суммы считаются один раз на корпус и кешируются.
ref_sum() {
  local cache="$ROOT/bench/results/ref-$1.sha256"
  [ -s "$cache" ] || python3 -I "$ROOT/bench/ref.py" "$ROOT/corpus/$1" | sha256sum | cut -d' ' -f1 > "$cache"
  cat "$cache"
}

CSV="$OUT/summary.csv"
echo "impl,size,build_s,build_maxrss_kb,image_bytes,load_ms,find_ms,checksum_ok" > "$CSV"

for size in "${SIZES[@]}"; do
  corpus="$ROOT/corpus/$size"
  [ -d "$corpus" ] || { echo "нет корпуса $corpus — запустите corpus/make.sh" >&2; exit 1; }
  ref=$(ref_sum "$size")
  echo "== $size (ref sha256 $ref)"
  for impl in "${IMPLS[@]}"; do
    bin=$(bin_of "$impl")
    [ -x "$bin" ] || { echo "  $impl: нет $bin, пропуск"; continue; }
    img="$OUT/$impl-$size.img"
    tag="$OUT/$impl-$size"

    /usr/bin/time -v "$bin" build "$corpus" -o "$img" > "$tag.build.out" 2> "$tag.build.time"
    rss=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tag.build.time")
    hyperfine -N -w 1 -r 3 --export-json "$tag.build.json" "$bin build $corpus -o $img" > /dev/null
    imgsz=$(stat -c %s "$img")

    hyperfine -N -w 3 -r "$RUNS" "${PREPARE[@]}" --export-json "$tag.load.json" "$bin load $img" > /dev/null
    finds=(); for p in "${PREFIXES[@]}"; do finds+=("$bin find $img $p"); done
    hyperfine -N -w 3 -r "$RUNS" "${PREPARE[@]}" --export-json "$tag.find.json" "${finds[@]}" > /dev/null

    sum=$("$bin" find "$img" "" | sha256sum | cut -d' ' -f1)
    ok=$([ "$sum" = "$ref" ] && echo yes || echo NO)

    mean() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["results"]; print("%.3f" % (sum(x["mean"] for x in r)/len(r)*float(sys.argv[2])))' "$@"; }
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$impl" "$size" "$(mean "$tag.build.json" 1)" "$rss" "$imgsz" \
      "$(mean "$tag.load.json" 1000)" "$(mean "$tag.find.json" 1000)" "$ok" | tee -a "$CSV"
  done
done

command -v column >/dev/null && column -s, -t "$CSV"
echo "результаты: $OUT"
