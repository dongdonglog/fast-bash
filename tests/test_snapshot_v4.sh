#!/usr/bin/env bash
set -euo pipefail

[[ $(uname -s) == Linux ]] || exit 0

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

iface=$(awk '$2=="00000000"{print $1; exit}' /proc/net/route)
[[ -n $iface ]] || exit 0
cid=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

run_case() {
  local version=$1 now_ms output="$work/output-$1.json"
  now_ms=$(date +%s%3N)
  case $version in
    1) printf 'M\t1\t%s\t1000\t%s\t100\t50\t10\t5\t10\t0\n' "$now_ms" "$iface" >"$work/net.tsv" ;;
    2) printf 'M\t2\t%s\t1000\t%s\t100\t50\t10\t5\t10\t0\t0\t0\t10\t5\t0\t0\t0\t0\n' "$now_ms" "$iface" >"$work/net.tsv" ;;
    3)
      printf 'M\t3\t%s\t1000\t%s\t100\t50\t0\t0\t10\t0\t0\t0\t0\t0\t0\t0\t0\t0\tebpf_cgroup\tok\thost_and_containers\t-\n' "$now_ms" "$iface" >"$work/net.tsv"
      printf 'C\t99\tprod\tapi-1\tapi\t%s\t80\t20\tcgroup\n' "$cid" >>"$work/net.tsv"
      ;;
    4)
      printf 'M\t4\t%s\t1000\t%s\t100\t50\t0\t0\t10\t0\t0\t0\t0\t0\t0\t0\t0\t0\tebpf_cgroup\tok\thost_and_containers\t-\n' "$now_ms" "$iface" >"$work/net.tsv"
      printf 'C\t99\tcontainer\tdocker\t-\t-\tweb\t%s\t80\t20\tcgroup\n' "$cid" >>"$work/net.tsv"
      printf 'W\t99\tcontainer\tdocker\t-\t-\tweb\t%s\t/\tcgroup\n' "$cid" >>"$work/net.tsv"
      ;;
  esac
  SMON_NET_SNAPSHOT="$work/net.tsv" SMON_NETIF="$iface" "$root/smon.sh" -j -i 1 >"$output"
  python3 - "$output" "$version" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
version = int(sys.argv[2])
assert payload["net_attribution"]["source"] == ("af_packet" if version < 3 else "ebpf_cgroup")
if version < 3:
    raise SystemExit
entity = next(item for item in payload["network_entities"] if item["container_id"].startswith("aaaaaaaaaaaa"))
assert entity["scope"] == ("pod" if version == 3 else "container"), entity
assert entity["runtime"] == ("containerd" if version == 3 else "docker"), entity
assert entity["container"] == ("api" if version == 3 else "web"), entity
assert entity["recv_kbs"] == 80 and entity["sent_kbs"] == 20, entity
PY
}

for version in 1 2 3 4; do
  run_case "$version"
done
