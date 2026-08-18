#!/usr/bin/env bash
# Usage: sudo tests/linux-performance.sh IFACE -- workload [args...]
# Example: sudo tests/linux-performance.sh eno1 -- iperf3 -c PEER -t 600
set -euo pipefail

[[ $(uname -s) == Linux ]] || { echo "SKIP: Linux only"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ $# -ge 3 && $2 == -- ]] || {
  echo "Usage: sudo $0 IFACE -- workload [args...]" >&2
  exit 2
}

interface=$1
shift 2
collector=${SMON_NET_BIN:-./smon-net}
expected_seconds=${SMON_PERF_SECONDS:-600}
[[ $expected_seconds =~ ^[1-9][0-9]*$ ]] || { echo "SMON_PERF_SECONDS must be an integer" >&2; exit 2; }
[[ -x $collector ]] || { echo "Collector not executable: $collector" >&2; exit 1; }

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/smon-net-perf.XXXXXX")
snapshot="$work_dir/net.tsv"
collector_pid=""; workload_pid=""

cleanup() {
  [[ -z $workload_pid ]] || kill "$workload_pid" 2>/dev/null || true
  [[ -z $collector_pid ]] || kill "$collector_pid" 2>/dev/null || true
  [[ -z $collector_pid ]] || wait "$collector_pid" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

read_cpu_ticks() {
  local stat
  IFS= read -r stat <"/proc/$1/stat"
  stat=${stat##*) }
  # shellcheck disable=SC2086
  set -- $stat
  echo "$(( ${12:-0} + ${13:-0} ))"
}

"$collector" --interface "$interface" --interval 1s --output "$snapshot" &
collector_pid=$!
for _ in $(seq 1 30); do
  [[ -r $snapshot ]] && break
  sleep 0.1
done
kill -0 "$collector_pid" 2>/dev/null || { echo "collector failed to start" >&2; exit 1; }

clock_ticks=$(getconf CLK_TCK)
cpu_start=$(read_cpu_ticks "$collector_pid")
started=$(date +%s)
max_rss_kb=0
total_drops=0
last_snapshot_ts=0

"$@" &
workload_pid=$!
while kill -0 "$workload_pid" 2>/dev/null; do
  rss=$(awk '/VmRSS:/ {print $2; exit}' "/proc/$collector_pid/status" 2>/dev/null || echo 0)
  [[ ${rss:-0} =~ ^[0-9]+$ ]] || rss=0
  (( rss > max_rss_kb )) && max_rss_kb=$rss
  if [[ -r $snapshot ]]; then
    IFS=$'\t' read -r kind _ timestamp _ _ _ _ _ _ _ drops <"$snapshot" || true
    if [[ $kind == M && $timestamp =~ ^[0-9]+$ && $drops =~ ^[0-9]+$ && $timestamp != "$last_snapshot_ts" ]]; then
      total_drops=$(( total_drops + drops ))
      last_snapshot_ts=$timestamp
    fi
  fi
  sleep 1
done
workload_status=0
wait "$workload_pid" || workload_status=$?
workload_pid=""

finished=$(date +%s)
cpu_end=$(read_cpu_ticks "$collector_pid")
elapsed=$(( finished - started )); (( elapsed < 1 )) && elapsed=1
kill "$collector_pid" 2>/dev/null || true
wait "$collector_pid" 2>/dev/null || true
collector_pid=""

avg_cpu=$(awk -v delta="$(( cpu_end - cpu_start ))" -v hz="$clock_ticks" -v seconds="$elapsed" 'BEGIN {printf "%.1f", delta*100/hz/seconds}')
echo "elapsed=${elapsed}s avg_cpu=${avg_cpu}% max_rss=${max_rss_kb}KB drops=${total_drops} workload_status=${workload_status}"

(( workload_status == 0 )) || { echo "workload failed" >&2; exit "$workload_status"; }
(( elapsed * 100 >= expected_seconds * 95 )) || { echo "workload ended before the expected duration" >&2; exit 1; }
awk -v cpu="$avg_cpu" 'BEGIN {exit !(cpu <= 50.0)}' || { echo "average collector CPU exceeds half a core" >&2; exit 1; }
(( max_rss_kb <= 65536 )) || { echo "collector RSS exceeds 64 MB" >&2; exit 1; }
(( total_drops == 0 )) || { echo "collector reported packet drops" >&2; exit 1; }

echo "PASS: collector stayed within CPU/RSS/drop targets"
