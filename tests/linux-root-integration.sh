#!/usr/bin/env bash
# Linux root-only integration test for host TCP/UDP attribution.
set -euo pipefail

[[ $(uname -s) == Linux ]] || { echo "SKIP: Linux only"; exit 0; }
[[ $EUID -eq 0 ]] || { echo "SKIP: run as root"; exit 0; }
command -v ip >/dev/null || { echo "SKIP: iproute2 is required for this test"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 is required for this test"; exit 0; }

COLLECTOR=${SMON_NET_BIN:-./smon-net}
[[ -x $COLLECTOR ]] || { echo "Build smon-net first: go build -o smon-net ./cmd/smon-net" >&2; exit 1; }

suffix=$$
namespace="smon-test-$suffix"
short_suffix=${suffix:0:8}
host_if="smh$short_suffix"
peer_if="smp$short_suffix"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/smon-net-test.XXXXXX")
server_pid=""; tcp_pid=""; udp_pid=""; collector_pid=""

cleanup() {
  for pid in "$collector_pid" "$tcp_pid" "$udp_pid" "$server_pid"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  ip netns del "$namespace" 2>/dev/null || true
  ip link del "$host_if" 2>/dev/null || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

ip netns add "$namespace"
ip link add "$host_if" type veth peer name "$peer_if"
ip link set "$peer_if" netns "$namespace"
ip addr add 10.203.0.1/24 dev "$host_if"
ip link set "$host_if" up
ip -n "$namespace" link set lo up
ip -n "$namespace" addr add 10.203.0.2/24 dev "$peer_if"
ip -n "$namespace" link set "$peer_if" up

ip netns exec "$namespace" python3 -u - <<'PY' &
import socket
import threading

def tcp_handler(conn):
    with conn:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                return
            conn.sendall(chunk)

def tcp_server():
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("10.203.0.2", 19090))
    sock.listen()
    while True:
        conn, _ = sock.accept()
        threading.Thread(target=tcp_handler, args=(conn,), daemon=True).start()

def udp_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("10.203.0.2", 19091))
    while True:
        data, peer = sock.recvfrom(65535)
        sock.sendto(data, peer)

threading.Thread(target=tcp_server, daemon=True).start()
udp_server()
PY
server_pid=$!

for _ in $(seq 1 50); do
  ip netns exec "$namespace" ss -ln 2>/dev/null | grep -q ':19090' && break
  sleep 0.05
done

python3 - "$work_dir/tcp.ready" "$work_dir/go" <<'PY' &
import os
import socket
import sys
import time

ready, trigger = sys.argv[1:]
sock = socket.create_connection(("10.203.0.2", 19090))
open(ready, "w").close()
while not os.path.exists(trigger):
    time.sleep(0.01)
payload = b"t" * 32768
for _ in range(256):
    sock.sendall(payload)
    received = 0
    while received < len(payload):
        received += len(sock.recv(len(payload) - received))
sock.close()
time.sleep(3)
PY
tcp_pid=$!

python3 - "$work_dir/udp.ready" "$work_dir/go" <<'PY' &
import os
import socket
import sys
import time

ready, trigger = sys.argv[1:]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.connect(("10.203.0.2", 19091))
sock.settimeout(2)
open(ready, "w").close()
while not os.path.exists(trigger):
    time.sleep(0.01)
payload = b"u" * 1400
for _ in range(1600):
    sock.send(payload)
    sock.recv(2048)
sock.close()
time.sleep(3)
PY
udp_pid=$!

for _ in $(seq 1 100); do
  [[ -f $work_dir/tcp.ready && -f $work_dir/udp.ready ]] && break
  sleep 0.02
done
[[ -f $work_dir/tcp.ready && -f $work_dir/udp.ready ]] || { echo "clients did not become ready" >&2; exit 1; }

read -r rx_before tx_before < <(awk -v dev="$host_if" '$1==dev":" {print $2, $10}' /proc/net/dev)
"$COLLECTOR" --interface "$host_if" --interval 2s --output "$work_dir/net.tsv" --once &
collector_pid=$!
sleep 0.3
touch "$work_dir/go"

# These connections are intentionally created after the resolver scan.
python3 - <<'PY'
import socket
for _ in range(20):
    with socket.create_connection(("10.203.0.2", 19090)) as sock:
        sock.sendall(b"short connection")
        sock.recv(64)
PY

wait "$tcp_pid"
wait "$udp_pid"
wait "$collector_pid"
read -r rx_after tx_after < <(awk -v dev="$host_if" '$1==dev":" {print $2, $10}' /proc/net/dev)

