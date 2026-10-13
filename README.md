# f50-dashboard

macOS 菜单栏流量看板，专为**中兴 F50 Pro**（5G 随身 Wi-Fi）设计。

在菜单栏实时显示上下行速率，点开可看到**本机在 5G 路由器上的累计用量**、
**运营商计费口径的本月流量与套餐进度**，以及 5G 信号、接入设备等。

> **为什么需要它**：5G 随身 Wi-Fi 的套餐流量是有限的（常见 100 GB/月）。
> 系统自带的流量统计会把手机热点、家里 Wi-Fi、有线的用量**混在一起**，
> 无法判断"这个月 5G 卡还能用多少"。本工具按接入网络分别记账，
> 并直接读取路由器上报的**运营商计费数字**。

---

## 界面

菜单栏（宽度固定，不随数字抖动）：

```
↓ 1.2M ↑ 340K
```

点击展开：

```
实时速率      ↓ 1.2M/s    ↑ 340K/s
─────────────────────────────────────
当前网络      5G 路由器 F50 Pro
  本网络累计  ↓ 1.20 GB   ↑ 340.0 MB   合计 1.54 GB
  已接入      2 小时 15 分钟
─────────────────────────────────────
本月计费      1.79 GB / 100 GB   已用 1.79%
  剩余        98.21 GB
  下载/上传   1.37 GB / 421.2 MB
  [█░░░░░░░░░░░░░░░░░░░]
5G 信号       5G   5/5   -82 dBm
接入设备      1 台
      192.168.0.125   ca:e6:09:9d:05:22
WAN IP        10.134.166.50
─────────────────────────────────────
全部网络合计  ↓ 2.10 GB   ↑ 890.0 MB
      家里 Wi-Fi  ↓ 900.0 MB  ↑ 550.0 MB
  本机开机以来 ↓ 127.11 GB   ↑ 95.71 GB
─────────────────────────────────────
打开配置文件 / 打开数据目录 / 刷新 / 退出
```

**关键设计**：`本月计费` 一行**只在连着 F50 Pro 时显示真实数据**。
切到别的网络会明确显示「—（当前不在 5G 路由器上）」，绝不拿其他网络的数字冒充。

---

## 安装

**只需要 Xcode Command Line Tools**（`swiftc`），不需要 Apple 开发者账号，
不需要联网下载依赖。

```bash
git clone https://github.com/nowhere1975/f50-dashboard.git
cd f50-dashboard
./build.sh install
```

`build.sh` 会：

1. 用 `swiftc` 编译（只有一个二进制，248 KB）
2. 打包成 `F50Dashboard.app` 并做 ad-hoc 签名
3. 装到 `~/Applications/`
4. 注册开机自启（LaunchAgent，崩溃自动拉起）
5. 跑一次自检并把结果打出来

装完菜单栏右上角就会出现 `↓… ↑…`。

### 其他命令

```bash
./build.sh            # 只构建到 build/，不安装
./build.sh uninstall  # 移除 App 与开机自启（保留配置与历史数据）
./build.sh clean      # 清理构建产物
```

> **为什么自己编译而不是下载 .app**：未签名的 App 会被 Gatekeeper 拦下
> （"无法验证开发者"）。走 Apple 公证需要每年 $99 的开发者账号。
> 本地编译生成的 App 不受此限制，且你随时能审查和修改源码。

---

## 配置

首次运行会生成：

```
~/Library/Application Support/F50Dashboard/config.json
```

```json
{
  "quotaGB": 100,              // 套餐每月额度（GB，十进制）
  "routerGateway": "auto",     // "auto" = 用当前默认网关
  "interface": "auto",         // "auto" = 用默认路由所在网卡
  "localPollSec": 2,           // 本机速率刷新间隔
  "routerPollSec": 30,         // 路由器数据刷新间隔
  "showRateInTitle": true      // 关掉则菜单栏只显示累计
}
```

改完**下次打开菜单即生效**（无需重启）。菜单里有「打开配置文件」快捷入口。

> `quotaGB` 一定要按你自己的套餐填 —— 这是配额的唯一来源。

---

## 排查问题

内置诊断命令，会打印所有数据源的状态：

