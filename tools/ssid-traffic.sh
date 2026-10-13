#!/bin/bash
# 按「接入的网络」记录流量消耗
#
# 网络标识优先级：
#   ① SSID        —— 需位置服务权限；本机当前被 redacted，脚本会自动探测
#   ② 网关 MAC     —— 免权限、唯一、稳定（同一路由器永远同一个值）
#   ③ 网关 IP      —— 最后兜底
#
# 用法：
#   ./ssid-traffic.sh sample     采一次样（cron 用这个）
#   ./ssid-traffic.sh report     汇总：按网络 / 按天
#   ./ssid-traffic.sh now        看当前网络与实时速率
#
# 数据：~/inbox/ssid-traffic.csv

set -u
IF="${SSID_TRAFFIC_IF:-en0}"
CSV="$HOME/inbox/ssid-traffic.csv"
STATE="$HOME/inbox/.ssid-traffic.state"
# 友好名映射表：每行 "键<TAB>名字"。键可以是 gwmac|xx:xx:.. 或 ssid|网络名
NAMES="$HOME/inbox/ssid-names.tsv"

# 把内部标识翻译成可读名字；没有映射就原样返回
friendly_name() {
  local key="$1" id name
  id="${key##*|}"
  if [ -f "$NAMES" ]; then
    name=$(awk -F'\t' -v k="$key" -v i="$id" '$1==k || $1==i {print $2; exit}' "$NAMES" 2>/dev/null)
    [ -n "$name" ] && { printf '%s' "$name"; return; }
  fi
  printf '%s' "$id"
}

# ---------- 取当前网络标识 ----------
get_ssid() {
  local s
  # 方式 1：networksetup（中英文都要匹配）
  s=$(networksetup -getairportnetwork "$IF" 2>/dev/null \
      | sed -n 's/^Current Wi-Fi Network: //p; s/^当前 Wi-Fi 网络：//p')
  # 方式 2：system_profiler
  if [ -z "$s" ] || [ "$s" = "<redacted>" ]; then
    s=$(system_profiler SPAirPortDataType 2>/dev/null \
        | awk '/Current Network Information:/{getline; gsub(/^[ \t]+/,""); sub(/:$/,""); print; exit}')
  fi
  case "$s" in ""|"<redacted>"|"Network Type: Infrastructure") s="" ;; esac
  printf '%s' "$s"
}

get_gw()      { route -n get default 2>/dev/null | awk '/gateway/{print $2}'; }
get_gw_mac()  {
  local gw; gw=$(get_gw)
  [ -z "$gw" ] && return
  ping -c1 -t1 "$gw" >/dev/null 2>&1
  arp -n "$gw" 2>/dev/null | awk '{print $4}' | grep -E '^([0-9a-f]{1,2}:){5}' | head -1
}

# 返回：<标识类型>|<标识值>
get_netkey() {
  local ssid mac gw
  ssid=$(get_ssid)
  if [ -n "$ssid" ]; then printf 'ssid|%s' "$ssid"; return; fi
  mac=$(get_gw_mac)
  if [ -n "$mac" ]; then printf 'gwmac|%s' "$mac"; return; fi
  gw=$(get_gw)
  printf 'gwip|%s' "${gw:-none}"
}

# ---------- 读接口累计字节 ----------
# 输出：<in_bytes> <out_bytes>
get_counters() {
  netstat -ib 2>/dev/null | awk -v i="$IF" '$1==i && $3 ~ /^<Link/ {print $7, $10; exit}'
}

csv_escape() { printf '%s' "$1" | sed 's/,/ /g'; }