assert_endpoint_rate() {
  local label=$1; shift
  local pid rates rx tx
  for pid in "$@"; do
    rates=$(awk -F '\t' -v pid="$pid" '$1=="P" && $2==pid {print $4, $5}' "$work_dir/net.tsv")
    read -r rx tx <<<"$rates"
    if [[ ${rx:-0} -gt 100 && ${tx:-0} -gt 100 ]]; then
      return 0
    fi
  done
  echo "$label endpoint PIDs missing bidirectional attribution (candidates: $*)" >&2
  cat "$work_dir/net.tsv" >&2
  exit 1
}

# With cgroup-skb on a veth pair, ingress and egress may be observed at the
# namespace-side endpoint. Accept either participating PID, but never unknown.
assert_endpoint_rate TCP "$tcp_pid" "$server_pid"
assert_endpoint_rate UDP "$udp_pid" "$server_pid"

# shellcheck disable=SC2034 # Read every metadata field to validate its column position.
IFS=$'\t' read -r kind version _ interval_ms iface cap_rx cap_tx unknown_rx unknown_tx packets drops unsupported_rx unsupported_tx unmatched_rx unmatched_tx ambiguous_rx ambiguous_tx exited_rx exited_tx source status scope reason <"$work_dir/net.tsv"
[[ $kind == M && $version == 4 && $iface == "$host_if" ]] || { echo "invalid metadata" >&2; exit 1; }
[[ $source == ebpf_cgroup && $status == ok && $scope == host_and_containers ]] || { echo "eBPF cgroup mode was not active: $source/$status/$scope $reason" >&2; exit 1; }
[[ $packets -gt 0 ]] || { echo "no packets captured" >&2; exit 1; }
[[ $drops -eq 0 ]] || { echo "capture dropped $drops packets" >&2; exit 1; }
[[ $(( unknown_rx + unknown_tx )) -gt 0 ]] || { echo "short connections were not reported as unknown" >&2; exit 1; }
[[ $(( unmatched_rx + unmatched_tx )) -gt 0 ]] || { echo "short connections were not reported as unmatched" >&2; exit 1; }

process_rx=$(awk -F '\t' '$1=="P" {sum+=$4} END {print sum+0}' "$work_dir/net.tsv")
process_tx=$(awk -F '\t' '$1=="P" {sum+=$5} END {print sum+0}' "$work_dir/net.tsv")

assert_coverage() {
  local captured=$1 covered=$2 direction=$3
  awk -v captured="$captured" -v covered="$covered" -v direction="$direction" 'BEGIN {
    diff=captured-covered; if (diff<0) diff=-diff
    tolerance=captured*0.10+20
    if (diff>tolerance) {
      printf "%s coverage mismatch: captured=%d covered=%d\n", direction, captured, covered > "/dev/stderr"
      exit 1
    }
  }'
}
assert_coverage "$cap_rx" "$(( process_rx + unknown_rx ))" RX
assert_coverage "$cap_tx" "$(( process_tx + unknown_tx ))" TX

assert_interface_delta() {
  local captured_kbs=$1 before=$2 after=$3 direction=$4
  awk -v rate="$captured_kbs" -v ms="$interval_ms" -v before="$before" -v after="$after" -v direction="$direction" 'BEGIN {
    captured=rate*1024*ms/1000
    interface_bytes=after-before
    diff=captured-interface_bytes; if (diff<0) diff=-diff
    # AF_PACKET sees both veth observation points on local namespace traffic.
    doubled=interface_bytes*2
    doubled_diff=captured-doubled; if (doubled_diff<0) doubled_diff=-doubled_diff
    if (doubled_diff<diff) {diff=doubled_diff; expected=doubled} else {expected=interface_bytes}
    tolerance=expected*0.10+65536
    if (diff>tolerance) {
      printf "%s /proc mismatch: capture=%.0f interface=%.0f\n", direction, captured, interface_bytes > "/dev/stderr"
      exit 1
    }
  }'
}
assert_interface_delta "$cap_rx" "$rx_before" "$rx_after" RX
assert_interface_delta "$cap_tx" "$tx_before" "$tx_after" TX

mode=$(stat -c '%a' "$work_dir/net.tsv")
[[ $mode == 600 ]] || { echo "snapshot mode is $mode, want 600" >&2; exit 1; }
echo "PASS: TCP/UDP bidirectional attribution, unknown accounting, coverage, and interface totals"
