# 踩坑记录

这份文档记录开发过程中真实遇到的坑。**每一条都是花了时间才定位的**，
写下来是为了让 review 的人和后续维护者不用再踩一遍。

---

## 1. `netstat` 在 `/usr/sbin`，不在 `/usr/bin`

### 症状
菜单栏实时速率**永远是 0**。

### 原因
代码里写了绝对路径 `/usr/bin/netstat`，但 macOS 上它在 `/usr/sbin/`：

```
$ ls /usr/bin/netstat
ls: /usr/bin/netstat: No such file or directory
$ ls /usr/sbin/netstat
-r-xr-xr-x  1 root  wheel  712144  /usr/sbin/netstat
```

`Process` 启动失败时抛的错被 `catch { return "" }` 吞掉，返回空字符串 →
解析不到任何行 → 计数器恒为 0 → 速率恒为 0。

**在终端里手测不出来**，因为 shell 会走 `PATH` 找到 `/usr/sbin/netstat`。
只有 App 里硬编码的绝对路径会踩这个坑。

### 修复
所有外部命令都通过 `SysInfo.findBin([...])` 按候选列表探测：

```swift
static let netstat = findBin(["/usr/sbin/netstat", "/usr/bin/netstat", "/bin/netstat"])
```

### 教训
**GUI 程序里绝不要硬编码系统命令路径。** 而且 `catch` 里至少要留下可诊断的信息 ——
第 4 节的 `--check` 就是为此加的。

---

## 2. 从 Swift 进程调用 `arp` 恒返回空

### 症状
拿不到网关 MAC，网络指纹退化。

### 现象
同一进程里，`netstat` / `route` / `ipconfig` / `ndp` **全部正常**，
唯独 `arp` 什么都不返回（退出码 0、stdout 0 字节、stderr 0 字节）。

测试过的调用方式，**全部无效**：

| 方式 | 结果 |
|---|---|
| `arp -an` | 0 字节 |
| `arp -n <gw>` | `"-- no entry"` |
| `arp <gw>` | `"-- no entry"` |
| `/bin/sh -c 'arp -an'` | 0 字节 |
| `/bin/bash -lc 'arp -an'` | 0 字节 |
| 显式设置 PATH 环境 | 0 字节 |
| 指定工作目录 | 0 字节 |

而同样的命令**在终端里完全正常**：

```
$ arp -an
? (192.168.0.1) at 5c:ff:a9:13:24:6c on en0 ifscope [ethernet]
...
```

`ndp -an`（IPv6 邻居表）从 Swift 里则正常返回 1167 字节 —— 但里面没有网关条目。

### 结论
未查明根因，推测与 `Process` 创建子进程时的某种继承属性有关。
**已放弃用 MAC 做网络指纹**，改用「网关 IP + DNS」。

代码里保留了 `SysInfo.gatewayMAC()`，因为在 launchd 启动的上下文里也许可行；
拿不到就自动降级，不影响功能。

> 如果你知道原因，非常欢迎提 issue。

---

## 3. 单位：二进制 vs 十进制，配额算错 7.4%

### 症状
用户反馈"5G 路由器流量统计不准"：后台显示 **1.6 GB**，工具显示 **1.53 GB**。

### 原因
数据一直是对的，**错的是标签**：

```
1,642,823,000 字节
  ÷ 2³⁰ = 1.53    ← 工具显示的，标签写 "GB" 但实际是 GiB
  ÷ 10⁹ = 1.64    ← 运营商后台显示的，四舍五入 1.6
```

### 为什么必须修
不只是看着别扭。100 GB 的配额下：

```
二进制口径算百分比 → 系统性少算 7.4% → 累计误差 7 GB
```

对"每月 100 GB"这种硬额度，**7 GB 足够让你在月中被限速**。

### 修复
全部改用十进制（`1 KB = 1000 B`），与运营商和路由器后台一致。
见 `Fmt.swift` 里的 `kilo/mega/giga/tera` 常量。

> 同理，`router-traffic.sh` 和 `ssid-traffic.sh` 也一并改了。

---

## 4. SSID 读不到（macOS 位置隐私）

### 症状
需要按「接入的网络」分开统计，但读不到当前 SSID。

### 现象
三种方式全部失败：

| 方式 | 结果 |
|---|---|
| `networksetup -getairportnetwork en0` | `"You are not associated with an AirPort network."` |
| `system_profiler SPAirPortDataType` | SSID 显示为 `<redacted>` |
| Swift + CoreWLAN `iface.ssid()` | 返回 `nil` |