# ---------- 采样 ----------
do_sample() {
  local now key raw in_b out_b
  now=$(date '+%Y-%m-%d %H:%M:%S')
  key=$(get_netkey)
  raw=$(get_counters)
  if [ -z "$raw" ]; then
    echo "接口 $IF 无计数器（未连接？）" >&2
    return 1
  fi
  in_b=$(echo "$raw" | awk '{print $1}')
  out_b=$(echo "$raw" | awk '{print $2}')

  local prev_key="" prev_in="" prev_out="" prev_ts=""
  if [ -f "$STATE" ]; then
    # 用 TAB 分隔：netkey 本身含 '|'，不能拿 '|' 当字段分隔符
    IFS=$'\t' read -r prev_key prev_in prev_out prev_ts < "$STATE" || true
  fi

  local d_in=0 d_out=0 dt=0
  if [ -n "$prev_in" ]; then
    dt=$(( $(date -j -f '%Y-%m-%d %H:%M:%S' "$now" +%s) - $(date -j -f '%Y-%m-%d %H:%M:%S' "$prev_ts" +%s) ))
    d_in=$(( in_b - prev_in ));  d_out=$(( out_b - prev_out ))
    # 计数器回绕/接口重置 → 记为 0，避免负数污染统计
    [ "$d_in"  -lt 0 ] && d_in=0
    [ "$d_out" -lt 0 ] && d_out=0
    [ "$dt"    -lt 0 ] && dt=0
  fi

  # 表头
  [ -f "$CSV" ] || echo "timestamp,net_type,net_id,in_bytes,out_bytes,in_mb,out_mb,interval_s,total_in_mb,total_out_mb" > "$CSV"

  awk -v ts="$now" -v kt="${key%%|*}" -v kid="$(csv_escape "${key##*|}")" \
      -v di="$d_in" -v do_="$d_out" -v dt="$dt" -v ti="$in_b" -v to="$out_b" \
      'BEGIN{printf "%s,%s,%s,%d,%d,%.3f,%.3f,%d,%.1f,%.1f\n", ts,kt,kid,di,do_,di/1000000,do_/1000000,dt,ti/1000000,to/1000000}' >> "$CSV"

  printf '%s\t%s\t%s\t%s\n' "$key" "$in_b" "$out_b" "$now" > "$STATE"

  # 网络切换时提示
  if [ -n "$prev_key" ] && [ "$prev_key" != "$key" ]; then
    echo "[$(date '+%H:%M:%S')] 网络切换: ${prev_key} → ${key}"
  fi
}

# ---------- 汇总 ----------
do_report() {
  [ -f "$CSV" ] || { echo "还没有数据，先跑 sample"; return 1; }
  echo "════ 按网络汇总 ════"
  awk -F, -v names="$NAMES" '
    BEGIN {
      # 读友好名映射表（键<TAB>名字），读不到就退化为显示原始标识
      if (names != "") {
        while ((getline line < names) > 0) {
          if (line == "" || line ~ /^#/) continue
          n2 = split(line, p, "\t")
          if (n2 >= 2) { map[p[1]] = p[2] }
        }
        close(names)
      }
    }
    NR>1 {
      key=$2"|"$3
      if(!(key in di)){order[++n]=key}
      di[key]+=$4; do_[key]+=$5
    }
    END{
      printf "  %-10s %-26s %11s %11s\n","类型","网络","下载","上传"
      for(i=1;i<=n;i++){
        k=order[i]; split(k,a,"|")
        label = (k in map) ? map[k] : ((a[2] in map) ? map[a[2]] : a[2])
        printf "  %-10s %-26s %8.1f MB %8.1f MB\n", a[1], label, di[k]/1000000, do_[k]/1000000
      }
    }' "$CSV"
  echo
  echo "════ 按天汇总 ════"
  printf "  %-12s %12s %12s %12s\n" "日期" "下载(GB)" "上传(GB)" "合计(GB)"
  # 表头单独打印：不能和 awk 输出一起送进 sort，否则表头会被排到中间
  awk -F, 'NR>1 { d=substr($1,1,10); di[d]+=$4; do_[d]+=$5 }
    END{
      for(d in di) printf "  %-12s %12.2f %12.2f %12.2f\n", d, di[d]/1000000000, do_[d]/1000000000, (di[d]+do_[d])/1000000000
    }' "$CSV" | sort
  echo
  echo "════ 合计 ════"
  awk -F, 'NR>1 { di+=$4; do_+=$5; n++ }
    END{ printf "  %d 条采样   下载 %.2f GB   上传 %.2f GB   合计 %.2f GB\n", n, di/1000000000, do_/1000000000, (di+do_)/1000000000 }' "$CSV"
}

# ---------- 当前状态 ----------
do_now() {
  local key raw in_b out_b
  key=$(get_netkey)
  raw=$(get_counters)
  echo "  接口:   $IF"
  echo "  网络:   $(friendly_name "$key")"
  echo "  标识:   ${key%%|*} = ${key##*|}"
  echo "  网关:   $(get_gw)"
  echo "  本机:   $(ipconfig getifaddr "$IF" 2>/dev/null)"
  echo "  出口:   $(curl -s --noproxy '*' -m 5 http://ip-api.com/line/?fields=query 2>/dev/null | head -1)"
  if [ -n "$raw" ]; then
    in_b=$(echo "$raw" | awk '{print $1}'); out_b=$(echo "$raw" | awk '{print $2}')
    echo "  累计:   下载 $(echo "$in_b" | awk '{printf "%.2f", $1/1000000000}') GB   上传 $(echo "$out_b" | awk '{printf "%.2f", $1/1000000000}') GB"
    if [ -f "$STATE" ]; then
      local pk pi po pts
      IFS=$'\t' read -r pk pi po pts < "$STATE" || true
      if [ -n "$pi" ]; then
        local dt=$(( $(date +%s) - $(date -j -f '%Y-%m-%d %H:%M:%S' "$pts" +%s) ))
        if [ "$dt" -gt 0 ]; then
          echo "  自上次采样（${dt}s 前）: 下载 $(( (in_b-pi)/1024 )) KB   上传 $(( (out_b-po)/1024 )) KB"
          echo "  平均速率: 下载 $(echo "$in_b $pi $dt" | awk '{printf "%.1f", ($1-$2)*8/1000000/$3}') Mbps   上传 $(echo "$out_b $po $dt" | awk '{printf "%.1f", ($1-$2)*8/1000000/$3}') Mbps"
        fi
      fi
    fi
  fi
}

case "${1:-now}" in
  sample) do_sample ;;
  report) do_report ;;
  now)    do_now ;;
  *) echo "用法: $0 {sample|report|now}"; exit 2 ;;
esac