```bash
~/Applications/F50Dashboard.app/Contents/MacOS/F50Dashboard --check
```

输出示例：

```
── 配置 ──
  月配额      100 GB
  网关设置    auto   (实际使用 192.168.0.1)
── 系统命令 ──
  netstat   /usr/sbin/netstat  ✅
  route     /sbin/route  ✅
── 网络 ──
  网络标识    f50（专属统计桶）
  网关 MAC    未获取（预期行为，见 docs/PITFALLS.md）
── 接口计数 ──
  en0 速率   ↓ 1363 B/s   ↑ 1602 B/s
  标题预览    ↓ 1.4K ↑ 1.6K  (宽度固定)
── 路由器 ──
  状态        ✅ 可达
  型号/固件   F50ProV1.0.0B27  MU3356V1.0.0B27
  命中字段    flux_monthly_tx_bytes+flux_monthly_rx_bytes
  本月计费    1.79 GB / 100 GB   已用 1.79%
  原始字节    1790727216  (下载 1369485556 + 上传 421241660)
```

**提 issue 时请附上这段输出** —— 有了它就能立刻定位是配置、系统命令、
还是固件字段差异的问题。

---

## 配套脚本（可选）

`tools/` 下两个 bash 脚本，把数据落成 CSV 供长期分析：

| 脚本 | 作用 |
|---|---|
| `router-traffic.sh` | 从路由器 API 采集：本月流量、信号、接入设备。**只在连着 F50 Pro 时采集**，切网自动暂停、连回自动恢复 |
| `ssid-traffic.sh` | 按接入网络归集本机 en0 流量 |

```bash
tools/router-traffic.sh status   # 当前网络 + 路由器状态
tools/router-traffic.sh report   # 走势 / 与本机对账 / 网络切换事件
```

它们的网络判断同样基于「网关 + DNS」，不依赖 SSID。

---

## 兼容性

| 项目 | 状态 |
|---|---|
| 系统 | macOS 12+（在 macOS 27 上开发测试） |
| 芯片 | Apple Silicon 与 Intel 均可 |
| 设备 | 中兴 F50 Pro |
| 已验证固件 | `F50ProV1.0.0B27` / `MU3356V1.0.0B27` |
| 其他固件 | **未验证** —— 字段名可能不同 |

代码为每个指标准备了**多个候选字段名**逐个尝试，以提高跨固件兼容性。
若你的 F50 Pro 跑不通，请提 issue 附上 `--check` 输出。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | **F50 Pro 管理接口协议**（端点、命令、登录算法、字段表） |
| [docs/PITFALLS.md](docs/PITFALLS.md) | 开发中踩过的坑（含 macOS 系统怪癖） |
| [docs/REVIEW.md](docs/REVIEW.md) | 代码审查要点与已知待办 |

---

## 设计取舍

**为什么读路由器而不是只用本机计数**
本机计数只覆盖这一台电脑，且会跨网络累加。路由器报出的是运营商计费口径的数字，
是判断配额的唯一权威来源。

**为什么按「网关 + DNS」而不是 SSID 区分网络**
macOS 把 SSID 当作位置隐私信息，未授权时 `networkswitcher` / `system_profiler` /
CoreWLAN 全部返回空（详见 [docs/PITFALLS.md](docs/PITFALLS.md) 第 4 节）。
网关 + DNS 组合是免权限且稳定的替代。

**为什么不做登录**
F50 Pro 的读命令**不需要认证**，所以本工具不持有任何凭据、不涉及密码存储。
参见 [docs/PROTOCOL.md](docs/PROTOCOL.md) 第 3 节。

**为什么用十进制单位**
运营商按 10⁹ 计费。用 2³⁰ 会在 100 GB 配额上产生 7.4% 误差。

---

## 免责声明

- 本工具为**非官方第三方软件**，与中兴通讯（ZTE Corporation）无任何关联。
- 「中兴」「ZTE」「F50 Pro」为其各自权利人的商标，此处仅作兼容性说明之用。
- 本工具**只读取**路由器的公开状态接口，不修改任何设备配置，不绕过任何授权机制。
- 按"现状"提供，不提供任何担保。固件更新可能导致失效。

## 许可

[MIT](LICENSE)
