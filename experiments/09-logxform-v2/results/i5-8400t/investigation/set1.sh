#!/usr/bin/env bash
# Development reruns to find causes. Never counted: separate label, configs restored at the end.
PB=/home/artem/symidx/toolchain/pipebench/PipeBench; O=/home/artem/symidx/toolchain/pipebench/investigate; mkdir -p "$O"; cd "$PB"
LABEL=dev-investigate
clean() { docker ps -aq --filter name=bench- | xargs -r docker rm -f >/dev/null 2>&1; docker network ls -q --filter name=bench- | xargs -r docker network rm >/dev/null 2>&1; docker volume ls -q --filter name=bench- | xargs -r docker volume rm >/dev/null 2>&1; }
run() { # tag test subject [nocleanup]
  local tag=$1 t=$2 s=$3 extra=""; [ "${4:-}" = keep ] && extra=--no-cleanup
  timeout 900 ./bin/harness test -t "$t" -s "$s" --hardware "$LABEL" $extra > "$O/$tag.log" 2>&1
  [ "${4:-}" = keep ] && docker logs bench-subject-$s > "$O/$tag.subject.log" 2>&1
  [ "${4:-}" = keep ] && clean
  echo "$(date +%H:%M) $tag: $(grep -E 'lines sent|loss:' "$O/$tag.log" | tail -1 | tr -s ' ' | cut -c1-90)"
}
TT=cases/tcp_to_tcp_persistent_correctness/configs/fluent-bit.conf; TR=cases/tcp_to_tcp_persistent_restart_correctness/configs/fluent-bit.conf; FT=cases/file_truncate_correctness/configs/fluent-bit.conf
# Unchanged configs, logs kept, to see what each tool says.
run base-vector-tcp tcp_to_tcp_persistent_correctness vector keep
run base-fb-tcp tcp_to_tcp_persistent_correctness fluent-bit keep
run base-fb-http tcp_to_http_persistent_correctness fluent-bit keep
run base-vector-http tcp_to_http_persistent_correctness vector keep
run base-fb-trunc file_truncate_correctness fluent-bit keep
# The one change under test: retry without limit.
sed -i '/^\[OUTPUT\]/a\    Retry_Limit   false' "$TT" "$TR"
for i in 1 2; do run retry-fb-tcp-$i tcp_to_tcp_persistent_correctness fluent-bit; done
for i in 1 2; do run retry-fb-restart-$i tcp_to_tcp_persistent_restart_correctness fluent-bit; done
git checkout -- "$TT" "$TR"
git diff --stat -- "$TT" "$TR" "$FT" | tail -1
echo done
