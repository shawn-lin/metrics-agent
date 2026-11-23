#!/usr/bin/env bash
# 讀取 Linux 系統指標，輸出一行 JSON。
# 需要 bash、/proc 與 df。IP 僅在系統已有 ip（iproute2）時查詢。
set -euo pipefail
export LC_ALL=C

die() {
  printf 'metrics.sh: %s\n' "$*" >&2
  exit 1
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# 數值已乘 100，印成兩位小數。
fmt2() {
  local n=$1
  if (( n < 0 )); then
    n=0
  fi
  printf '%d.%02d' $((n / 100)) $((n % 100))
}

uptime_ms() {
  local line whole s frac
  IFS= read -r line < /proc/uptime || die "讀不到 /proc/uptime"
  whole=${line%% *}
  s=${whole%%.*}
  if [[ $whole == *.* ]]; then
    frac=${whole#*.}
    frac=${frac:0:2}
  else
    frac=0
  fi
  [[ $s =~ ^[0-9]+$ ]] || die "無法解析 /proc/uptime"
  printf '%s\n' $((10#$s * 1000 + 10#$frac * 10))
}

# 回傳「累計忙碌 tick」與「累計總 tick」。
read_cpu() {
  local line cpu user nice system idle iowait irq softirq steal
  local idle_all busy total
  IFS= read -r line < /proc/stat || die "讀不到 /proc/stat"
  read -r cpu user nice system idle iowait irq softirq steal _ <<< "$line"
  [[ $cpu == cpu ]] || die "/proc/stat 格式無法辨識"
  user=${user:-0}
  nice=${nice:-0}
  system=${system:-0}
  idle=${idle:-0}
  iowait=${iowait:-0}
  irq=${irq:-0}
  softirq=${softirq:-0}
  steal=${steal:-0}
  idle_all=$((idle + iowait))
  busy=$((user + nice + system + irq + softirq + steal))
  total=$((busy + idle_all))
  printf '%s %s\n' "$busy" "$total"
}

# want 為空時加總除 lo 以外的介面；否則只讀該介面。回傳 rx tx。
read_net_bytes() {
  local want=$1
  local line iface rest rx tx rx_sum=0 tx_sum=0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *:* ]] || continue
    iface=${line%%:*}
    iface=${iface//[[:space:]]/}
    [[ -z $iface || $iface == lo ]] && continue
    if [[ -n $want && $iface != "$want" ]]; then
      continue
    fi
    rest=${line#*:}
    read -r rx _ _ _ _ _ _ _ tx _ <<< "$rest"
    rx=${rx:-0}
    tx=${tx:-0}
    rx_sum=$((rx_sum + rx))
    tx_sum=$((tx_sum + tx))
  done < /proc/net/dev
  printf '%s %s\n' "$rx_sum" "$tx_sum"
}

first_non_lo() {
  local line iface
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *:* ]] || continue
    iface=${line%%:*}
    iface=${iface//[[:space:]]/}
    if [[ -n $iface && $iface != lo ]]; then
      printf '%s\n' "$iface"
      return 0
    fi
  done < /proc/net/dev
}

# 略過 RTF_REJECT（0x200）與 lo。找不到則不輸出。
pick_default_iface() {
  local iface dest plen gw flags metric metric_dec
  local refcnt use found=0 best_metric=0 best=""
  if [[ -r /proc/net/route ]]; then
    while read -r iface dest gw flags refcnt use metric _; do
      [[ $dest == 00000000 ]] || continue
      [[ -z $iface || $iface == lo ]] && continue
      flags=$((16#${flags:-0}))
      if (( (flags & 512) != 0 )); then
        continue
      fi
      metric_dec=$((16#${metric:-0}))
      if (( found == 0 || metric_dec < best_metric )); then
        found=1
        best_metric=$metric_dec
        best=$iface
      fi
    done < /proc/net/route
  fi
  if [[ -z $best && -r /proc/net/ipv6_route ]]; then
    while read -r dest plen _ _ _ metric _ _ flags iface; do
      [[ $dest == 00000000000000000000000000000000 ]] || continue
      [[ $plen == 00 ]] || continue
      [[ -z $iface || $iface == lo ]] && continue
      flags=$((16#${flags:-0}))
      if (( (flags & 512) != 0 )); then
        continue
      fi
      metric_dec=$((16#${metric:-0}))
      if (( found == 0 || metric_dec < best_metric )); then
        found=1
        best_metric=$metric_dec
        best=$iface
      fi
    done < /proc/net/ipv6_route
  fi
  if [[ -n $best ]]; then
    printf '%s\n' "$best"
  fi
}

read_mem() {
  local key val total=0 available=0 free=0 buffers=0 cached=0 has_av=0 used
  while read -r key val _; do
    case ${key%:} in
      MemTotal) total=$val ;;
      MemAvailable) available=$val; has_av=1 ;;
      MemFree) free=$val ;;
      Buffers) buffers=$val ;;
      Cached) cached=$val ;;
    esac
  done < /proc/meminfo
  [[ $total =~ ^[0-9]+$ && $total -gt 0 ]] || die "無法解析 /proc/meminfo"
  if (( has_av == 1 )); then
    used=$((total - available))
  else
    used=$((total - free - buffers - cached))
  fi
  if (( used < 0 )); then
    used=0
  elif (( used > total )); then
    used=$total
  fi
  printf '%s\n' $((used * 10000 / total))
}

read_disk() {
  local out line field cap=""
  out=$(df -P /) || die "df 讀取根目錄失敗"
  line=${out##*$'\n'}
  for field in $line; do
    if [[ $field =~ ^[0-9]+%$ ]]; then
      cap=${field%%%}
    fi
  done
  [[ $cap =~ ^[0-9]+$ ]] || die "無法解析根目錄磁碟使用率"
  printf '%s\n' $((cap * 100))
}

find_ip_bin() {
  if command -v ip >/dev/null 2>&1; then
    command -v ip
  elif [[ -x /sbin/ip ]]; then
    printf '%s\n' /sbin/ip
  elif [[ -x /usr/sbin/ip ]]; then
    printf '%s\n' /usr/sbin/ip
  fi
}

read_ip() {
  local iface=$1 ip_bin line cidr
  [[ -n $iface ]] || return 0
  ip_bin=$(find_ip_bin || true)
  [[ -n $ip_bin ]] || return 0
  line=$("$ip_bin" -4 -o addr show dev "$iface" scope global 2>/dev/null | head -n 1 || true)
  if [[ -z $line ]]; then
    line=$("$ip_bin" -6 -o addr show dev "$iface" scope global 2>/dev/null | head -n 1 || true)
  fi
  [[ -n $line ]] || return 0
  read -r _ _ _ cidr _ <<< "$line"
  cidr=${cidr%%/*}
  cidr=${cidr%%%*}
  printf '%s' "$cidr"
}

read_os() {
  local line os=""
  if [[ -r /etc/os-release ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      case $line in
        PRETTY_NAME=*)
          os=${line#PRETTY_NAME=}
          if [[ $os == \"*\" ]]; then
            os=${os#\"}
            os=${os%\"}
          elif [[ $os == \'*\' ]]; then
            os=${os#\'}
            os=${os%\'}
          fi
          ;;
      esac
    done < /etc/os-release
  fi
  if [[ -z $os ]]; then
    os="$(uname -s) $(uname -r)"
  fi
  printf '%s' "$os"
}

main() {
  local t0 t1 elapsed iface ip_iface
  local c0 c1 b0 tot0 b1 tot1 busy total cpu
  local n0 n1 rx0 tx0 rx1 tx1 rx tx up down
  local mem disk ip os

  [[ -r /proc/stat ]] || die "讀不到 /proc/stat"
  [[ -r /proc/meminfo ]] || die "讀不到 /proc/meminfo"
  [[ -r /proc/net/dev ]] || die "讀不到 /proc/net/dev"
  [[ -r /proc/uptime ]] || die "讀不到 /proc/uptime"
  command -v df >/dev/null 2>&1 || die "找不到 df"

  iface=$(pick_default_iface || true)
  if [[ -n $iface ]]; then
    ip_iface=$iface
  else
    ip_iface=$(first_non_lo || true)
  fi

  t0=$(uptime_ms)
  c0=$(read_cpu)
  n0=$(read_net_bytes "$iface")
  sleep 1
  c1=$(read_cpu)
  n1=$(read_net_bytes "$iface")
  t1=$(uptime_ms)

  read -r b0 tot0 <<< "$c0"
  read -r b1 tot1 <<< "$c1"
  busy=$((b1 - b0))
  total=$((tot1 - tot0))
  if (( busy < 0 )); then
    busy=0
  fi
  if (( total <= 0 )); then
    cpu=0
  else
    cpu=$((busy * 10000 / total))
  fi

  read -r rx0 tx0 <<< "$n0"
  read -r rx1 tx1 <<< "$n1"
  if (( rx1 >= rx0 )); then
    rx=$((rx1 - rx0))
  else
    rx=0
  fi
  if (( tx1 >= tx0 )); then
    tx=$((tx1 - tx0))
  else
    tx=0
  fi

  elapsed=$((t1 - t0))
  if (( elapsed <= 0 )); then
    elapsed=1000
  fi
  # Mbps 到小數兩位：bytes * 8 / 秒 / 1e6，再乘 100。
  down=$((rx * 4 / (elapsed * 5)))
  up=$((tx * 4 / (elapsed * 5)))

  mem=$(read_mem)
  disk=$(read_disk)
  ip=$(read_ip "$ip_iface")
  os=$(read_os)

  printf '{"cpu_percent":%s,"memory_percent":%s,"disk_percent":%s,"upload_mbps":%s,"download_mbps":%s,"ip":"%s","os":"%s"}\n' \
    "$(fmt2 "$cpu")" \
    "$(fmt2 "$mem")" \
    "$(fmt2 "$disk")" \
    "$(fmt2 "$up")" \
    "$(fmt2 "$down")" \
    "$(json_escape "$ip")" \
    "$(json_escape "$os")"
}

main "$@"