**关键诊断**：CoreWLAN 里 **RSSI / 噪声 / 信道都能读，只有 SSID 和 BSSID 是 nil**。

这是「位置权限未生效」的确凿签名 —— 非位置字段正常，位置门控字段为空。

### 已经做了但没用的尝试
- 给 App 授予位置服务（`locationd` 的 clients.plist 里确实出现了
  `com.deepseek.dsh`，`Authorized = 1`，但**依然读不到**）
- 重启宿主 App 让 TCC 重新读取（TCC 权限在**进程启动时**读取）
- 直接调 CoreWLAN 原生 API 绕过 `system_profiler`

### 结论
**放弃 SSID**，改用网络指纹：

```
① 网关 + DNS 都是 192.168.0.1  →  "f50"（5G 路由器专属桶）
② 网关 MAC 可读                →  "mac:<MAC>"（本机不可用）
③ 兜底                         →  "gw:<IP>|dns:<DNS>"
```

> **已知局限**：若另一个路由器恰好也是 `192.168.0.1` 且 DNS 指向自己，
> 会与 F50 合并统计。遇到这种情况需要在配置里手工指定网关。

---

## 5. 路由器返回的字段类型不统一

同一个 JSON 响应里：

| 字段 | 类型 |
|---|---|
| `Z5g_rsrp` | **字符串** `"-82"` |
| `network_signalbar` | **数字** `5` |
| `monthly_tx_bytes` | **数字** |
| `wan_ipaddr` | **字符串** |

只按一种类型解析，就会静默丢失数据（表现为菜单里某一行空白）。

### 修复
`RouterClient.parse` 里的取值函数同时接受两种：

```swift
func str(_ key: String) -> String {
    if let v = obj[key] as? String { return v }
    if let n = obj[key] as? NSNumber { return n.stringValue }
    return ""
}
```

---

## 6. 登录失败 5 次锁定 300 秒

设备配置里：`MAX_LOGIN_COUNT: 5`，`login_lock_time: 300`。

**调试登录算法时绝不能拿真实设备试错。**

### 做法
先从设备自己的 `js/util.js` 里提取 `SHA256` 函数，在 Node 里跑，
确认输出格式（**大写十六进制**），再离线验证完整算法，
最后才向设备发一次登录请求。

```
$ node -e "console.log(require('/tmp/sha256_fn.js')('abc'))"
BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD
                          ↑ 大写！和标准实现的常见小写输出不同
```

---

## 7. 菜单栏宽度抖动

### 症状
菜单栏项宽度随数字变化（`↓8.5K ↑4.4K` → `↓1.2M ↑340K`），看起来一直在动。

### 修复需要**两步**，缺一不可
1. **数值补齐到固定宽度**（5 字符右对齐）—— 否则 3 字符和 5 字符还是不一样宽
2. **使用等宽字体** `NSFont.monospacedSystemFont` —— 否则比例字体里
   空格宽度 ≠ 数字宽度，补了也白补

```swift
statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
```

---

## 8. `ping` 的 `-t` 是 TTL，不是超时

macOS 的 `ping -t <n>` 设置的是 **TTL**，不是超时时间（Linux 上才是超时）。

想要超时应该用 `-W <毫秒>`：

```bash
ping -c1 -W 1000 <host>     # 1 秒超时
ping -c1 -t1 <host>         # TTL=1（只够一跳，对网关够用，但语义完全不同）
```

本工具里 `ping` 只用来"戳一下网关填 ARP 表"，TTL=1 够用，但**别把 `-t` 当超时用**。

---

## 9. 汇总报告的表头被 `sort` 排到了中间

`awk` 先打印表头再打印数据，管道给 `sort` 之后表头会按字典序跑到数据中间。

### 修复
表头单独 `printf`，只把数据行送进 `sort`：

```bash
printf "  %-12s %12s\n" "日期" "下载"
awk -F, '...' "$CSV" | sort
```

---

## 10. 对账要比较「同一窗口的增量」，不是累计值

### 症状
本机计数 212 GB，路由器本月 1.3 GB，比值 16223% —— 毫无意义。

### 原因
- 路由器给的是**本计费周期**的累计
- 本机 `netstat` 给的是**开机以来所有网络**的累计

两个窗口完全不同，直接相除没有意义。

### 修复
以第一个采样点为基线，比较**同一时间窗口内两边各涨了多少**：

```awk
NR>1 { n++; if (n==1) { br=...; bl=... }   # 记基线
       dr = now_router - br; dl = now_local - bl }
```

修正后对账结果合理了（本机/路由 ≈ 100.7%），并顺带成为链路质量的免费指标
（Wi-Fi 重传会让本机计数偏高）。
