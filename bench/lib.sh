# Shared helpers for the benchmark scripts: portable across Linux and macOS, bash 3.2 compatible
# (macOS /bin/bash). Sourced, not run.

OS=$(uname -s)

# sha256 of stdin, hex only.
sha256() {
  if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

# Size of a file in bytes.
file_size() { wc -c < "$1" | tr -d ' '; }

# peak_rss_kb <stdout-file> <stderr-file> <cmd...>: runs cmd and prints its peak RSS in KiB.
# Linux: GNU time's %M (KiB). macOS: BSD time -l reports ru_maxrss in bytes. Honors PIN (setup_pin).
peak_rss_kb() {
  local out=$1 err=$2; shift 2
  case "$OS" in
    Darwin)
      ${PINPFX[@]+"${PINPFX[@]}"} /usr/bin/time -l "$@" > "$out" 2> "$err" || return
      awk '/maximum resident set size/ {printf "%d\n", $1 / 1024}' "$err" ;;
    *)
      ${PINPFX[@]+"${PINPFX[@]}"} /usr/bin/time -f 'peak_rss_kb %M' "$@" > "$out" 2> "$err" || return
      awk '$1 == "peak_rss_kb" {print $2}' "$err" | tail -1 ;;
  esac
}

# Cold-cache support. COLD=1 empties the page cache before each timed run (hyperfine --prepare):
# Linux drop_caches or macOS purge, via passwordless sudo restricted to that one command
# (bench/check-machine.sh prints the sudoers line).
cold_prepare_cmd() {
  case "$OS" in
    Darwin) echo 'sync; sudo -n /usr/sbin/purge' ;;
    *) echo "sync; echo 3 | sudo -n $(command -v tee) /proc/sys/vm/drop_caches > /dev/null" ;;
  esac
}
cold_allowed() {
  case "$OS" in
    Darwin) sudo -n -l /usr/sbin/purge > /dev/null 2>&1 ;;
    *) sudo -n -l "$(command -v tee)" /proc/sys/vm/drop_caches > /dev/null 2>&1 ;;
  esac
}

# Core pinning. PIN=<cpu list> (e.g. PIN=2,3) runs each measuring tool (hyperfine, time) under
# taskset, so the measured process inherits the affinity without an extra exec inside the timing.
# Linux only; ignored with a warning elsewhere.
PINPFX=()
setup_pin() {
  [ -n "${PIN:-}" ] || return 0
  if [ "$OS" = Linux ] && command -v taskset > /dev/null; then
    PINPFX=(taskset -c "$PIN")
  else
    echo "PIN=$PIN ignored: taskset is Linux only" >&2
  fi
}
# pinned <cmd...>: runs cmd under the PIN affinity, if any.
pinned() { ${PINPFX[@]+"${PINPFX[@]}"} "$@"; }

# probe <cmd-string>: output of a shell snippet, first non-empty value, or "unknown" on any failure.
probe() {
  local v
  v=$( (eval "$1") 2> /dev/null | sed -n '/./{p;q;}' ) || v=
  echo "${v:-unknown}"
}

# Storage behind a path: "<fstype> on <device> (<kind>)", kind = nvme / ssd / hdd / network / virtual disk.
storage_of() {
  local p=$1 src fs kind=unknown disk tran rota
  case "$OS" in
    Darwin)
      src=$(df "$p" | awk 'NR == 2 {print $1}')
      fs=$(mount | awk -v d="$src" '$1 == d {sub(/^\(/, "", $4); sub(/,$/, "", $4); print $4; exit}')
      if info=$(diskutil info "$src" 2> /dev/null); then
        case "$(echo "$info" | awk -F': *' '/Solid State/ {print $2}')" in
          Yes) kind="ssd, $(echo "$info" | awk -F': *' '/Protocol/ {print $2; exit}')" ;;
          No) kind=hdd ;;
        esac
      fi ;;
    *)
      src=$(findmnt -no SOURCE -T "$p" 2> /dev/null)
      fs=$(findmnt -no FSTYPE -T "$p" 2> /dev/null)
      case "$fs" in
        nfs*|cifs|smb*|fuse.sshfs|9p|virtiofs|ceph|glusterfs|lustre) kind=network ;;
        *)
          disk=$(lsblk -no PKNAME "$src" 2> /dev/null | sed -n '/./{p;q;}')
          [ -n "$disk" ] || disk=$(basename "$src")
          tran=$(lsblk -dno TRAN "/dev/$disk" 2> /dev/null | tr -d ' ')
          rota=$(lsblk -dno ROTA "/dev/$disk" 2> /dev/null | tr -d ' ')
          case "$tran:$rota:$disk" in
            nvme:*|*:*:nvme*) kind=nvme ;;
            *:1:*) kind=hdd ;;
            *:*:vd*|*:*:xvd*) kind="virtual disk" ;;
            *:0:*) kind=ssd ;;
          esac ;;
      esac ;;
  esac
  echo "${fs:-unknown} on ${src:-unknown} ($kind)"
}

