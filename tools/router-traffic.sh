#!/bin/bash
# router-traffic.sh —— 从中兴 F50 Pro（5G 路由器）采集流量与信号
#
# 设计要点：
#   · 只在「连着这台 F50 Pro」时采集；切到别的网络自动暂停，连回来自动恢复
#   · 判断依据是网关 MAC（唯一、免权限）。不读 SSID —— macOS 的位置隐私
#     保护把 SSID 挡死了，网关 MAC 是等效且稳定的替代
#   · 读命令本来不需要登录，仍实现了登录兜底（固件升级后可能需要）
#
# 用法：
#   router-traffic.sh watch     # 单次检查+按需采集（launchd 每 60s 调这个）
#   router-traffic.sh sample    # 强制立刻采一次
#   router-traffic.sh report    # 汇总：流量走势 / 信号 / 与本机对账 / 切换事件
#   router-traffic.sh status    # 当前网络与设备状态
#
# 数据：~/inbox/router-traffic.csv

set -u

TARGET_MAC="${RT_TARGET_MAC:-5c:ff:a9:13:24:6c}"
GW_IP="192.168.0.1"
API_GET="http://${GW_IP}/goform/goform_get_cmd_process"
API_SET="http://${GW_IP}/goform/goform_set_cmd_process"
REFERER="http://${GW_IP}/index.html"

CSV="$HOME/inbox/router-traffic.csv"
STATE="$HOME/inbox/.router-traffic.state"
COOKIE="$HOME/inbox/.f50-cookies.txt"
PWFILE="$HOME/inbox/.f50-password"
SAMPLE_EVERY=5

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"
HDR="timestamp,event,monthly_tx_bytes,monthly_rx_bytes,monthly_total_mb,rsrp_dbm,network_type,signalbar,stations,wan_ip,local_in_bytes,local_out_bytes"
CMD="flux_monthly_tx_bytes,flux_monthly_rx_bytes,Z5g_rsrp,network_type,station_list,wan_ipaddr,network_signalbar"

now_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
now_sec() { date +%s; }
h256()    { printf '%s' "$1" | shasum -a 256 | awk '{print toupper($1)}'; }

get_gw_ip() { route -n get default 2>/dev/null | awk '/gateway/{print $2}'; }
get_gw_mac() {
  local gw; gw=$(get_gw_ip)
  [ -z "$gw" ] && return
  ping -c1 -t1 "$gw" >/dev/null 2>&1
  arp -n "$gw" 2>/dev/null | awk '{print $4}' | grep -E '^([0-9a-f]{1,2}:){5}' | head -1
}

on_target() {
  local gw mac
  gw=$(get_gw_ip); mac=$(get_gw_mac)
  if [ -n "$mac" ]; then [ "$mac" = "$TARGET_MAC" ]; else [ "$gw" = "$GW_IP" ]; fi
}

state_get() { [ -f "$STATE" ] && head -1 "$STATE" 2>/dev/null; }
state_sec() { state_get | awk -F'|' '{print $1}'; }
state_on()  { state_get | awk -F'|' '{print $3}'; }
state_put() { printf '%s|%s|%s\n' "${1:-$(now_sec)}" "$(now_ts)" "${2:-off}" > "$STATE"; }

api_get() {
  curl -s --noproxy '*' -m 8 -b "$COOKIE" -c "$COOKIE" -A "$UA" -H "Referer: $REFERER" \
       "${API_GET}?isTest=false&cmd=$1&multi_data=1" 2>/dev/null
}

ensure_login() {
  local pw ld hash resp
  [ -f "$PWFILE" ] || return 1
  pw=$(cat "$PWFILE")
  ld=$(api_get "LD" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("LD",""))' 2>/dev/null)
  [ -z "$ld" ] && return 1
  hash=$(h256 "$(h256 "$pw")$ld")
  resp=$(curl -s --noproxy '*' -m 8 -b "$COOKIE" -c "$COOKIE" -A "$UA" -H "Referer: $REFERER" \
         -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
         -X POST "$API_SET" --data "isTest=false&goformId=LOGIN&password=${hash}" 2>/dev/null)
  case "$resp" in *'"result":0'*) return 0 ;; *) return 1 ;; esac
}

