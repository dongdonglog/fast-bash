#!/usr/bin/env bash
#
# smon - 中文进程占用实时排障工具
# 以进程为核心，一打开就知道是谁占用了 CPU / 内存 / 磁盘 IO / 网络。
# 用法:  smon [选项]
set -o pipefail

VERSION="0.3.1"
INTERVAL=5
SORT_KEY=cpu
JSON_MODE=0
NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
PRIVILEGED=0; [[ $EUID -eq 0 ]] && PRIVILEGED=1
BASEDIR=$(mktemp -d "${TMPDIR:-/tmp}/smon.XXXXXX") || exit 1
NETIF=""

# 颜色
C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_CYN=$'\e[36m'
C_BLD=$'\e[1m'; C_OFF=$'\e[0m'

restore_tty() { stty sane 2>/dev/null; }
TUI_RUNNING=0
cleanup() {
  rm -rf "$BASEDIR"
  restore_tty
  (( TUI_RUNNING )) && tput cnorm 2>/dev/null
}
trap 'exit 1' INT TERM
trap 'cleanup' EXIT

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

数据来源（Linux）: /proc/<pid>/stat, status, io; /proc/net/dev; ss -iepn(TCP_INFO)
  * CPU% 为单个核心百分比（100% = 吃满一核）
  * 磁盘 IO 需 root 才能读取其他用户进程
  * 网络：总收/总发（接口级）+ 每进程 TCP 带宽（ss -i 内核计数器，root 才完整）
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
    i) INTERVAL="$OPTARG" ;;
    j) JSON_MODE=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -d /proc && -r /proc/stat ]]; then OS=linux; else OS=macos; fi

