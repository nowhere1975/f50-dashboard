#!/usr/bin/env python3
"""解析 F50 只读响应。文本直接交给 csv 模块，绝不生成 shell 代码。"""
import csv
import datetime
import json
import os
import sys

def counter(data, keys):
    for key in keys:
        value = data.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, int) and 0 <= value <= 2**64 - 1:
            return value
        if isinstance(value, str) and value.strip().isascii() and value.strip().isdigit():
            number = int(value.strip())
            if number <= 2**64 - 1:
                return number
    raise ValueError("上传或下载流量字段缺失或无效")

def read(data):
    if not isinstance(data, dict):
        raise ValueError("路由器未返回 JSON 对象")
    model = str(data.get("wa_inner_version") or data.get("device_name") or "")
    if not model.lower().startswith("f50"):
        raise ValueError("设备型号未确认为 F50")
    tx = counter(data, ["flux_monthly_tx_bytes", "monthly_tx_bytes"])
    rx = counter(data, ["flux_monthly_rx_bytes", "monthly_rx_bytes"])
    if tx + rx > 2**64 - 1:
        raise ValueError("流量计数溢出")
    return tx, rx

def main():
    data = json.loads(os.environ.get("RJSON", ""))
    tx, rx = read(data)
    stations = data.get("station_list") or []
    if not isinstance(stations, list):
        stations = []
    if sys.argv[1] == "csv":
        csv.writer(sys.stdout, lineterminator="\n").writerow([
            os.environ.get("R_TIMESTAMP") or datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            os.environ.get("R_EVENT", "sample"), tx, rx, "%.2f" % ((tx+rx)/1e6),
            data.get("Z5g_rsrp", ""), data.get("network_type", ""), data.get("network_signalbar", ""),
            len(stations), data.get("wan_ipaddr", ""), os.environ.get("R_LOCAL_RX", ""),
            os.environ.get("R_LOCAL_TX", "")])
    else:
        print("  型号:       %s" % data.get("wa_inner_version", ""))
        print("  本周期用量: 上传 %.3f GB / 下载 %.3f GB / 合计 %.3f GB" % (tx/1e9, rx/1e9, (tx+rx)/1e9))
        print("  移动网络:   %s · 信号 %s/5 · RSRP %s dBm" %
              (data.get("network_type", "?"), data.get("network_signalbar", "?"), data.get("Z5g_rsrp", "?")))
        print("  接入设备:   %d 台" % len(stations))
        print("  说明:       套餐余量以运营商查询结果为准")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError) as error:
        print("读取失败：" + str(error), file=sys.stderr)
        sys.exit(1)