read_state() {
  local raw
  raw=$(api_get "$CMD")
  case "$raw" in
    *monthly_rx_bytes*|*station_list*|*network_type*) printf '%s' "$raw"; return 0 ;;
  esac
  if ensure_login; then
    raw=$(api_get "$CMD"); printf '%s' "$raw"; return 0
  fi
  return 1
}

parse_env() {
  RJSON="$1" python3 <<'PY'
import os, json, sys
try:
    d = json.loads(os.environ.get("RJSON") or "{}")
except Exception:
    sys.exit(1)
st = d.get("station_list") or []
macs = ";".join(x.get("mac_addr", "") for x in st if isinstance(x, dict))
def g(k, dv=""):
    v = d.get(k, dv)
    return dv if v in (None, "") else v
out = {
    "R_TX": g("flux_monthly_tx_bytes", "0"),
    "R_RX": g("flux_monthly_rx_bytes", "0"),
    "RSRP": g("Z5g_rsrp", ""),
    "NTYPE": g("network_type", ""),
    "SIGBAR": g("network_signalbar", ""),
    "WANIP": g("wan_ipaddr", ""),
    "STAS": str(len(st)),
    "STAMAC": macs,
}
for k, v in out.items():
    v = str(v).replace("|", " ").replace("\n", " ").replace('"', "")
    print(k + '="' + v + '"')
PY
}

local_counters() {
  netstat -ib 2>/dev/null | awk -v i="${1:-en0}" '$1==i && $3 ~ /^<Link/ {print $7, $10; exit}'
}

csv_init() { [ -f "$CSV" ] || echo "$HDR" > "$CSV"; }

do_sample() {
  local event="${1:-sample}"
  on_target || { echo "不在目标网络，跳过采集"; return 1; }
  local raw
  raw=$(read_state) || { echo "读取路由器失败"; return 1; }

  R_TX=0; R_RX=0; RSRP=""; NTYPE=""; SIGBAR=""; WANIP=""; STAS="0"; STAMAC=""
  eval "$(parse_env "$raw")" || { echo "解析路由器返回失败"; return 1; }

  local lc lin lout
  lc=$(local_counters en0); lin=$(echo "$lc" | awk '{print $1}'); lout=$(echo "$lc" | awk '{print $2}')

  csv_init
  awk -v ts="$(now_ts)" -v ev="$event" -v tx="${R_TX:-0}" -v rx="${R_RX:-0}" \
      -v rs="$RSRP" -v nt="$NTYPE" -v sb="$SIGBAR" -v st="$STAS" -v wi="$WANIP" \
      -v li="${lin:-0}" -v lo="${lout:-0}" \
      'BEGIN{printf "%s,%s,%d,%d,%.2f,%s,%s,%s,%s,%s,%s,%s\n", ts,ev,tx,rx,(tx+rx)/1000000,rs,nt,sb,st,wi,li,lo}' >> "$CSV"

  state_put "$(now_sec)" "on"
  printf '%s 已采集[%s]: 本月 %.2f MB, RSRP %s dBm, 接入 %s 台\n' \
    "$(date '+%H:%M:%S')" "$event" \
    "$(awk -v a="${R_TX:-0}" -v b="${R_RX:-0}" 'BEGIN{printf "%.2f",(a+b)/1048576}')" \
    "${RSRP:-?}" "${STAS:-0}"
}

do_watch() {
  local prev_on cur_on last
  prev_on=$(state_on); [ -z "$prev_on" ] && prev_on="off"
  cur_on="off"; on_target && cur_on="on"

  if [ "$cur_on" = "off" ]; then
    if [ "$prev_on" = "on" ]; then
      csv_init
      echo "$(now_ts),paused,0,0,0,,,0,0,,0,0" >> "$CSV"
      echo "$(date '+%H:%M:%S') 已离开目标网络 → 暂停采集"
    fi
    state_put "$(now_sec)" "off"
    return 0
  fi

  if [ "$prev_on" != "on" ]; then
    echo "$(date '+%H:%M:%S') 已连上目标网络 → 恢复采集"
    do_sample "resumed"
    state_put "$(now_sec)" "on"
    return 0
  fi

  last=$(state_sec); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(( $(now_sec) - last )) -ge $(( SAMPLE_EVERY * 60 )) ]; then
    do_sample "sample"
  fi
  state_put "$(now_sec)" "on"
}

