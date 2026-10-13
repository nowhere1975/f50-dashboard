#!/usr/bin/env python3
import csv
import datetime
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
checks = 0
def expect(condition, name):
    global checks
    checks += 1
    if not condition:
        raise AssertionError(name)

with tempfile.TemporaryDirectory(prefix="f50-script-tests-") as directory:
    temp = pathlib.Path(directory)
    script = (ROOT / "tools/router-traffic.sh").read_text().split('action="')[0]
    fixture = script + r"""
REVIEW_SEC=0; LAST_SAMPLE=0; WAS_ON=off; REVIEW_COUNT=0
now_sec() { printf '%s' "§REVIEW_SEC"; }
now_ts() { echo fixture; }
on_target() { return 0; }
state_put() { :; }
sample() { REVIEW_COUNT=§((REVIEW_COUNT+1)); LAST_SAMPLE=§REVIEW_SEC; WAS_ON=on; }
for REVIEW_SEC in 0 60 120 180 240 300 360 420 480 540 600; do watch; done
printf '%s\n' "§REVIEW_COUNT"
""".replace("§",chr(36))
    result = subprocess.run(["bash", "-c", fixture], capture_output=True, text=True, check=True)
    expect(result.stdout.strip() == "3", "five-minute watch cadence")
    off = fixture.split("for REVIEW_SEC")[0] + r"""
REVIEW_SEC=600; LAST_SAMPLE=300; WAS_ON=on
on_target() { return 1; }
csv_init() { :; }
CSV=/dev/null
watch
printf '%s %s\n' "§LAST_SAMPLE" "§WAS_ON"
""".replace("§",chr(36))
    result = subprocess.run(["bash", "-c", off], capture_output=True, text=True, check=True)
    expect(result.stdout.strip() == "300 off", "pause keeps last successful sample time")

    payload = dict(wa_inner_version="F50ProV1", flux_monthly_tx_bytes=0, flux_monthly_rx_bytes=0,
                   network_type='$(printf fixture-evaluated),"quoted"', station_list=[])
    env = os.environ.copy()
    env["RJSON"] = json.dumps(payload)
    result = subprocess.run(["python3", str(ROOT/"tools/router-data.py"), "csv"], env=env, capture_output=True, text=True, check=True)
    row = next(csv.reader(io.StringIO(result.stdout)))
    expect(len(row) == 12 and row[6] == payload["network_type"], "router text remains inert and CSV escaped")
    expect(row[2:4] == ["0", "0"], "zero counters accepted")
    payload["flux_monthly_rx_bytes"] = -1
    env["RJSON"] = json.dumps(payload)
    result = subprocess.run(["python3", str(ROOT/"tools/router-data.py"), "csv"], env=env, capture_output=True, text=True)
    expect(result.returncode != 0 and result.stdout == "", "invalid usage never appended as zero")
    payload["flux_monthly_rx_bytes"] = 0; payload["wa_inner_version"] = "MF79"
    env["RJSON"] = json.dumps(payload)
    result = subprocess.run(["python3", str(ROOT/"tools/router-data.py"), "status"], env=env, capture_output=True, text=True)
    expect(result.returncode != 0, "other router model rejected")

    ssid = (ROOT/"tools/ssid-traffic.sh").read_text()
    ssid = ssid[:ssid.index('case "' + chr(36) + '{1:-now}"')]
    state = temp/"ssid.state"; output = temp/"ssid.csv"
    old_time = (datetime.datetime.now() - datetime.timedelta(seconds=10)).strftime("%Y-%m-%d %H:%M:%S")
    state.write_text("gwmac|old\t1000\t100\t"+old_time+"\n")
    fixture = ssid + r"""
CSV="@@CSV@@"; STATE="@@STATE@@"
get_netkey() { echo 'gwmac|new'; }
get_counters() { echo '9000000000 1000000000'; }
do_sample
""".replace("@@CSV@@",str(output)).replace("@@STATE@@",str(state))
    subprocess.run(["bash","-c",fixture],capture_output=True,text=True,check=True)
    with output.open(newline="") as f: row=list(csv.DictReader(f))[0]
    expect(row["in_bytes"]=="0" and row["out_bytes"]=="0","SSID network switch skips cross-network delta")
    state.write_text("gwmac|new\t9000000000\t1000000000\t"+old_time+"\n")
    fixture=fixture.replace("9000000000 1000000000","9000000010 1000000005")
    subprocess.run(["bash","-c",fixture],capture_output=True,text=True,check=True)
    with output.open(newline="") as f: row=list(csv.DictReader(f))[-1]
    expect(row["in_bytes"]=="10" and row["out_bytes"]=="5","SSID same-network delta")
    original=state.read_bytes()
    failure=fixture.replace("get_counters() { echo '9000000010 1000000005'; }","get_counters() { return 0; }")
    result=subprocess.run(["bash","-c",failure],capture_output=True,text=True)
    expect(result.returncode!=0 and state.read_bytes()==original,"missing counter keeps valid baseline file")

    report=temp/"router.csv"
    with report.open("w",newline="") as f:
        writer=csv.writer(f)
        writer.writerow(["timestamp","event","monthly_tx_bytes","monthly_rx_bytes","monthly_total_mb","rsrp_dbm","network_type","signalbar","stations","wan_ip","local_in_bytes","local_out_bytes"])
        writer.writerow(["t1","sample",10,90,0,"","5G","","","",40,60])
        writer.writerow(["t2","paused","","","","","","","","","",""])
        writer.writerow(["t3","resumed",20,180,0,"","5G","","","",4000,6000])
        writer.writerow(["t4","sample",30,270,0,"","5G","","","",4010,6090])
    result=subprocess.run(["python3",str(ROOT/"tools/router-report.py"),str(report)],capture_output=True,text=True,check=True)
    expect("t3  路由器 0.00 MB / 本机 0.00 MB" in result.stdout,"report resets baseline after pause")
print("PASS: %s script regression checks" % checks)
