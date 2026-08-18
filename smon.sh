#!/usr/bin/env bash
#
# smon - 中文进程占用实时排障工具
# 以进程为核心，一打开就知道是谁占用了 CPU / 内存 / 磁盘 IO / 网络。
# 用法:  smon [选项]
set -o pipefail

VERSION="0.5.0"
INTERVAL=5
INTERVAL_SET=0
SORT_KEY=cpu
JSON_MODE=0
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
PRIVILEGED=0; [[ $EUID -eq 0 ]] && PRIVILEGED=1
BASEDIR=$(mktemp -d "${TMPDIR:-/tmp}/smon.XXXXXX") || exit 1
NETIF=""
NET_COLLECTOR_PID=""
NET_COLLECTOR_ERROR=""
NET_SNAPSHOT=""
SMON_EXCLUDE_PIDS="${SMON_EXCLUDE_PIDS:-},$$"
if [[ $(uname -s) == Linux ]]; then declare -A PID_PARENT; fi

# 颜色
C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_CYN=$'\e[36m'
C_BLD=$'\e[1m'; C_OFF=$'\e[0m'

restore_tty() { stty sane 2>/dev/null; }
TUI_RUNNING=0
cleanup() {
  if [[ -n $NET_COLLECTOR_PID ]]; then
    kill "$NET_COLLECTOR_PID" 2>/dev/null || true
    wait "$NET_COLLECTOR_PID" 2>/dev/null || true
  fi
  rm -rf "$BASEDIR"
  restore_tty
  (( TUI_RUNNING )) && tput cnorm 2>/dev/null
}
trap 'exit 1' INT TERM
trap 'cleanup' EXIT

profile_mark() {
  [[ ${SMON_PROFILE:-0} == 1 ]] && printf '[smon-profile] %s %s\n' "$(date +%s%3N)" "$1" >&2
  return 0
}

usage() {
  cat <<EOF
smon v$VERSION - 中文进程占用实时排障工具

用法:
  smon                实时进程表（默认按 CPU 排序，每 $INTERVAL 秒刷新）
  smon -m             按内存排序
  smon -d             按磁盘 IO 排序
  smon -n             按网络排序
  smon -i 秒          刷新间隔
  smon -j | --json    输出一次 JSON（供脚本 / Web 面板对接）
  smon --serve [端口] 启动 Web 面板（浏览器可视化，默认 8080，需 python3）
  smon -h             帮助

交互快捷键（实时模式）:
  c=按CPU  m=按内存  d=按磁盘IO  n=按网络  q=退出

数据来源（Linux）: /proc/<pid>/stat, status, io; /proc/net/dev; smon-net(AF_PACKET)
  * CPU% 为单个核心百分比（100% = 吃满一核）
  * 磁盘 IO 需 root 才能读取其他用户进程
  * 网络：同一网卡总收/总发 + 每进程 TCP/UDP 带宽（AF_PACKET，默认需 root）
  * smon-net 不可用时降级到 ss -i，并明确标记为"仅部分 TCP"
  * 占用高自动高亮: 红(≥90%) 黄(≥60%) 绿(正常)
EOF
}

# 预处理长选项（并从参数中剔除，避免 getopts 报错）
SERVE=0; SERVE_PORT=8080; prev=""; filtered=()
for a in "$@"; do
  case "$a" in
    --json) JSON_MODE=1; prev=$a; continue ;;
    --serve) SERVE=1; prev=$a; continue ;;
    *)
      if [[ $prev == "--serve" && $a =~ ^[0-9]+$ ]]; then SERVE_PORT=$a; prev=""; continue; fi
      filtered+=("$a"); prev="" ;;
  esac
done
set -- "${filtered[@]}"
while getopts "mdni:jh" opt; do
  case "$opt" in
    m) SORT_KEY=mem ;;
    d) SORT_KEY=disk ;;
    n) SORT_KEY=net ;;
    i) INTERVAL="$OPTARG"; INTERVAL_SET=1 ;;
    j) JSON_MODE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ ! $INTERVAL =~ ^[1-9][0-9]*$ ]] || (( INTERVAL > 60 )); then
  echo "刷新间隔必须是 1 到 60 秒的整数" >&2
  exit 2
fi
if (( JSON_MODE && INTERVAL_SET == 0 )); then INTERVAL=1; fi

if [[ -d /proc && -r /proc/stat ]]; then OS=linux; else OS=macos; fi

# ------------------------- 系统指标（一次采样，供汇总/诊断/JSON 复用）---------
CPU_SYS=0; MEM_USED=0; MEM_TOTAL=0; SWAP_USED=0; SWAP_TOTAL=0; L1=0; L5=0; L15=0; DISK_USE=0
load_sys_stats() {
  local raw id1 pt pide
  if [[ $OS == linux ]]; then
    read -r raw id1 < <(cpu_total); if [[ ${SMON_FAST:-0} == 1 ]]; then sleep 0.1; else sleep 0.3; fi; read -r pt pide < <(cpu_total)
    CPU_SYS=0
    if (( (pt-raw) > 0 )); then CPU_SYS=$(( (pt-raw-(pide-id1)) * 100 / (pt-raw) )); fi
    MEM_TOTAL=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
    MEM_USED=$(awk '/MemAvailable:/{m=$2} END{print int((mt-m)/1024)}' mt="$MEM_TOTAL" /proc/meminfo)
    MEM_TOTAL=$(( MEM_TOTAL / 1024 ))
    read -r SWAP_TOTAL SWAP_USED < <(awk '/SwapTotal:/{t=$2}/SwapFree:/{f=$2}END{print int(t/1024),int((t-f)/1024)}' /proc/meminfo)
    read -r L1 L5 L15 _ < <(cat /proc/loadavg 2>/dev/null || echo "0 0 0")
    DISK_USE=$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    DISK_USE=${DISK_USE:-0}
  else
    CPU_SYS=$(ps -A -o %cpu= | awk '{s+=$1} END{printf "%d",s/NR}')
    MEM_TOTAL=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    local free_pct
    free_pct=$(memory_pressure -Q 2>/dev/null | awk -F': ' '/System-wide memory free percentage/{gsub(/%/,"",$2); print $2}')
    MEM_USED=$(( MEM_TOTAL * (100 - ${free_pct:-100}) / 100 ))
    read -r L1 L5 L15 _ < <(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1, $2, $3}')
  fi
}

# ------------------------- Linux 采集 -------------------------
cpu_total() {  # 输出 "total idle"
  local line
  line=$(grep '^cpu ' /proc/stat)
  # shellcheck disable=SC2086
  set -- $line
  local idle=$5 iowait=$6
  echo "$(( $2 + $3 + $4 + idle + iowait + $7 + $8 + $9 )) $(( idle + iowait ))"
}

net_dev_total() {  # 输出选定网卡的 "rx_bytes tx_bytes"
  awk -v dev="$NETIF" 'NR>2 {gsub(/:/,"",$1); if ($1==dev) {print $2+0, $10+0; found=1; exit}} END{if(!found) print "0 0"}' /proc/net/dev 2>/dev/null
}

