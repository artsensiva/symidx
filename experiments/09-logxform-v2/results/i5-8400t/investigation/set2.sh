#!/usr/bin/env bash
# Second set of development reruns. Never counted: separate label, configs restored at the end.
PB=/home/artem/symidx/toolchain/pipebench/PipeBench; O=/home/artem/symidx/toolchain/pipebench/investigate; cd "$PB"
LABEL=dev-investigate
clean() { docker ps -aq --filter name=bench- | xargs -r docker rm -f >/dev/null 2>&1; docker network ls -q --filter name=bench- | xargs -r docker network rm >/dev/null 2>&1; docker volume ls -q --filter name=bench- | xargs -r docker volume rm >/dev/null 2>&1; }
run() { local tag=$1 t=$2 s=$3 extra=""; [ "${4:-}" = keep ] && extra=--no-cleanup
  timeout 900 ./bin/harness test -t "$t" -s "$s" --hardware "$LABEL" $extra > "$O/$tag.log" 2>&1
  [ "${4:-}" = keep ] && docker logs bench-subject-$s > "$O/$tag.subject.log" 2>&1
  echo "$(date +%H:%M) $tag: $(grep -E 'lines sent|loss:' "$O/$tag.log" | tail -1 | tr -s ' ' | cut -c1-90)"; }
H=cases/tcp_to_http_persistent_correctness/configs/fluent-bit.conf; FT=cases/file_truncate_correctness/configs/fluent-bit.conf; VT=cases/tcp_to_tcp_persistent_correctness/configs/vector.toml
# Fluent Bit HTTP: only the storage limit changes.
sed -i 's/storage.total_limit_size 2G/storage.total_limit_size 8G/' "$H"
for i in 1 2; do run limit-fb-http-$i tcp_to_http_persistent_correctness fluent-bit; done
git checkout -- "$H"
# Fluent Bit truncate: debug logging only, then the stat watcher instead of inotify.
sed -i 's/Log_Level    warn/Log_Level    debug/' "$FT"
run debug-fb-trunc file_truncate_correctness fluent-bit keep; clean
git checkout -- "$FT"
sed -i '/Read_from_Head true/a\    Inotify_Watcher false' "$FT"
run stat-fb-trunc file_truncate_correctness fluent-bit
git checkout -- "$FT"
# Vector: a second sink counts what got into Vector, to place the loss on the way in or the way out.
cat >> "$VT" <<'V'

[sinks.count]
type = "file"
inputs = ["in"]
path = "/tmp/count.log"
encoding.codec = "text"
V
for i in 1 2; do run count-vector-tcp-$i tcp_to_tcp_persistent_correctness vector keep; echo "count-vector-tcp-$i file sink lines: $(docker exec bench-subject-vector sh -c 'wc -l < /tmp/count.log')"; clean; done
git checkout -- "$VT"
git status --short -- "$H" "$FT" "$VT" | wc -l
echo done