# Mains power on Linux: "ac", "battery", or "unknown" when no mains supply is reported (most desktops;
# a peripheral's battery, such as a Bluetooth mouse, does not count).
power_linux() {
  local d seen=0
  for d in /sys/class/power_supply/*; do
    [ "$(cat "$d/type" 2> /dev/null)" = Mains ] || continue
    seen=1
    [ "$(cat "$d/online" 2> /dev/null)" = 1 ] && { echo ac; return; }
  done
  [ "$seen" = 1 ] && echo battery
}

# write_env <file> <corpus-dir>: the machine and toolchain a result came from. Never fails.
write_env() {
  local f=$1 corpus=$2 goose
  goose=${GOOSE:-$(goose_default 2> /dev/null)}
  {
    echo "date: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "git_commit: $(probe "git -C '$ROOT' describe --always --dirty --tags")"
    echo "kernel: $(probe 'uname -srm')"
    case "$OS" in
      Darwin)
        echo "os: $(probe 'echo "$(sw_vers -productName) $(sw_vers -productVersion)"')"
        echo "cpu_model: $(probe 'sysctl -n machdep.cpu.brand_string')"
        echo "cores_logical: $(probe 'sysctl -n hw.logicalcpu')"
        echo "cores_physical: $(probe 'sysctl -n hw.physicalcpu')"
        echo "cpu_governor: unknown (macOS has no governor)"
        echo "ram_total_kb: $(probe 'echo $(( $(sysctl -n hw.memsize) / 1024 ))')"
        echo "ram_free_kb: $(probe 'vm_stat | awk -v ps=$(sysctl -n hw.pagesize) "/Pages (free|inactive|speculative)/ {gsub(/\\./, \"\", \$NF); n += \$NF} END {if (n) print int(n * ps / 1024)}"')"
        echo "power: $(probe "pmset -g batt | sed -n \"1s/.*'\\(.*\\)'.*/\\1/p\"")" ;;
      *)
        echo "os: $(probe '. /etc/os-release && echo "$PRETTY_NAME"')"
        echo "cpu_model: $(probe "awk -F': ' '/^model name/ {print \$2; exit}' /proc/cpuinfo" | grep -v unknown || probe "lscpu | awk -F': *' '/^Model name/ {print \$2; exit}'")"
        echo "cores_logical: $(probe nproc)"
        echo "cores_physical: $(probe "lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l | tr -d ' '")"
        echo "cpu_governor: $(probe 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c | awk "{printf \"%s%s x%s\", s, \$2, \$1; s=\", \"} END {print \"\"}"')"
        echo "ram_total_kb: $(probe "awk '/^MemTotal/ {print \$2}' /proc/meminfo")"
        echo "ram_free_kb: $(probe "awk '/^MemAvailable/ {print \$2}' /proc/meminfo")"
        echo "power: $(probe 'power_linux')" ;;
    esac
    echo "load_avg: $(probe "uptime | sed 's/.*load averages*: //'")"
    echo "corpus_storage: $(storage_of "$corpus")"
    echo "goose: $(probe "'$goose' version")"
    echo "rustc: $(probe 'rustc -V')"
    echo "cargo: $(probe 'cargo -V')"
    echo "clang: $(probe 'clang --version')"
    echo "python3: $(probe 'python3 -V')"
    echo "sqlite (python3 module): $(probe "python3 -I -c 'import sqlite3; print(sqlite3.sqlite_version)'")"
    echo "sqlite3 cli: $(probe 'sqlite3 --version')"
    echo "ctags: $(probe 'ctags --version')"
    echo "hyperfine: $(probe 'hyperfine --version')"
    echo "cold: ${COLD:-0}"
    echo "pin: ${PIN:-none}"
    echo "runs: ${RUNS:-}"
    echo "ci: ${CI:-false}${GITHUB_RUN_ID:+ (github run $GITHUB_RUN_ID)}"
  } > "$f" 2> /dev/null || true
}

# The pinned Goose toolchain for this platform (goose/fetch-toolchain.sh installs it).
goose_default() {
  local plat
  case "$OS-$(uname -m)" in
    Linux-x86_64) plat=linux-x64 ;;
    Darwin-arm64) plat=macos-arm64 ;;
    Darwin-x86_64) plat=macos-x64 ;;
    *) return 1 ;;
  esac
  echo "$ROOT/toolchain/goose-v2026.3-$plat/goose"
}