# ------------------------- 系统指标（一次采样，供汇总/诊断/JSON 复用）---------
CPU_SYS=0; MEM_USED=0; MEM_TOTAL=0; L1=0; L5=0; L15=0; DISK_USE=0
load_sys_stats() {
  local raw id1 pt pide
  if [[ $OS == linux ]]; then
    read -r raw id1 < <(cpu_total); sleep 0.3; read -r pt pide < <(cpu_total)
    CPU_SYS=0
    if (( (pt-raw) > 0 )); then CPU_SYS=$(( (pt-raw-(pide-id1)) * 100 / (pt-raw) )); fi
    MEM_TOTAL=$(awk '/MemTotal:/{print $2}' /proc/meminfo)
    MEM_USED=$(awk '/MemAvailable:/{m=$2} END{print int((mt-m)/1024)}' mt="$MEM_TOTAL" /proc/meminfo)
    MEM_TOTAL=$(( MEM_TOTAL / 1024 ))
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

net_dev_total() {  # 输出 "rx_bytes tx_bytes"（汇总所有非回环网卡）
  awk 'NR>2 { if ($1!="lo:") { rx+=$2; tx+=$10 } } END{print rx+0, tx+0}' /proc/net/dev 2>/dev/null
}

# 快速读取器：全部用 bash 内建（无外部子进程），结果写入全局变量
T_TICKS1=0; T_TICKS2=0
read_ticks() {  # $1=pid -> $T_TICKS1 $T_TICKS2
  local pid=$1 s
  T_TICKS1=0; T_TICKS2=0
  [[ -r "/proc/$pid/stat" ]] || return 0
  IFS= read -r s <"/proc/$pid/stat"
  s=${s##*) }
  # shellcheck disable=SC2086
  set -- $s
  T_TICKS1=${12:-0}; T_TICKS2=${13:-0}
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
  local pid=$1 s
  CMDLINE=""
  [[ -r "/proc/$pid/cmdline" ]] || return 0
  IFS= read -rd '' s <"/proc/$pid/cmdline" || true
  CMDLINE=${s//$'\0'/ }
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

linux_snapshot() {  # 建立基线: 每文件 "utime stime rss rbytes wbytes user"
  local pid u upid uu
  mkdir -p "$BASEDIR" 2>/dev/null || return 1
  cpu_total >"$BASEDIR/cpu_total"   # 保存整体 CPU 基线（供 collect 算差值）
  net_dev_total >"$BASEDIR/net_dev" # 保存总流量基线（供 collect 算速率）
  ss_bw >"$BASEDIR/net_bw"          # 保存每进程 TCP 字节基线（供 collect 算带宽）
  declare -A USERS
  while read -r upid uu; do
    [[ $upid =~ ^[0-9]+$ ]] && USERS[$upid]=$uu
  done < <(ps -eo pid=,user=)
  for pdir in /proc/[0-9]*; do
    pid=${pdir##*/}
    [[ -r "/proc/$pid/stat" ]] || continue
    u=${USERS[$pid]:-?}
    read_ticks "$pid"
    read_rss "$pid"
    read_io "$pid"
    printf '%s %s %s %s\n' "$T_TICKS1 $T_TICKS2" "$RSSKB" "$IO_R $IO_W" "$u" >"$BASEDIR/$pid"
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
  while read -r bp ba br; do BWA[$bp]=$ba; BWR[$bp]=$br; done <"$BASEDIR/net_bw" 2>/dev/null
  while read -r cp ca cr; do CWA[$cp]=$ca; CWR[$cp]=$cr; done < <(ss_bw)
  for pdir in /proc/[0-9]*; do
    pid=${pdir##*/}
    [[ -r "/proc/$pid/stat" && -f "$BASEDIR/$pid" ]] || continue
    local t1 t0 _ rb0 wb0 u1
    read -r t1 t0 _ rb0 wb0 u1 <"$BASEDIR/$pid"
    num "$t1"; t1=$NUMOUT; num "$t0"; t0=$NUMOUT
    num "$rb0"; rb0=$NUMOUT; num "$wb0"; wb0=$NUMOUT
    read_ticks "$pid"
    local cpu=0 rk=0 wk=0 nc=0 rx=0 tx=0
    local dp=$(( (T_TICKS1 + T_TICKS2) - (t1 + t0) ))
    if (( ptot > 0 && dp > 0 )); then cpu=$(( dp * NCPU * 100 / ptot )); fi
    read_rss "$pid"; rss=$RSSKB
    read_io "$pid"
    rk=$(( (IO_R - rb0) / INTERVAL / 1024 )); [[ $rk -lt 0 ]] && rk=0
    wk=$(( (IO_W - wb0) / INTERVAL / 1024 )); [[ $wk -lt 0 ]] && wk=0
    nc=${NETCNT[$pid]:-0}
    rx=$(( (${CWR[$pid]:-0} - ${BWR[$pid]:-0}) / INTERVAL / 1024 )); [[ $rx -lt 0 ]] && rx=0
    tx=$(( (${CWA[$pid]:-0} - ${BWA[$pid]:-0}) / INTERVAL / 1024 )); [[ $tx -lt 0 ]] && tx=0
    local name
    read_cmdline "$pid"; name=$CMDLINE; name=${name:0:50}
    [[ -z $name ]] && name="<内核线程>"
    printf '%s %s %s %s %s %s %s %s %s %s\n' "$pid" "$cpu" "$rss" "$rk" "$wk" "$nc" "$u1" "$rx" "$tx" "$name"
  done
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
  fi
  if [[ $OS == linux && $PRIVILEGED == 0 ]]; then
    printf '  %s⚠ 当前非 root：磁盘IO / 连接数 / 每进程带宽 不可用，请用 %ssudo smon%s 查看完整数据%s\n' \
      "$C_YEL" "$C_BLD" "$C_OFF" "$C_OFF"
  fi
  echo
}

# ------------------------- 诊断建议 -------------------------
ALERTS=()
collect_alerts() {  # 读取 collect 数据(stdin)，产出诊断建议到 ALERTS
  ALERTS=()
  local a topio_pid=0 topio_rk=0 topnet_pid=0 topnet_nc=0 topbw_pid=0 topbw_kb=0 pid rk nc rx tx
  while IFS=' ' read -r -a a; do
    num "${a[0]}"; pid=$NUMOUT; num "${a[3]}"; rk=$NUMOUT; num "${a[5]}"; nc=$NUMOUT; num "${a[7]}"; rx=$NUMOUT; num "${a[8]}"; tx=$NUMOUT
    (( rk > topio_rk )) && { topio_rk=$rk; topio_pid=$pid; }
    (( nc > topnet_nc )) && { topnet_nc=$nc; topnet_pid=$pid; }
    local bw=$(( rx + tx ))
    (( bw > topbw_kb )) && { topbw_kb=$bw; topbw_pid=$pid; }
  done
  (( CPU_SYS >= 90 )) && ALERTS+=("CPU 使用率 ${CPU_SYS}% 过高，重点看占用最高的进程（已按 CPU 排序）")
  local mp=$(( MEM_USED * 100 / (MEM_TOTAL?MEM_TOTAL:1) ))
  (( mp >= 90 )) && ALERTS+=("内存使用 ${mp}% 不足，查看详情: free -h")
  float_gt "$L1" "$NCPU" && ALERTS+=("1分钟负载 ${L1} 超过核数(${NCPU})，疑似高并发或 IO 阻塞")
  (( DISK_USE >= 85 )) && ALERTS+=("根分区使用 ${DISK_USE}% 接近满，清理: du -sh /* 2>/dev/null | sort -rh | head")
  (( topio_rk >= 51200 )) && ALERTS+=("PID ${topio_pid} 磁盘读 ${topio_rk}KB/s 过高，查看: iostat -x 1")
  (( topbw_kb >= 10240 )) && ALERTS+=("PID ${topbw_pid} TCP 带宽 ${topbw_kb}KB/s 过高，重点排查该进程")
  (( topnet_nc >= 500 )) && ALERTS+=("PID ${topnet_pid} TCP/UDP 连接 ${topnet_nc} 过多，查看: ss -tn state established")
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
json_escape() {  # 纯 bash 转义，避免每次 spawn sed
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

emit_json() {  # 从 stdin 读 collect 数据
  local data; data=$(cat)
  load_sys_stats
  net_rate
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
  echo "  \"processes\": ["
  local first=1 a pid cpu rss rk wk nc u nm rx tx u2 nm2
  while IFS=' ' read -r -a a; do
    num "${a[0]}"; pid=$NUMOUT; num "${a[1]}"; cpu=$NUMOUT; num "${a[2]}"; rss=$NUMOUT; num "${a[3]}"; rk=$NUMOUT; num "${a[4]}"; wk=$NUMOUT; num "${a[5]}"; nc=$NUMOUT; u=${a[6]:-}; num "${a[7]}"; rx=$NUMOUT; num "${a[8]}"; tx=$NUMOUT; nm="${a[*]:9}"
    u2=${u//\\/\\\\}; u2=${u2//\"/\\\"}
    nm2=${nm//\\/\\\\}; nm2=${nm2//\"/\\\"}
    (( first )) || echo ","
    first=0
    printf '    { "pid": %s, "cpu": %s, "rss_mb": %s, "read_kbs": %s, "write_kbs": %s, "net": %s, "user": "%s", "cmd": "%s", "recv_kbs": %s, "sent_kbs": %s}' \
      "$pid" "$cpu" "$(( rss / 1024 ))" "$rk" "$wk" "$nc" "$u2" "$nm2" "$rx" "$tx"
  done <<<"$data"
  echo
  echo "  ],"
  collect_alerts <<<"$data"
  echo "  \"alerts\": ["
  local first2=1 a
  for a in "${ALERTS[@]}"; do
    (( first2 )) || echo ","
    first2=0
    printf '    "%s"' "$(json_escape "$a")"
  done
  echo
  echo "  ]"
  echo "}"
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
  if [[ -n $SMON_NETIF ]]; then
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
  if [[ -f "$smon_dir/web.py" ]]; then web="$smon_dir/web.py"
  elif [[ -f "$smon_dir/smon-web.py" ]]; then web="$smon_dir/smon-web.py"
  else
    echo "未找到 web.py，请将 web.py 与 smon 放在同一目录" >&2
    exit 1
  fi
  command -v python3 >/dev/null 2>&1 || { echo "Web 面板需要 python3，请先安装" >&2; exit 1; }
  exec python3 "$web" "${BASH_SOURCE[0]}" "$SERVE_PORT"
fi

if (( JSON_MODE )); then
  if [[ $OS == linux ]]; then
    linux_snapshot; sleep "$INTERVAL"
  fi
  collect | emit_json
else
  main_tui
fi
