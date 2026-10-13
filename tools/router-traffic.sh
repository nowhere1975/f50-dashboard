#!/bin/bash
# F50 只读采集。每分钟调用 watch 时，默认每五分钟采样一次。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GW_IP="${RT_GATEWAY:-192.168.0.1}"
TARGET_MAC="${RT_TARGET_MAC:-}"
CSV="${RT_CSV:-$HOME/inbox/router-traffic.csv}"
STATE="${RT_STATE:-$HOME/inbox/.router-traffic.state}"
SAMPLE_SEC="${RT_SAMPLE_SEC:-300}"
CMD="flux_monthly_tx_bytes,flux_monthly_rx_bytes,monthly_tx_bytes,monthly_rx_bytes,Z5g_rsrp,network_type,station_list,wan_ipaddr,network_signalbar,wa_inner_version,cr_version"
HDR="timestamp,event,monthly_tx_bytes,monthly_rx_bytes,monthly_total_mb,rsrp_dbm,network_type,signalbar,stations,wan_ip,local_in_bytes,local_out_bytes"

now_sec() { date +%s; }
now_ts() { date '+%Y-%m-%d %H:%M:%S'; }
get_gw() { /sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2}'; }
get_iface() { /sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }
get_mac() { /usr/sbin/arp -n "$GW_IP" 2>/dev/null | awk '{print $4}'; }
on_target() {
  local gw mac
  gw=$(get_gw) || return 1
  [ "$gw" = "$GW_IP" ] || return 1
  if [ -n "$TARGET_MAC" ]; then
    mac=$(get_mac) || return 1
    [ "$mac" = "$TARGET_MAC" ] || return 1
  fi
}
read_state() {
  curl --silent --show-error --fail --noproxy '*' --max-time 8 \
    -H "Referer: http://$GW_IP/index.html" \
    "http://$GW_IP/goform/goform_get_cmd_process?isTest=false&cmd=$CMD&multi_data=1"
}
state_load() {
  LAST_SAMPLE=0; WAS_ON=off
  if [ -f "$STATE" ]; then
    IFS='|' read -r LAST_SAMPLE _ WAS_ON < "$STATE" || true
    case "$LAST_SAMPLE" in ''|*[!0-9]*) LAST_SAMPLE=0 ;; esac
  fi
}
state_put() {
  printf '%s|%s|%s\n' "$LAST_SAMPLE" "$(now_ts)" "$WAS_ON" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}
csv_init() { [ -f "$CSV" ] || printf '%s\n' "$HDR" > "$CSV"; }
sample() {
  local event="$1" raw iface counts rx='' tx='' row
  on_target || { echo "当前不在目标网络，已暂停采集"; return 1; }
  raw=$(read_state) || return 1
  iface=$(get_iface) || iface=''
  counts=$(/usr/sbin/netstat -ib 2>/dev/null | awk -v i="$iface" '$1==i && $3 ~ /^<Link/ {print $7,$10;exit}') || counts=''
  read -r rx tx <<< "$counts" || true
  row=$(RJSON="$raw" R_EVENT="$event" R_TIMESTAMP="$(now_ts)" R_LOCAL_RX="$rx" R_LOCAL_TX="$tx" \
    python3 "$SCRIPT_DIR/router-data.py" csv) || return 1
  csv_init
  printf '%s\n' "$row" >> "$CSV"
  LAST_SAMPLE=$(now_sec); WAS_ON=on
  state_put
  echo "$(now_ts) 已采集（$event）"
}
watch() {
  local current
  if ! on_target; then
    if [ "$WAS_ON" = on ]; then
      csv_init
      printf '%s,paused,,,,,,,,,,\n' "$(now_ts)" >> "$CSV"
    fi
    WAS_ON=off; state_put; return 0
  fi
  current=$(now_sec)
  if [ "$WAS_ON" != on ]; then sample resumed
  elif [ $((current - LAST_SAMPLE)) -ge "$SAMPLE_SEC" ] || [ "$current" -lt "$LAST_SAMPLE" ]; then sample sample
  fi
  # 未采样时不更新 LAST_SAMPLE，避免每次检查都把采样时间推迟。
}
status() {
  echo "  默认网关: $(get_gw || true)"
  on_target || { echo "  当前不在目标网络"; return 0; }
  local raw
  raw=$(read_state) || return 1
  RJSON="$raw" python3 "$SCRIPT_DIR/router-data.py" status
}
report() { python3 "$SCRIPT_DIR/router-report.py" "$CSV"; }

action="${1:-watch}"
case "$action" in
  status) status; exit ;;
  report) report; exit ;;
  watch|sample) ;;
  *) echo "用法：$0 {watch|sample|status|report}"; exit 2 ;;
esac
case "$SAMPLE_SEC" in ''|*[!0-9]*|0) echo "RT_SAMPLE_SEC 必须为正整数" >&2; exit 2 ;; esac
mkdir -p "$(dirname "$CSV")" "$(dirname "$STATE")"
LOCK="$STATE.lock"
mkdir "$LOCK" 2>/dev/null || { echo "已有采集任务运行，跳过"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
state_load
if [ "$action" = watch ]; then watch; else sample manual; fi