# 快速读取器：全部用 bash 内建（无外部子进程），结果写入全局变量
T_TICKS1=0; T_TICKS2=0; T_START=0; T_STATE=""
read_ticks() {  # $1=pid -> $T_TICKS1 $T_TICKS2 $T_START $T_STATE
  local pid=$1 s
  T_TICKS1=0; T_TICKS2=0; T_START=0; T_STATE=""
  [[ -r "/proc/$pid/stat" ]] || return 0
  IFS= read -r s <"/proc/$pid/stat"
  s=${s##*) }
  # shellcheck disable=SC2086
  set -- $s
  T_STATE=${1:-}
  T_TICKS1=${12:-0}; T_TICKS2=${13:-0}; T_START=${20:-0}
}

RSSKB=0
read_rss() {  # $1=pid -> $RSSKB
  local pid=$1 s
  RSSKB=0
  [[ -r "/proc/$pid/status" ]] || return 0
  IFS= read -rd '' s <"/proc/$pid/status" || true
  [[ $s == *VmRSS:* ]] || return 0
  s=${s#*VmRSS:}; s=${s%%kB*}; RSSKB=${s//[!0-9]/}
}

IO_R=0; IO_W=0
read_io() {  # $1=pid -> $IO_R $IO_W
  local pid=$1 s
  IO_R=0; IO_W=0
  [[ -r "/proc/$pid/io" ]] || return 0
  IFS= read -rd '' s <"/proc/$pid/io" || true
  [[ $s == *read_bytes:* ]] || return 0
  s=${s#*read_bytes:}; IO_R=${s%%$'\n'*}; IO_R=${IO_R//[!0-9]/}
  [[ $s == *write_bytes:* ]] || return 0
  s=${s#*write_bytes:}; IO_W=${s%%$'\n'*}; IO_W=${IO_W//[!0-9]/}
}

CMDLINE=""
read_cmdline() {  # $1=pid -> $CMDLINE
  local pid=$1 arg
  CMDLINE=""
  [[ -r "/proc/$pid/cmdline" ]] || return 0
  while IFS= read -r -d '' arg; do
    arg=${arg//$'\n'/ }; arg=${arg//$'\r'/ }; arg=${arg//$'\t'/ }
    CMDLINE+="${CMDLINE:+ }$arg"
  done <"/proc/$pid/cmdline"
}

NUMOUT=0
num() {  # 强制转为数字（防字段错位），结果写入 $NUMOUT（无子进程）
  local v=${1:-0}
  [[ $v =~ ^-?[0-9]+$ ]] && NUMOUT=$v || NUMOUT=0
}

ss_bw() {  # 输出 "pid bytes_acked bytes_received"（TCP 每连接累计字节，来自内核 TCP_INFO，纯内置）
  ss -iepn 2>/dev/null | awk '
    /^tcp/ {
      pid=""
      if (match($0, /pid=[0-9]+/)) pid=substr($0, RSTART+4, RLENGTH-4)
      getline
      a=0; r=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^bytes_acked:/) { sub(/^bytes_acked:/,"",$i); a=$i }
        else if ($i ~ /^bytes_received:/) { sub(/^bytes_received:/,"",$i); r=$i }
      }
      if (pid ~ /^[0-9]+$/ && pid != 0) print pid, a, r
    }'
}

# ------------------------- 每进程网络归属 -------------------------
if [[ $OS == linux ]]; then
  declare -A AF_RX AF_TX AF_START AF_SCOPE AF_NAMESPACE AF_POD AF_CONTAINER AF_CONTAINER_ID AF_ATTRIBUTION
  declare -A WL_NAMESPACE WL_POD WL_CONTAINER
else
  declare -a AF_RX AF_TX AF_START AF_SCOPE AF_NAMESPACE AF_POD AF_CONTAINER AF_CONTAINER_ID AF_ATTRIBUTION
  declare -a WL_NAMESPACE WL_POD WL_CONTAINER
fi
NET_ENTITIES=()
NET_ATTR_SOURCE="ss_tcp_info"
NET_ATTR_STATUS="partial"
NET_ATTR_PROTOCOLS='["tcp"]'
NET_ATTR_INTERVAL_MS=0
NET_ATTR_PERCENT=0
NET_ATTR_UNKNOWN_RX=0
NET_ATTR_UNKNOWN_TX=0
NET_ATTR_PACKETS=0
NET_ATTR_DROPS=0
NET_ATTR_REASON="smon-net 快照尚未就绪"
NET_ATTR_SCOPE="host_network_namespace"
NET_UNSUPPORTED_RX=0; NET_UNSUPPORTED_TX=0
NET_UNMATCHED_RX=0; NET_UNMATCHED_TX=0
NET_AMBIGUOUS_RX=0; NET_AMBIGUOUS_TX=0
NET_EXITED_RX=0; NET_EXITED_TX=0

refresh_pid_parents() {
  [[ $OS == linux ]] || return 0
  PID_PARENT=()
  local pid parent
  while read -r pid parent; do
    [[ $pid =~ ^[0-9]+$ && $parent =~ ^[0-9]+$ ]] && PID_PARENT[$pid]=$parent
  done < <(ps -eo pid=,ppid= 2>/dev/null)
}

is_excluded_pid() {
  local pid=$1 list=",${SMON_EXCLUDE_PIDS#,}," parent="" hops=0
  while [[ $pid =~ ^[0-9]+$ && $pid != 0 && $hops -lt 16 ]]; do
    [[ $list == *",$pid,"* ]] && return 0
    parent=${PID_PARENT[$pid]:-}
    [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || break
    pid=$parent
    ((hops++))
  done
  return 1
}

find_net_collector() {
  local script_dir candidate
  [[ $OS == linux ]] || return 1
  if [[ -n ${SMON_NET_BIN:-} && -x ${SMON_NET_BIN:-} ]]; then
    printf '%s\n' "$SMON_NET_BIN"
    return 0
  fi
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  candidate="$script_dir/smon-net"
  if [[ -x $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  command -v smon-net 2>/dev/null
}

start_net_collector() {  # $1=once|continuous
  local mode=${1:-continuous} collector once_args=()
  [[ $OS == linux ]] || { NET_COLLECTOR_ERROR="当前平台不支持 AF_PACKET"; return 1; }
  [[ -n $NETIF ]] || { NET_COLLECTOR_ERROR="未找到主路由网卡"; return 1; }
  NET_SNAPSHOT=${SMON_NET_SNAPSHOT:-"$BASEDIR/net.tsv"}
  if [[ -n ${SMON_NET_SNAPSHOT:-} ]]; then return 0; fi
  collector=$(find_net_collector) || { NET_COLLECTOR_ERROR="未找到 smon-net"; return 1; }
  [[ $mode == once ]] && once_args=(--once)
  "$collector" --interface "$NETIF" --interval "${SMON_NET_INTERVAL:-1s}" \
    --output "$NET_SNAPSHOT" "${once_args[@]}" 2>"$BASEDIR/smon-net.err" &
  NET_COLLECTOR_PID=$!
}

wait_net_collector_once() {
  local rc=0 detail
  [[ -n $NET_COLLECTOR_PID ]] || return 0
  wait "$NET_COLLECTOR_PID" || rc=$?
  NET_COLLECTOR_PID=""
  if (( rc != 0 )); then
    detail=$(head -n 1 "$BASEDIR/smon-net.err" 2>/dev/null || true)
    if [[ $detail == *"operation not permitted"* || $detail == *"permission denied"* || $detail == *"Operation not permitted"* ]]; then
      NET_COLLECTOR_ERROR="AF_PACKET 权限不足，请使用 sudo smon"
    elif [[ -n $detail ]]; then
      NET_COLLECTOR_ERROR=$detail
    else
      NET_COLLECTOR_ERROR="smon-net 退出（状态 $rc）"
    fi
  fi
  return 0
}

ensure_net_collector() {
  [[ $OS == linux && -z ${SMON_NET_SNAPSHOT:-} ]] || return 0
  if [[ -n $NET_COLLECTOR_PID ]] && kill -0 "$NET_COLLECTOR_PID" 2>/dev/null; then return 0; fi
  [[ -z $NET_COLLECTOR_PID ]] || wait_net_collector_once
  start_net_collector continuous || true
}

set_net_fallback() {
  AF_RX=(); AF_TX=(); AF_START=(); AF_SCOPE=(); AF_NAMESPACE=(); AF_POD=(); AF_CONTAINER=(); AF_CONTAINER_ID=(); AF_ATTRIBUTION=()
  WL_NAMESPACE=(); WL_POD=(); WL_CONTAINER=(); NET_ENTITIES=()
  NET_ATTR_SOURCE="ss_tcp_info"
  NET_ATTR_STATUS="partial"
  NET_ATTR_PROTOCOLS='["tcp"]'
  NET_ATTR_INTERVAL_MS=$(( INTERVAL * 1000 ))
  NET_ATTR_PERCENT=0
  NET_ATTR_UNKNOWN_RX=0
  NET_ATTR_UNKNOWN_TX=0
  NET_ATTR_PACKETS=0
  NET_ATTR_DROPS=0
  NET_UNSUPPORTED_RX=0; NET_UNSUPPORTED_TX=0
  NET_UNMATCHED_RX=0; NET_UNMATCHED_TX=0
  NET_AMBIGUOUS_RX=0; NET_AMBIGUOUS_TX=0
  NET_EXITED_RX=0; NET_EXITED_TX=0
  NET_ATTR_REASON=${NET_COLLECTOR_ERROR:-${SMON_NET_FALLBACK_REASON:-"smon-net 快照缺失或已过期"}}
  NET_ATTR_SCOPE="host_network_namespace"
  if [[ $OS != linux ]]; then
    NET_ATTR_SOURCE="unsupported"
    NET_ATTR_STATUS="unavailable"
    NET_ATTR_PROTOCOLS='[]'
    NET_ATTR_REASON="当前平台不支持 AF_PACKET"
  fi
}

load_net_snapshot() {
  local kind version ts interval_ms iface cap_rx cap_tx unknown_rx unknown_tx packets drops
  local unsupported_rx unsupported_tx unmatched_rx unmatched_tx ambiguous_rx ambiguous_tx exited_rx exited_tx
  local meta_source meta_status meta_scope meta_reason scope pid start rx tx now age max_age total attributed ns pod container cid attribution cgroup_id
  set_net_fallback
  [[ $OS == linux ]] || return 1
  NET_SNAPSHOT=${SMON_NET_SNAPSHOT:-${NET_SNAPSHOT:-"$BASEDIR/net.tsv"}}
  [[ -r $NET_SNAPSHOT ]] || return 1
  IFS=$'\t' read -r kind version ts interval_ms iface cap_rx cap_tx unknown_rx unknown_tx packets drops unsupported_rx unsupported_tx unmatched_rx unmatched_tx ambiguous_rx ambiguous_tx exited_rx exited_tx meta_source meta_status meta_scope meta_reason <"$NET_SNAPSHOT" || return 1
  [[ $kind == M && ( $version == 1 || $version == 2 || $version == 3 ) && $iface == "$NETIF" ]] || {
    NET_ATTR_REASON="smon-net 快照格式或网卡不匹配"
    return 1
  }
  for value in "$ts" "$interval_ms" "$cap_rx" "$cap_tx" "$unknown_rx" "$unknown_tx" "$packets" "$drops"; do
    [[ $value =~ ^[0-9]+$ ]] || { NET_ATTR_REASON="smon-net 快照字段无效"; return 1; }
  done
  if [[ $version == 2 || $version == 3 ]]; then
    for value in "$unsupported_rx" "$unsupported_tx" "$unmatched_rx" "$unmatched_tx" "$ambiguous_rx" "$ambiguous_tx" "$exited_rx" "$exited_tx"; do
      [[ $value =~ ^[0-9]+$ ]] || { NET_ATTR_REASON="smon-net v2 分类字段无效"; return 1; }
    done
  else
    unsupported_rx=0; unsupported_tx=0; unmatched_rx=$unknown_rx; unmatched_tx=$unknown_tx
    ambiguous_rx=0; ambiguous_tx=0; exited_rx=0; exited_tx=0
  fi
  now=$(date +%s)
  age=$(( now - ts / 1000 )); (( age < 0 )) && age=0
  max_age=$(( interval_ms * 3 / 1000 + 2 )); (( max_age < 3 )) && max_age=3
  if (( age > max_age )); then
    NET_ATTR_REASON="smon-net 快照已过期 ${age}s"
    return 1
  fi

  while IFS=$'\t' read -r kind pid start rx tx scope ns pod container cid attribution; do
    if [[ $kind == P && $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $rx =~ ^[0-9]+$ && $tx =~ ^[0-9]+$ ]]; then
      [[ $scope == - || -z $scope ]] && scope=host
      [[ $ns == - ]] && ns=""; [[ $pod == - ]] && pod=""; [[ $container == - ]] && container=""; [[ $cid == - ]] && cid=""; [[ $attribution == - ]] && attribution=""
      AF_START[$pid]=$start; AF_RX[$pid]=$rx; AF_TX[$pid]=$tx; AF_SCOPE[$pid]=$scope
      AF_NAMESPACE[$pid]=$ns; AF_POD[$pid]=$pod; AF_CONTAINER[$pid]=$container; AF_CONTAINER_ID[$pid]=$cid; AF_ATTRIBUTION[$pid]=$attribution
      if [[ -n $cid ]]; then WL_NAMESPACE[$cid]=$ns; WL_POD[$cid]=$pod; WL_CONTAINER[$cid]=$container; fi
    fi
  done < <(tail -n +2 "$NET_SNAPSHOT" 2>/dev/null)
  if [[ $version == 3 ]]; then
    while IFS=$'\t' read -r kind cgroup_id ns pod container cid rx tx attribution; do
      [[ $kind == C && $cgroup_id =~ ^[0-9]+$ && $rx =~ ^[0-9]+$ && $tx =~ ^[0-9]+$ ]] || continue
      [[ $ns == - ]] && ns=""; [[ $pod == - ]] && pod=""; [[ $container == - ]] && container=""; [[ $cid == - ]] && cid=""; [[ $attribution == - ]] && attribution="cgroup"
      NET_ENTITIES+=("$cgroup_id"$'\t'"$ns"$'\t'"$pod"$'\t'"$container"$'\t'"$cid"$'\t'"$rx"$'\t'"$tx"$'\t'"$attribution")
      if [[ -n $cid ]]; then WL_NAMESPACE[$cid]=$ns; WL_POD[$cid]=$pod; WL_CONTAINER[$cid]=$container; fi
    done < <(tail -n +2 "$NET_SNAPSHOT" 2>/dev/null)
  fi
  total=$(( cap_rx + cap_tx ))
  attributed=$(( total - unknown_rx - unknown_tx )); (( attributed < 0 )) && attributed=0
  if (( total > 0 )); then NET_ATTR_PERCENT=$(( attributed * 100 / total )); else NET_ATTR_PERCENT=100; fi
  (( NET_ATTR_PERCENT > 100 )) && NET_ATTR_PERCENT=100
  if [[ $version == 3 ]]; then
    [[ $meta_source == - || -z $meta_source ]] && meta_source="af_packet_fallback"
    [[ $meta_status == - || -z $meta_status ]] && meta_status="partial"
    [[ $meta_scope == - || -z $meta_scope ]] && meta_scope="host_network_namespace"
    [[ $meta_reason == - ]] && meta_reason=""
    NET_ATTR_SOURCE=$meta_source; NET_ATTR_STATUS=$meta_status; NET_ATTR_SCOPE=$meta_scope; NET_ATTR_REASON=$meta_reason
  else
    NET_ATTR_SOURCE="af_packet"; NET_ATTR_STATUS="ok"; NET_ATTR_SCOPE="host_network_namespace"; NET_ATTR_REASON=""
  fi
  NET_ATTR_PROTOCOLS='["tcp", "udp"]'
  NET_ATTR_INTERVAL_MS=$interval_ms
  NET_ATTR_UNKNOWN_RX=$unknown_rx
  NET_ATTR_UNKNOWN_TX=$unknown_tx
  NET_ATTR_PACKETS=$packets
  NET_ATTR_DROPS=$drops
  NET_UNSUPPORTED_RX=$unsupported_rx; NET_UNSUPPORTED_TX=$unsupported_tx
  NET_UNMATCHED_RX=$unmatched_rx; NET_UNMATCHED_TX=$unmatched_tx
  NET_AMBIGUOUS_RX=$ambiguous_rx; NET_AMBIGUOUS_TX=$ambiguous_tx
  NET_EXITED_RX=$exited_rx; NET_EXITED_TX=$exited_tx
  return 0
}

linux_snapshot() {  # 建立基线: 每文件 "utime stime rss rbytes wbytes user"
  profile_mark snapshot_start
  local pid u state
  mkdir -p "$BASEDIR" 2>/dev/null || return 1
  cpu_total >"$BASEDIR/cpu_total"   # 保存整体 CPU 基线（供 collect 算差值）
  net_dev_total >"$BASEDIR/net_dev" # 保存总流量基线（供 collect 算速率）
  if [[ -n ${SMON_NET_SNAPSHOT:-} ]]; then
    : >"$BASEDIR/net_bw"
  else
    ss_bw >"$BASEDIR/net_bw"        # 仅降级模式需要 TCP_INFO 基线
  fi
  diskstats_snapshot >"$BASEDIR/diskstats"
  load_workload_metadata
  cgroup_io_snapshot >"$BASEDIR/cgroup_io"
  refresh_pid_parents
  exec 3>"$BASEDIR/proc_base"
  while read -r pid u state; do
    [[ $pid =~ ^[0-9]+$ && $state != Z* ]] || continue
    is_excluded_pid "$pid" && continue
    [[ -r "/proc/$pid/stat" ]] || continue
    read_ticks "$pid"
    [[ $T_STATE == Z ]] && continue
    read_rss "$pid"
    read_io "$pid"
    printf '%s %s %s %s %s %s %s %s\n' "$pid" "$T_TICKS1" "$T_TICKS2" "$T_START" "$RSSKB" "$IO_R" "$IO_W" "$u" >&3
  done < <(ps -eo pid=,user=,state= 2>/dev/null)
  exec 3>&-
  profile_mark snapshot_end
}

load_workload_metadata() {
  [[ $OS == linux ]] || return 0
  local file base cid prefix pod rest ns container
  for file in /var/log/containers/*.log; do
    [[ -f $file ]] || continue
    base=${file##*/}; base=${base%.log}; cid=${base##*-}; prefix=${base%-"$cid"}
    [[ $cid =~ ^[0-9a-f]{12,64}$ && $prefix == *_*_* ]] || continue
    pod=${prefix%%_*}; rest=${prefix#*_}; ns=${rest%%_*}; container=${rest#*_}
    WL_NAMESPACE[$cid]=$ns; WL_POD[$cid]=$pod; WL_CONTAINER[$cid]=$container
  done
}

linux_collect() {  # 每行: pid cpu rssKB rKB wKB net user rxKB txKB name
  local ptot pide btot bide pid rss np
  read -r ptot pide < <(cpu_total)
  read -r btot bide <"$BASEDIR/cpu_total" 2>/dev/null || { btot=$ptot; bide=$pide; }
  ptot=$(( ptot - btot )); pide=$(( pide - bide ))   # 整体 CPU 差值（非累计值）
  declare -A NETCNT
  while read -r np; do
    [[ $np =~ ^pid=[0-9]+$ ]] && (( NETCNT[${np#pid=}]++ ))
  done < <( { ss -tpnH 2>/dev/null; ss -unpH 2>/dev/null; } | grep -o 'pid=[0-9]*' )
  declare -A BWA BWR CWA CWR
  local bp ba br cp ca cr
  if [[ $NET_ATTR_SOURCE == ss_tcp_info ]]; then
    while read -r bp ba br; do BWA[$bp]=$ba; BWR[$bp]=$br; done <"$BASEDIR/net_bw" 2>/dev/null
    while read -r cp ca cr; do CWA[$cp]=$ca; CWR[$cp]=$cr; done < <(ss_bw)
  fi
  local t1 t0 start0 _rss0 rb0 wb0 u1
  while read -r pid t1 t0 start0 _rss0 rb0 wb0 u1; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    is_excluded_pid "$pid" && continue
    [[ -r "/proc/$pid/stat" ]] || continue
    num "$t1"; t1=$NUMOUT; num "$t0"; t0=$NUMOUT
    num "$rb0"; rb0=$NUMOUT; num "$wb0"; wb0=$NUMOUT
    read_ticks "$pid"
    [[ $T_STATE == Z || $T_START != "$start0" ]] && continue
    local current_start=$T_START
    local cpu=0 rk=0 wk=0 nc=0 rx=0 tx=0
    local dp=$(( (T_TICKS1 + T_TICKS2) - (t1 + t0) ))
    if (( ptot > 0 && dp > 0 )); then cpu=$(( dp * NCPU * 100 / ptot )); fi
    read_rss "$pid"; rss=$RSSKB
    read_io "$pid"
    rk=$(( (IO_R - rb0) / INTERVAL / 1024 )); [[ $rk -lt 0 ]] && rk=0
    wk=$(( (IO_W - wb0) / INTERVAL / 1024 )); [[ $wk -lt 0 ]] && wk=0
    nc=${NETCNT[$pid]:-0}
    if [[ $NET_ATTR_SOURCE != ss_tcp_info && $NET_ATTR_SOURCE != unsupported ]]; then
      if [[ ${AF_START[$pid]:-} == "$current_start" ]]; then
        rx=${AF_RX[$pid]:-0}; tx=${AF_TX[$pid]:-0}
      else
        rx=0; tx=0
      fi
    else
      rx=$(( (${CWR[$pid]:-0} - ${BWR[$pid]:-0}) / INTERVAL / 1024 )); [[ $rx -lt 0 ]] && rx=0
      tx=$(( (${CWA[$pid]:-0} - ${BWA[$pid]:-0}) / INTERVAL / 1024 )); [[ $tx -lt 0 ]] && tx=0
    fi
    local name
    read_cmdline "$pid"; name=$CMDLINE
    [[ -z $name ]] && name="<内核线程>"
    printf '%s %s %s %s %s %s %s %s %s %s\n' "$pid" "$cpu" "$rss" "$rk" "$wk" "$nc" "$u1" "$rx" "$tx" "$name"
  done <"$BASEDIR/proc_base" 2>/dev/null
}

# Top-level block devices only. diskstats fields: reads, sectors read, read ms,
# writes, sectors written, write ms, in-progress, IO ms, weighted IO ms.
diskstats_snapshot() {
  local dev reads sectors_r rms writes sectors_w wms busy weighted
  [[ $OS == linux ]] || return 0
  while read -r _ _ dev reads _ sectors_r rms writes _ sectors_w wms _ busy weighted _; do
    [[ -d /sys/block/$dev ]] || continue
    printf '%s %s %s %s %s %s %s %s %s\n' "$dev" "${reads:-0}" "${sectors_r:-0}" "${rms:-0}" "${writes:-0}" "${sectors_w:-0}" "${wms:-0}" "${busy:-0}" "${weighted:-0}"
  done < /proc/diskstats 2>/dev/null
}

DISK_DEVICES=()
disk_devices_collect() {
  DISK_DEVICES=()
  [[ $OS == linux ]] || return 0
  declare -A BR BS BRMS BW BSWS BWMS BBUSY BWEIGHT
  local dev reads sectors_r rms writes sectors_w wms busy weighted
  while read -r dev reads sectors_r rms writes sectors_w wms busy weighted; do
    BR[$dev]=$reads; BS[$dev]=$sectors_r; BRMS[$dev]=$rms; BW[$dev]=$writes; BSWS[$dev]=$sectors_w; BWMS[$dev]=$wms; BBUSY[$dev]=$busy; BWEIGHT[$dev]=$weighted
  done < "$BASEDIR/diskstats" 2>/dev/null
  while read -r dev reads sectors_r rms writes sectors_w wms busy weighted; do
    [[ -n ${BR[$dev]:-} ]] || continue
    local dr=$(( reads - BR[$dev] )) dsr=$(( sectors_r - BS[$dev] )) drm=$(( rms - BRMS[$dev] ))
    local dw=$(( writes - BW[$dev] )) dsw=$(( sectors_w - BSWS[$dev] )) dwm=$(( wms - BWMS[$dev] ))
    local db=$(( busy - BBUSY[$dev] )) dq=$(( weighted - BWEIGHT[$dev] ))
    (( dr < 0 )) && dr=0; (( dsr < 0 )) && dsr=0; (( drm < 0 )) && drm=0
    (( dw < 0 )) && dw=0; (( dsw < 0 )) && dsw=0; (( dwm < 0 )) && dwm=0
    (( db < 0 )) && db=0; (( dq < 0 )) && dq=0
    local rk=$(( dsr / 2 / INTERVAL )) wk=$(( dsw / 2 / INTERVAL )) ri=$(( dr / INTERVAL )) wi=$(( dw / INTERVAL ))
    local bp=$(( db * 100 / (INTERVAL * 1000) )) ra=0 wa=0 qd=0
    (( bp > 100 )) && bp=100
    (( dr > 0 )) && ra=$(( drm / dr ))
    (( dw > 0 )) && wa=$(( dwm / dw ))
    qd=$(( dq / (INTERVAL * 1000) ))
    DISK_DEVICES+=("$dev $rk $wk $ri $wi $bp $ra $wa $qd")
  done < <(diskstats_snapshot)
}

cgroup_io_snapshot() {
  [[ $OS == linux && -d /sys/fs/cgroup/kubepods.slice ]] || return 0
  local file dir base cid r w value line
  local -a fields
  while IFS= read -r file; do
    dir=${file%/io.stat}; base=${dir##*/}
    [[ $base == cri-containerd-*.scope ]] || continue
    cid=${base#cri-containerd-}; cid=${cid%.scope}; r=0; w=0
    while IFS= read -r line; do
      read -r -a fields <<<"$line"
      for value in "${fields[@]}"; do
        case $value in
          rbytes=*) value=${value#rbytes=}; (( value > r )) && r=$value ;;
          wbytes=*) value=${value#wbytes=}; (( value > w )) && w=$value ;;
        esac
      done
    done <"$file" 2>/dev/null
    printf '%s %d %d\n' "$cid" "$r" "$w"
  done < <(find /sys/fs/cgroup/kubepods.slice -type f -name io.stat 2>/dev/null)
}

CGROUP_IO=()
cgroup_io_collect() {
  CGROUP_IO=()
  [[ $OS == linux ]] || return 0
  declare -A base_r base_w
  local cid r w rk wk
  while read -r cid r w; do
    [[ $cid =~ ^[0-9a-f]+$ ]] || continue
    base_r[$cid]=$r; base_w[$cid]=$w
  done <"$BASEDIR/cgroup_io" 2>/dev/null
  while read -r cid r w; do
    [[ -n ${base_r[$cid]:-} ]] || continue
    rk=$(( (r - base_r[$cid]) / INTERVAL / 1024 )); wk=$(( (w - base_w[$cid]) / INTERVAL / 1024 ))
    (( rk < 0 )) && rk=0; (( wk < 0 )) && wk=0
    (( rk + wk > 0 )) && CGROUP_IO+=("$cid"$'\t'"$rk"$'\t'"$wk")
  done < <(cgroup_io_snapshot)
}

# ------------------------- macOS 降级采集 -------------------------
mac_collect() {  # 每行: pid cpu rssKB rKB wKB net user rxKB txKB name
  while read -r p u c r n; do
    printf '%s %s %s 0 0 0 %s 0 0 %s\n' "$p" "${c%.*}" "$(( r / 1024 ))" "$u" "$n"
  done < <(ps -axo pid=,user=,%cpu=,rss=,comm=)
}

collect() {
  if [[ $OS == linux ]]; then linux_collect; else mac_collect; fi
}

# ------------------------- 显示辅助 -------------------------
hr_size() {
  awk -v b="${1:-0}" 'BEGIN{ b=b<0?0:b; split("B K M G T",u); i=1; while(b>=1024&&i<5){b/=1024;i++} printf "%.1f%s",b,u[i] }'
}

color_pct() {  # 百分比 红≥90 黄≥60 绿
  local v=${1:-0}
  if (( v >= 90 )); then echo "$C_RED$C_BLD"; elif (( v >= 60 )); then echo "$C_YEL"; else echo "$C_GRN"; fi
}
color_io() {   # 磁盘速率 KB/s 红≥51200 黄≥10240
  local v=${1:-0}
  if (( v >= 51200 )); then echo "$C_RED$C_BLD"; elif (( v >= 10240 )); then echo "$C_YEL"; else echo "$C_GRN"; fi
}
color_conn() { # 连接数 红≥500 黄≥200
  local v=${1:-0}
  if (( v >= 500 )); then echo "$C_RED$C_BLD"; elif (( v >= 200 )); then echo "$C_YEL"; else echo "$C_GRN"; fi
}

float_gt() {  # 浮点比较: $1 > $2
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'
}

# ------------------------- 汇总 -------------------------
print_summary() {
  local cp mp dp
  cp=$(color_pct "$CPU_SYS")
  mp=$(color_pct $(( MEM_USED * 100 / (MEM_TOTAL?MEM_TOTAL:1) )))
  dp=$(color_pct "$DISK_USE")
  printf '%s%s  系统概况%s\n' "$C_BLD" "$C_CYN" "$C_OFF"
  printf '%s 主机: %s | 系统: %s | 运行: %s%s\n' "$C_BLD" "$(hostname)" \
    "$(uname -sr)" "$(uptime -p 2>/dev/null || echo -n "-")" "$C_OFF"
  printf '  CPU %s%3d%%%s   负载 %s/%s/%s   内存 %s%4d/%dMB%s   磁盘/ %s%3d%%%s\n' \
    "$cp" "$CPU_SYS" "$C_OFF" "$L1" "$L5" "$L15" \
    "$mp" "$MEM_USED" "$MEM_TOTAL" "$C_OFF" "$dp" "$DISK_USE" "$C_OFF"
  if [[ $OS == linux ]]; then
    printf '  网络: ↓%s  ↑%s   (%s)\n' \
      "$(hr_size $(( NET_RX * 1024 )))/s" "$(hr_size $(( NET_TX * 1024 )))/s" "$NETIF"
    if [[ $NET_ATTR_STATUS == ok ]]; then
      printf '  进程网络: AF_PACKET TCP/UDP  覆盖 %d%%  未归属 ↓%s/s ↑%s/s  丢包 %d\n' \
        "$NET_ATTR_PERCENT" "$(hr_size $(( NET_ATTR_UNKNOWN_RX * 1024 )))" \
        "$(hr_size $(( NET_ATTR_UNKNOWN_TX * 1024 )))" "$NET_ATTR_DROPS"
    else
      printf '  %s进程网络: 降级为 ss TCP_INFO（仅部分 TCP；%s）%s\n' \
        "$C_YEL" "$NET_ATTR_REASON" "$C_OFF"
    fi
  fi
  if [[ $OS == linux && $PRIVILEGED == 0 ]]; then
    printf '  %s⚠ 当前非 root：磁盘IO / 连接数 / AF_PACKET 可能不完整，请用 %ssudo smon%s 查看完整数据%s\n' \
      "$C_YEL" "$C_BLD" "$C_OFF" "$C_OFF"
  fi
  echo
}

# ------------------------- 诊断建议 -------------------------
ALERTS=(); FINDINGS=()

add_finding() { # severity resource summary suspects_json actions_json evidence...
  local severity=$1 resource=$2 summary=$3 suspects=$4 actions=$5; shift 5
  local evidence_json="" item
  for item in "$@"; do
    [[ -z $evidence_json ]] || evidence_json+=","
    evidence_json+="\"$(json_escape "$item")\""
  done
  FINDINGS+=("{\"severity\":\"$(json_escape "$severity")\",\"resource\":\"$(json_escape "$resource")\",\"summary\":\"$(json_escape "$summary")\",\"evidence\":[${evidence_json}],\"suspects\":${suspects},\"actions\":${actions}}")
  ALERTS+=("$summary")
}

root_block_device() {
  local current=$1 next path chain=$1 hops=0 link parent
  while (( hops < 8 )); do
    if [[ -e /sys/class/block/$current/partition ]]; then
      link=$(readlink -f "/sys/class/block/$current" 2>/dev/null || true)
      parent=${link%/*}; parent=${parent##*/}
      if [[ -n $parent && $parent != "$current" ]]; then
        chain+=" -> $parent"; current=$parent; ((hops++)); continue
      fi
    fi
    next=""
    for path in /sys/block/"$current"/slaves/*; do
      [[ -e $path ]] || break
      next=${path##*/}; break
    done
    [[ -n $next && $next != "$current" ]] || break
    chain+=" -> $next"; current=$next; ((hops++))
  done
  printf '%s\t%s\n' "$current" "$chain"
}

collect_alerts() {  # 读取 collect 数据(stdin)，产出结构化 FINDINGS 与兼容 ALERTS
  ALERTS=(); FINDINGS=()
  local a pid cpu rss rk wk nc rx tx cmd bw io
  local topcpu_pid=0 topcpu=0 topcpu_cmd="" topmem_pid=0 topmem=0 topmem_cmd=""
  local topio_pid=0 topio=0 topio_r=0 topio_w=0 topnet_pid=0 topnet_nc=0 topbw_pid=0 topbw_kb=0 topbw_cmd=""
  while IFS=' ' read -r -a a; do
    num "${a[0]}"; pid=$NUMOUT; num "${a[1]}"; cpu=$NUMOUT; num "${a[2]}"; rss=$NUMOUT
    num "${a[3]}"; rk=$NUMOUT; num "${a[4]}"; wk=$NUMOUT; num "${a[5]}"; nc=$NUMOUT
    num "${a[7]}"; rx=$NUMOUT; num "${a[8]}"; tx=$NUMOUT; cmd="${a[*]:9}"; bw=$(( rx + tx )); io=$(( rk + wk ))
    (( cpu > topcpu )) && { topcpu=$cpu; topcpu_pid=$pid; topcpu_cmd=$cmd; }
    (( rss > topmem )) && { topmem=$rss; topmem_pid=$pid; topmem_cmd=$cmd; }
    (( io > topio )) && { topio=$io; topio_pid=$pid; topio_r=$rk; topio_w=$wk; }
    (( nc > topnet_nc )) && { topnet_nc=$nc; topnet_pid=$pid; }
    (( bw > topbw_kb )) && { topbw_kb=$bw; topbw_pid=$pid; topbw_cmd=$cmd; }
  done

  local suspect actions summary mp swap_pct=0
  if (( CPU_SYS >= 90 )); then
    suspect="[{\"kind\":\"process\",\"pid\":${topcpu_pid},\"cmd\":\"$(json_escape "$topcpu_cmd")\",\"cpu_percent\":${topcpu}}]"
    actions="[{\"label\":\"查看进程状态\",\"command\":\"ps -p ${topcpu_pid} -o pid,ppid,user,state,etime,%cpu,%mem,cmd\"},{\"label\":\"查看线程 CPU\",\"command\":\"ps -L -p ${topcpu_pid} -o pid,tid,psr,state,%cpu,comm --sort=-%cpu\"}]"
    add_finding critical cpu "CPU 使用率 ${CPU_SYS}%，主要责任进程 PID ${topcpu_pid}" "$suspect" "$actions" "整机 CPU ${CPU_SYS}%" "PID ${topcpu_pid} 本轮 ${topcpu}%"
  fi
  mp=$(( MEM_USED * 100 / (MEM_TOTAL?MEM_TOTAL:1) ))
  if (( mp >= 90 )); then
    suspect="[{\"kind\":\"process\",\"pid\":${topmem_pid},\"cmd\":\"$(json_escape "$topmem_cmd")\",\"rss_mb\":$((topmem/1024))}]"
    actions="[{\"label\":\"查看内存总况\",\"command\":\"free -h\"},{\"label\":\"查看进程内存\",\"command\":\"cat /proc/${topmem_pid}/status\"}]"
    add_finding critical memory "内存已用 ${mp}%，PID ${topmem_pid} 的 RSS 最大" "$suspect" "$actions" "已用 ${MEM_USED}MB / ${MEM_TOTAL}MB" "PID ${topmem_pid} RSS $((topmem/1024))MB"
  fi
  if (( SWAP_TOTAL > 0 )); then swap_pct=$(( SWAP_USED * 100 / SWAP_TOTAL )); fi
  if (( swap_pct >= 50 && SWAP_USED >= 512 )); then
    add_finding warning swap "Swap 已使用 ${swap_pct}%（${SWAP_USED}MB）" "[]" '[{"label":"查看内存与 swap","command":"free -h && cat /proc/swaps"}]' "Swap ${SWAP_USED}MB / ${SWAP_TOTAL}MB"
  fi
  if float_gt "$L1" "$NCPU"; then
    add_finding warning load "1 分钟负载 ${L1} 超过 ${NCPU} 个 CPU 核" "[]" '[{"label":"查看运行与阻塞任务","command":"ps -eo pid,ppid,state,wchan:24,%cpu,%mem,cmd --sort=-%cpu | head -30"}]' "load1=${L1}" "CPU 核数=${NCPU}"
  fi
  if (( DISK_USE >= 85 )); then
    add_finding warning disk_space "根分区已使用 ${DISK_USE}%" "[]" '[{"label":"查看文件系统容量","command":"df -hT /"},{"label":"查看一级目录占用","command":"du -xhd1 / 2>/dev/null | sort -h | tail -20"}]' "根分区使用率 ${DISK_USE}%"
  fi

  disk_devices_collect; cgroup_io_collect
  local topcg_id="" topcg=0 topcg_r=0 topcg_w=0 cgline cgid cgr cgw
  for cgline in "${CGROUP_IO[@]}"; do
    IFS=$'\t' read -r cgid cgr cgw <<<"$cgline"
    (( cgr + cgw > topcg )) && { topcg=$((cgr+cgw)); topcg_id=$cgid; topcg_r=$cgr; topcg_w=$cgw; }
  done
  if [[ $OS == linux ]]; then declare -A DEVICE_SEEN; else declare -a DEVICE_SEEN; fi
  local d name dr dw di dj db ra wa dq root chain pattern="" severity
  for d in "${DISK_DEVICES[@]}"; do
    name=${d%% *}; read -r dr dw di dj db ra wa dq <<<"${d#* }"
    (( (db >= 80 || ra >= 20 || wa >= 20) && (di + dj > 0) )) || continue
    IFS=$'\t' read -r root chain < <(root_block_device "$name")
    [[ -z ${DEVICE_SEEN[$root]:-} ]] || continue; DEVICE_SEEN[$root]=1
    if (( wa >= 20 && wa >= ra )); then pattern="写等待"; elif (( dq >= 2 )); then pattern="队列堆积"; elif (( di + dj >= 1000 && dr + dw < (di + dj) * 64 )); then pattern="高并发小 IO"; else pattern="设备繁忙"; fi
    severity=warning; (( db >= 95 || ra >= 100 || wa >= 100 )) && severity=critical
    local cgns=${WL_NAMESPACE[$topcg_id]:-} cgpod=${WL_POD[$topcg_id]:-} cgcontainer=${WL_CONTAINER[$topcg_id]:-}
    if (( topcg > topio && topcg > 0 )) && [[ -n $cgns && -n $cgpod ]]; then
      suspect="[{\"kind\":\"pod\",\"namespace\":\"$(json_escape "$cgns")\",\"pod\":\"$(json_escape "$cgpod")\",\"container\":\"$(json_escape "$cgcontainer")\",\"container_id\":\"$topcg_id\",\"read_kbs\":${topcg_r},\"write_kbs\":${topcg_w}}]"
      actions="[{\"label\":\"查看 Pod\",\"command\":\"k3s kubectl -n ${cgns} get pod ${cgpod} -o wide\"},{\"label\":\"查看容器信息\",\"command\":\"crictl inspect ${topcg_id}\"}]"
      summary="设备 ${root} 出现${pattern}，主要 IO 来自 ${cgns}/${cgpod}/${cgcontainer}"
    else
      suspect="[{\"kind\":\"process\",\"pid\":${topio_pid},\"read_kbs\":${topio_r},\"write_kbs\":${topio_w}}]"
      actions="[{\"label\":\"查看进程 IO\",\"command\":\"cat /proc/${topio_pid}/io\"},{\"label\":\"查看进程状态\",\"command\":\"ps -p ${topio_pid} -o pid,ppid,user,state,etime,%cpu,%mem,cmd\"}]"
      summary="设备 ${root} 出现${pattern}，本轮 Top 进程为 PID ${topio_pid}"
    fi
    add_finding "$severity" disk "$summary" "$suspect" "$actions" "设备链 ${chain}" "busy ${db}%" "读/写 await ${ra}/${wa}ms" "队列深度 ${dq}" "吞吐 ${dr}/${dw}KB/s，IOPS ${di}/${dj}"
  done

  local entity _entity_id ens epod econtainer _ecid erx etx _eattr entity_bw=0 entity_desc="" entity_actions=""
  for entity in "${NET_ENTITIES[@]}"; do
    IFS=$'\t' read -r _entity_id ens epod econtainer _ecid erx etx _eattr <<<"$entity"
    (( erx + etx > entity_bw )) && { entity_bw=$((erx+etx)); entity_desc="$ens/$epod/$econtainer"; entity_actions="k3s kubectl -n $ens get pod $epod -o wide"; }
  done
  if (( entity_bw > topbw_kb )); then topbw_kb=$entity_bw; topbw_pid=0; fi
  if (( topbw_kb >= 10240 )); then
    if (( topbw_pid > 0 )); then
      suspect="[{\"kind\":\"process\",\"pid\":${topbw_pid},\"cmd\":\"$(json_escape "$topbw_cmd")\",\"total_kbs\":${topbw_kb}}]"
      actions="[{\"label\":\"查看进程连接\",\"command\":\"nsenter -t ${topbw_pid} -n ss -tpn\"}]"
      summary="PID ${topbw_pid} 是网络带宽热点（${topbw_kb}KB/s）"
    else
      suspect="[{\"kind\":\"pod\",\"workload\":\"$(json_escape "$entity_desc")\",\"total_kbs\":${topbw_kb}}]"
      actions="[{\"label\":\"查看 Pod\",\"command\":\"$(json_escape "$entity_actions")\"}]"
      summary="Pod ${entity_desc} 是网络带宽热点（${topbw_kb}KB/s）"
    fi
    add_finding warning network "$summary" "$suspect" "$actions" "接收与发送合计 ${topbw_kb}KB/s" "归属来源 ${NET_ATTR_SOURCE}"
  fi
  if (( topnet_nc >= 500 )); then
    add_finding warning connections "PID ${topnet_pid} 持有 ${topnet_nc} 个 TCP/UDP 连接" "[{\"kind\":\"process\",\"pid\":${topnet_pid},\"connections\":${topnet_nc}}]" "[{\"label\":\"查看进程连接\",\"command\":\"nsenter -t ${topnet_pid} -n ss -tpn\"}]" "连接数阈值 500"
  fi
  if (( NET_ATTR_DROPS > 0 )); then
    add_finding critical network_drop "网络采集本轮丢弃 ${NET_ATTR_DROPS} 个包" "[]" '[{"label":"查看网卡统计","command":"ip -s link show dev '"$NETIF"'"}]' "AF_PACKET dropped_packets=${NET_ATTR_DROPS}"
  fi

  local zombie_stats zombie_count=0 zombie_ppid=0 zombie_parent_count=0
  zombie_stats=$(ps -eo stat=,ppid= 2>/dev/null | awk '$1 ~ /^Z/{n++; c[$2]++} END{p=0;m=0;for(k in c)if(c[k]>m){m=c[k];p=k} print n+0,p+0,m+0}')
  read -r zombie_count zombie_ppid zombie_parent_count <<<"$zombie_stats"
  if (( zombie_count > 0 )); then
    severity=warning; (( zombie_count >= 100 )) && severity=critical
    add_finding "$severity" zombie "发现 ${zombie_count} 个 zombie，PID ${zombie_ppid} 是主要父进程" "[{\"kind\":\"process\",\"pid\":${zombie_ppid},\"zombie_children\":${zombie_parent_count}}]" "[{\"label\":\"查看父进程\",\"command\":\"ps -p ${zombie_ppid} -o pid,ppid,user,state,etime,cmd\"},{\"label\":\"查看 zombie 子进程\",\"command\":\"ps -o pid,ppid,state,etime,cmd --ppid ${zombie_ppid}\"}]" "zombie 总数 ${zombie_count}" "该父进程名下 ${zombie_parent_count} 个"
  fi
}

print_diag() {
  if (( ${#ALERTS[@]} == 0 )); then
    printf '  %s✓ 系统各项指标正常%s\n' "$C_GRN" "$C_OFF"
  else
    printf '  %s⚠ 诊断建议%s\n' "$C_RED$C_BLD" "$C_OFF"
    local a
    for a in "${ALERTS[@]}"; do
      printf '    %s%s%s\n' "$C_YEL" "$a" "$C_OFF"
    done
  fi
  echo
}

# ------------------------- 进程表 -------------------------
print_table() {  # 从 stdin 读 collect 数据（已排序）
  local k
  case "$SORT_KEY" in mem) k=3 ;; disk) k=4 ;; net) k=6 ;; *) k=2 ;; esac
  printf '%-7s %6s %7s %7s %7s %5s %7s %7s  %-10s %s\n' 'PID' 'CPU%' '内存' '读IO' '写IO' '连接' '收↓' '发↑' '用户' '命令'
  local a lines=0 pid cpu rss rk wk nc u nm rx tx mem_pct
  while IFS=' ' read -r -a a; do
    (( lines++ )); (( lines > 20 )) && break
    num "${a[0]}"; pid=$NUMOUT; num "${a[1]}"; cpu=$NUMOUT; num "${a[2]}"; rss=$NUMOUT; num "${a[3]}"; rk=$NUMOUT; num "${a[4]}"; wk=$NUMOUT; num "${a[5]}"; nc=$NUMOUT; u=${a[6]:-}; num "${a[7]}"; rx=$NUMOUT; num "${a[8]}"; tx=$NUMOUT; nm="${a[*]:9}"
    mem_pct=$(( rss * 100 / (( MEM_TOTAL?MEM_TOTAL:1) * 1024) ))
    local pc mc ic ncc nwc
    pc=$(color_pct "$cpu")
    mc=$(color_pct "$mem_pct")
    ic=$(color_io "$rk"); [[ $(color_io "$wk") == "$C_RED$C_BLD" ]] && ic=$C_RED$C_BLD
    ncc=$(color_conn "$nc")
    nwc=$(color_io "$(( rx + tx ))")
    printf '%-7s %s%6s%%%s %s%7s%s %s%7s%s %s%7s%s %s%5s%s %s%7s%s %s%7s%s  %-10s %s\n' \
      "$pid" "$pc" "$cpu" "$C_OFF" "$mc" "$(hr_size $(( rss * 1024 )))" "$C_OFF" \
      "$ic" "$rk" "$C_OFF" "$ic" "$wk" "$C_OFF" "$ncc" "$nc" "$C_OFF" \
      "$nwc" "$rx" "$C_OFF" "$nwc" "$tx" "$C_OFF" "$u" "$nm"
  done
  echo
  printf '  [排序: %s]  c=CPU  m=内存  d=磁盘IO  n=网络  q=退出\n' "$SORT_KEY"
}

sort_data() {  # 按当前排序键排序 stdin
  local k
  case "$SORT_KEY" in mem) k=3 ;; disk) k=4 ;; net) k=6 ;; *) k=2 ;; esac
  if [[ $SORT_KEY == net ]]; then
    awk '{print $8+$9, $0}' | sort -t' ' -k1 -rn | cut -d' ' -f2-
  else
    sort -t' ' -k"$k" -rn
  fi
}

# ------------------------- JSON 输出 -------------------------
JSON_ESCAPED=""
json_escape_value() {  # 无子进程地写入 $JSON_ESCAPED
  local s=$1 out="" c code i
  if [[ $s != *\\* && $s != *\"* && $s != *$'\b'* && $s != *$'\f'* && $s != *$'\n'* && $s != *$'\r'* && $s != *$'\t'* ]]; then
    JSON_ESCAPED=$s
    return 0
  fi
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case "$c" in
      \\) out="${out}\\\\" ;;
      '"') out="${out}\\\"" ;;
      $'\b') out="${out}\\b" ;;
      $'\f') out="${out}\\f" ;;
      $'\n') out="${out}\\n" ;;
      $'\r') out="${out}\\r" ;;
      $'\t') out="${out}\\t" ;;
      *)
        printf -v code '%d' "'$c"
        if (( code >= 0 && code < 32 )); then printf -v c '\\u%04x' "$code"; fi
        out+=$c
        ;;
    esac
  done
  JSON_ESCAPED=$out
}

json_escape() {
  json_escape_value "$1"
  printf '%s' "$JSON_ESCAPED"
}

emit_json() {  # 从 stdin 读 collect 数据
  profile_mark emit_start
  local data; data=$(cat)
  profile_mark emit_data_read
  load_sys_stats
  profile_mark emit_sys_loaded
  net_rate
  disk_devices_collect
  cgroup_io_collect
  profile_mark emit_devices_loaded
  local mp=$(( MEM_USED * 100 / (MEM_TOTAL?MEM_TOTAL:1) ))
  echo "{"
  printf '  "host": "%s",\n' "$(json_escape "$(hostname)")"
  printf '  "os": "%s",\n'   "$(json_escape "$(uname -sr)")"
  printf '  "uptime": "%s",\n' "$(json_escape "$(uptime -p 2>/dev/null || echo -n "-")")"
  echo "  \"cpu\": { \"percent\": $CPU_SYS, \"load1\": $L1, \"load5\": $L5, \"load15\": $L15 },"
  echo "  \"memory\": { \"total_mb\": $MEM_TOTAL, \"used_mb\": $MEM_USED, \"percent\": $mp },"
  printf '  "disk_root_percent": %d,\n' "$DISK_USE"
  printf '  "privileged": %d,\n' "$PRIVILEGED"
  printf '  "netif": "%s",\n' "$(json_escape "$NETIF")"
  echo "  \"net_traffic\": { \"rx_kbs\": $NET_RX, \"tx_kbs\": $NET_TX },"
  printf '  "net_attribution": { "source": "%s", "status": "%s", "scope": "%s", "protocols": %s, "interval_ms": %d, "attributed_percent": %d, "unknown_rx_kbs": %d, "unknown_tx_kbs": %d, "unknown_breakdown": { "unsupported_rx_kbs": %d, "unsupported_tx_kbs": %d, "unmatched_rx_kbs": %d, "unmatched_tx_kbs": %d, "ambiguous_rx_kbs": %d, "ambiguous_tx_kbs": %d, "exited_rx_kbs": %d, "exited_tx_kbs": %d }, "captured_packets": %d, "dropped_packets": %d, "reason": "%s" },\n' \
    "$NET_ATTR_SOURCE" "$NET_ATTR_STATUS" "$NET_ATTR_SCOPE" "$NET_ATTR_PROTOCOLS" "$NET_ATTR_INTERVAL_MS" \
    "$NET_ATTR_PERCENT" "$NET_ATTR_UNKNOWN_RX" "$NET_ATTR_UNKNOWN_TX" \
    "$NET_UNSUPPORTED_RX" "$NET_UNSUPPORTED_TX" "$NET_UNMATCHED_RX" "$NET_UNMATCHED_TX" "$NET_AMBIGUOUS_RX" "$NET_AMBIGUOUS_TX" "$NET_EXITED_RX" "$NET_EXITED_TX" \
    "$NET_ATTR_PACKETS" "$NET_ATTR_DROPS" "$(json_escape "$NET_ATTR_REASON")"
  echo "  \"disk_devices\": ["
  local d first_disk=1 name rk wk ri wi bp ra wa qd
  for d in "${DISK_DEVICES[@]}"; do
    read -r name rk wk ri wi bp ra wa qd <<<"$d"
    (( first_disk )) || echo ','; first_disk=0
    printf '    { "name": "%s", "read_kbs": %d, "write_kbs": %d, "read_iops": %d, "write_iops": %d, "busy_percent": %d, "read_await_ms": %d, "write_await_ms": %d, "avg_queue_depth": %d }' "$(json_escape "$name")" "$rk" "$wk" "$ri" "$wi" "$bp" "$ra" "$wa" "$qd"
  done
  echo
  echo "  ],"
  echo "  \"processes\": ["
  local first=1 a pid cpu rss rk wk nc u nm rx tx u2 nm2 pscope pns ppod pcontainer pcid pattribution
  while IFS=' ' read -r -a a; do
    num "${a[0]}"; pid=$NUMOUT; num "${a[1]}"; cpu=$NUMOUT; num "${a[2]}"; rss=$NUMOUT; num "${a[3]}"; rk=$NUMOUT; num "${a[4]}"; wk=$NUMOUT; num "${a[5]}"; nc=$NUMOUT; u=${a[6]:-}; num "${a[7]}"; rx=$NUMOUT; num "${a[8]}"; tx=$NUMOUT; nm="${a[*]:9}"
    json_escape_value "$u"; u2=$JSON_ESCAPED
    json_escape_value "$nm"; nm2=$JSON_ESCAPED
    pscope=${AF_SCOPE[$pid]:-host}; pns=${AF_NAMESPACE[$pid]:-}; ppod=${AF_POD[$pid]:-}; pcontainer=${AF_CONTAINER[$pid]:-}; pcid=${AF_CONTAINER_ID[$pid]:-}; pattribution=${AF_ATTRIBUTION[$pid]:-}
    json_escape_value "$pscope"; pscope=$JSON_ESCAPED
    json_escape_value "$pns"; pns=$JSON_ESCAPED
    json_escape_value "$ppod"; ppod=$JSON_ESCAPED
    json_escape_value "$pcontainer"; pcontainer=$JSON_ESCAPED
    json_escape_value "$pcid"; pcid=$JSON_ESCAPED
    json_escape_value "$pattribution"; pattribution=$JSON_ESCAPED
    (( first )) || echo ","
    first=0
    printf '    { "kind": "process", "pid": %s, "scope": "%s", "namespace": "%s", "pod": "%s", "container": "%s", "container_id": "%s", "attribution": "%s", "cpu": %s, "rss_mb": %s, "read_kbs": %s, "write_kbs": %s, "net": %s, "user": "%s", "cmd": "%s", "recv_kbs": %s, "sent_kbs": %s}' \
      "$pid" "$pscope" "$pns" "$ppod" "$pcontainer" "$pcid" "$pattribution" \
      "$cpu" "$(( rss / 1024 ))" "$rk" "$wk" "$nc" "$u2" "$nm2" "$rx" "$tx"
  done <<<"$data"
  profile_mark emit_processes_written
  echo
  echo "  ],"
  echo "  \"network_entities\": ["
  if [[ $OS == linux ]]; then declare -A CGROUP_RK CGROUP_WK; else declare -a CGROUP_RK CGROUP_WK; fi
  local cgline cgid cgr cgw entity ns pod container cid erx etx attribution first_entity=1
  for cgline in "${CGROUP_IO[@]}"; do IFS=$'\t' read -r cgid cgr cgw <<<"$cgline"; CGROUP_RK[$cgid]=$cgr; CGROUP_WK[$cgid]=$cgw; done
  for entity in "${NET_ENTITIES[@]}"; do
    IFS=$'\t' read -r cgid ns pod container cid erx etx attribution <<<"$entity"
    (( first_entity )) || echo ','; first_entity=0
    printf '    { "kind": "container", "pid": null, "scope": "pod", "namespace": "%s", "pod": "%s", "container": "%s", "container_id": "%s", "attribution": "%s", "cpu": 0, "rss_mb": 0, "read_kbs": %d, "write_kbs": %d, "net": 0, "user": "", "cmd": "container aggregate", "recv_kbs": %d, "sent_kbs": %d }' \
      "$(json_escape "$ns")" "$(json_escape "$pod")" "$(json_escape "$container")" "$(json_escape "$cid")" "$(json_escape "$attribution")" \
      "${CGROUP_RK[$cid]:-0}" "${CGROUP_WK[$cid]:-0}" "$erx" "$etx"
  done
  echo
  echo "  ],"
  collect_alerts <<<"$data"
  profile_mark emit_findings_written
  echo "  \"alerts\": ["
  local first2=1 a
  for a in "${ALERTS[@]}"; do
    (( first2 )) || echo ","
    first2=0
    printf '    "%s"' "$(json_escape "$a")"
  done
  echo
  echo "  ],"
  echo "  \"findings\": ["
  local first3=1 finding
  for finding in "${FINDINGS[@]}"; do
    (( first3 )) || echo ','; first3=0
    printf '    %s' "$finding"
  done
  echo
  echo "  ]"
  echo "}"
  profile_mark emit_end
}

# ------------------------- 启动 & 主循环 -------------------------
mac_snapshot() { :; }   # macOS 无速率采样
if [[ $OS == linux ]]; then SNAP=linux_snapshot; else SNAP=mac_snapshot; fi

NET_RX=0; NET_TX=0
net_rate() {  # 计算总收/总发速率(KB/s) -> $NET_RX $NET_TX（基于 snapshot 基线差值）
  local rx0 tx0 rx1 tx1
  NET_RX=0; NET_TX=0
  [[ $OS == linux ]] || return 0
  read -r rx0 tx0 <"$BASEDIR/net_dev" 2>/dev/null || { rx0=0; tx0=0; }
  read -r rx1 tx1 < <(net_dev_total)
  NET_RX=$(( (rx1 - rx0) / INTERVAL / 1024 )); [[ $NET_RX -lt 0 ]] && NET_RX=0
  NET_TX=$(( (tx1 - tx0) / INTERVAL / 1024 )); [[ $NET_TX -lt 0 ]] && NET_TX=0
}

detect_netif() {  # 探测主要网卡（用于展示）
  [[ $OS == linux ]] || return 0
  if [[ -n ${SMON_NETIF:-} ]]; then
    NETIF=$SMON_NETIF
  else
    NETIF=$(ip -o route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | awk '{print $2}')
    [[ -z $NETIF ]] && NETIF=$(awk '$2=="00000000"{print $1; exit}' /proc/net/route 2>/dev/null)
    [[ -z $NETIF ]] && NETIF=""
  fi
}
detect_netif

main_tui() {
  # shellcheck disable=SC2034
  TUI_RUNNING=1
  start_net_collector continuous || true
  $SNAP
  local key data
  while :; do
    read -rt "$INTERVAL" -n1 -s key || key=''
    case "$key" in
      c) SORT_KEY=cpu ;; m) SORT_KEY=mem ;; d) SORT_KEY=disk ;; n) SORT_KEY=net ;;
      q) break ;;
    esac
    tput clear; tput home; tput civis
    load_sys_stats
    net_rate
    ensure_net_collector
    load_net_snapshot || true
    data=$(collect | sort_data)
    print_summary
    print_table <<<"$data"
    collect_alerts <<<"$data"
    print_diag
    $SNAP
  done
}

if (( SERVE )); then
  smon_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f "$smon_dir/smon-web.py" ]]; then web="$smon_dir/smon-web.py"
  elif [[ -f "$smon_dir/web.py" ]]; then web="$smon_dir/web.py"
  else
    echo "未找到 web.py，请将 web.py 与 smon 放在同一目录" >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "Web 面板需要 python3，请先安装" >&2; exit 1; }
  exec env SMON_NETIF="$NETIF" python3 "$web" "${BASH_SOURCE[0]}" "$SERVE_PORT"
fi

if (( JSON_MODE )); then
  if [[ $OS == linux ]]; then
    start_net_collector once || true
    linux_snapshot
    wait_net_collector_once
  fi
  load_net_snapshot || true
  profile_mark collect_start
  collect | { profile_mark collect_end; emit_json; }
else
  main_tui
fi