do_report() {
  [ -f "$CSV" ] || { echo "还没有数据"; return 1; }
  echo "════ 本月流量走势 ════"
  # 用原始字节列($3/$4)算，避免受历史行里的 MB 列单位差异影响；十进制 1 MB = 1e6
  awk -F, 'NR>1 && $2!="paused" { printf "  %-19s %9.2f MB   RSRP %-6s %-4s  接入 %s 台\n", $1, ($3+$4)/1000000, ($6==""?"-":$6), $7, $9 }' "$CSV" | tail -15
  echo
  echo "════ 与本机计数对账（自基线起的增量）════"
  printf "  %-19s %12s %12s %10s %9s\n" "时间" "路由器增量" "本机增量" "差值" "本机/路由"
  awk -F, 'NR>1 && $2!="paused" && $11>0 {
      n++
      if (n==1) { br=($3+$4)/1000000; bl=($11+$12)/1000000 }
      dr=($3+$4)/1000000-br; dl=($11+$12)/1000000-bl
      printf "  %-19s %9.1f MB %9.1f MB %7.1f MB %8.1f%%\n", $1, dr, dl, dl-dr, (dr>0?dl*100/dr:0)
    }' "$CSV" | tail -10
  echo "  （以第一个采样点为基线，比同一窗口内两边各涨多少。本机略大属正常：Wi-Fi 帧头与重传开销）"
  echo
  echo "════ 网络切换事件 ════"
  n=$(awk -F, 'NR>1 && ($2=="paused"||$2=="resumed")' "$CSV" | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then echo "  （暂无切换记录）"; else
    awk -F, 'NR>1 && ($2=="paused"||$2=="resumed") { printf "  %-19s %s\n", $1, $2 }' "$CSV" | tail -10
  fi
  echo
  echo "════ 合计 ════"
  awk -F, 'NR>1 && $2!="paused" { n++; if(($3+$4)/1000000>mx) mx=($3+$4)/1000000 } END{ printf "  %d 次采样   本月峰值 %.2f MB\n", n, mx }' "$CSV"
}

do_status() {
  local gw mac raw
  gw=$(get_gw_ip); mac=$(get_gw_mac)
  echo "  当前网关:   ${gw:-无}"
  echo "  网关 MAC:   ${mac:-未获取}"
  echo "  目标网络:   $TARGET_MAC"
  if on_target; then echo "  判断:       ✅ 连着目标 F50 Pro（采集中）"
  else echo "  判断:       ⏸  不在目标网络（已暂停）"; return 0; fi
  raw=$(read_state) || { echo "  读取路由器失败"; return 1; }
  RJSON="$raw" python3 <<'PY'
import os, json
d = json.loads(os.environ["RJSON"])
tx = int(d.get("flux_monthly_tx_bytes") or 0)
rx = int(d.get("flux_monthly_rx_bytes") or 0)
print("  本月流量:   上传 %.3f GB / 下载 %.3f GB / 合计 %.3f GB" % (tx/1073741824, rx/1073741824, (tx+rx)/1073741824))
print("  网络:       %s   信号格 %s/5   RSRP %s dBm" % (d.get('network_type','?'), d.get('network_signalbar','?'), d.get('Z5g_rsrp','?')))
print("  WAN IP:     %s" % d.get('wan_ipaddr','?'))
st = d.get("station_list") or []
print("  接入设备:   %d 台" % len(st))
for x in st:
    if isinstance(x, dict):
        print("      %s   %s" % (x.get('mac_addr','?'), x.get('ip_addr','?')))
PY
}

case "${1:-watch}" in
  watch)  do_watch ;;
  sample) do_sample "manual" ;;
  report) do_report ;;
  status) do_status ;;
  *) echo "用法: $0 {watch|sample|report|status}"; exit 2 ;;
esac
