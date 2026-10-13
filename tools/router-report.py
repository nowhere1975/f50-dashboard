#!/usr/bin/env python3
"""按连续采样窗口对账，断线、重置和跨周期后重建基线。"""
import csv
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
if not p.exists():
    print("还没有数据")
    sys.exit(0)
with p.open(newline="") as source:
    rows = list(csv.DictReader(source))
print("════ 路由器用量（十进制 MB）════")
for row in rows[-15:]:
    if row.get("event") == "paused":
        print("  %s 已暂停采集" % row["timestamp"])
        continue
    try:
        total = int(row["monthly_tx_bytes"]) + int(row["monthly_rx_bytes"])
        print("  %s  %.2f MB  %s" % (row["timestamp"], total / 1e6, row.get("network_type", "")))
    except (ValueError, KeyError):
        print("  %s 字段无效" % row.get("timestamp", "?"))
print("════ 同一连续窗口对账 ════")
baseline = previous = None
result = []
for row in rows:
    try:
        current = (int(row["monthly_tx_bytes"]) + int(row["monthly_rx_bytes"]),
                   int(row["local_in_bytes"]) + int(row["local_out_bytes"]))
        if row["event"] == "resumed" or previous is None or current[0] < previous[0] or current[1] < previous[1]:
            baseline = current
        dr, dl = current[0] - baseline[0], current[1] - baseline[1]
        result.append("  %s  路由器 %.2f MB / 本机 %.2f MB" % (row["timestamp"], dr/1e6, dl/1e6))
        previous = current
    except (ValueError, KeyError):
        baseline = previous = None
for line in result[-10:]:
    print(line)
print("  路由器包含全部接入设备；本机与路由器读数不代表相同计费口径。")
