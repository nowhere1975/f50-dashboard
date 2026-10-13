# 代码审查指南

> 这份文档是给审查者（人或其他 AI）的。它说明**项目做了什么**、
> **哪些地方最需要被质疑**、以及**已知的问题**。
>
> 请优先审查「需要重点审查」一节列出的点 —— 那些是我自己不确定的地方。

---

## 1. 项目概览

**一句话**：macOS 菜单栏 App，显示本机实时网速，并按接入网络分别累计流量；
当接入的是中兴 F50 Pro 时，额外读取路由器上报的运营商计费流量与 5G 信号。

**代码规模**：Swift 约 900 行（6 个文件）+ bash 约 400 行（构建与采集脚本）。

**运行方式**：LaunchAgent 常驻，`LSUIElement`（只驻菜单栏，不显示 Dock 图标）。

**关键约束**：
- 只依赖 Xcode CLT 自带的 `swiftc`，**无第三方依赖**
- **不持有任何凭据**（路由器读接口无需认证）
- 一切外部命令路径都动态探测，不硬编码

---

## 2. 文件地图

```
Sources/F50Dashboard/
├── main.swift           入口；--check / --version / --help 诊断
├── Config.swift         配置读写（JSON，缺失键回落默认值）
├── SysInfo.swift        系统命令封装、接口计数、网关/DNS 探测
├── RouterClient.swift   路由器 API 客户端（多字段候选、类型兼容）
├── Fmt.swift            显示格式化（十进制单位、固定宽度速率）
└── AppDelegate.swift    菜单栏 UI、采样循环、按网络分桶、持久化

Resources/Info.plist     App 元信息（LSUIElement = 菜单栏专用）
build.sh                 构建 / 安装 / 卸载 / 清理
tools/*.sh               可选的 CSV 采集脚本
docs/                    协议、踩坑、本文档
```

---

## 3. 数据流

```
        ┌──────────────── 每 2 秒 ────────────────┐
        │ netstat -ib 读 en0 累计字节             │
        │ 差分 → 实时速率                         │
        │ 增量累加到 buckets[netKey]              │
        └────────────────────────────────────────┘
                          │
        ┌────────── 每 10 秒 ──────────┐
        │ 重算 netKey（网关 + DNS）    │
        │ 变了就换桶，速率清零         │
        └──────────────────────────────┘
                          │
        ┌────────── 每 30 秒 ──────────┐
        │ GET 路由器 API               │
        │ 更新本月计费 / 信号 / 设备   │
        └──────────────────────────────┘

持久化：~/Library/Application Support/F50Dashboard/state.json
        （只存各网络的累计字节，切换网络与退出时写盘）
```

---

## 4. ⚠️ 需要重点审查的地方

按我自己的不确定程度排序。

### 4.1 `state.json` 的并发写入 — 可能丢数据

`saveState()` 在 `checkNetwork()`（定时器回调）和 `applicationWillTerminate`
里都会被调用，是**非原子写**：

```swift
try? data.write(to: stateURL)      // 先截断再写，中途崩溃会留下半个文件
```

**请评估**：
- 是否需要 `Data.write(to:options:.atomic)`？
- 定时器回调与退出回调是否可能并发（都在主线程？请确认）？
- 读取端 `loadState()` 遇到损坏文件会静默返回空（`try?`），
  这会**丢失所有历史累计**且用户毫无察觉。是否应该提示或备份？

### 4.2 网络切换时的采样窗口错配 — 可能把流量记到错误的桶

`tick()` 每 2 秒读一次计数，`checkNetwork()` 每 10 秒才检查网络是否变了。

**这意味着网络切换后，最多有 10 秒的流量会被记到旧网络的桶里。**

**请评估**：
- 这个误差是否可以接受？（10 秒 @ 100 Mbps ≈ 125 MB，对 100 GB 配额是 0.125%，我判断可接受）
- 有没有更优雅的办法？例如把 `netKey` 的检查合并进 `tick()` 且用更轻量的判断？
- 但 `currentNetKey()` 会 fork 两个进程（`route` + `ipconfig`），
  放进 2 秒循环代价太大。这个取舍合理吗？

### 4.3 计数器的回绕与重置

```swift
if dt > 0, c.rx >= lastRx, c.tx >= lastTx {   // 变小就跳过这次
```

**请评估**：
- 若接口重置（拔插网线、切换 Wi-Fi），计数器归零，这里会跳过**一次**采样，
  下一次就正常了。这个处理够吗？
- 跳过的那一次增量会被永久丢失。是否应该把重置前的差值也算进去？
- `netstat` 的计数器是 64 位，实际不会回绕，但接口重置会归零。

### 4.4 `refreshRouter()` 的异步回调可能写到过期的桶

```swift
RouterClient.fetch(gateway: gw) { info in
    self.buckets[self.netKey, default: Bucket()].label = label   // ← netKey 可能已变
}
```

请求发出到回调之间有几百毫秒，期间用户可能换了网络。此时会**把 F50 的标签
写到新网络的桶上**。

**请评估**：
- 概率多大？影响是什么？（标签错误，不影响流量数字）
- 修复方式：在发起请求时捕获 `netKey` 快照，回调里比对后再写。这样对吗？

### 4.5 `onRouter` 的判定逻辑

```swift
private var onRouter: Bool {
    netKey == "f50" || (router.reachable && config.effectiveGateway() == SysInfo.defaultGateway())
}
```

第二个条件是"路由器可达 且 配置的网关就是当前默认网关"。

**请评估**：
- 如果用户在别的网络上，但那个网络上恰好也有个设备响应了
  `/goform/goform_get_cmd_process`（几乎不可能，但理论上），会误判吗？
- `RouterClient.parse` 里用 `txField.isEmpty && rxField.isEmpty && station_list == nil`
  来判断"不是 F50"，这个判据够严格吗？普通路由器的 404 页面能通过吗？

### 4.6 位置隐私相关的代码路径已经废弃但保留

`SysInfo.gatewayMAC()` 在 App 里**恒返回空**（原因见
[PITFALLS.md](PITFALLS.md) 第 2 节）。保留它是因为在 launchd 启动的上下文里
也许行为不同 —— 但**我没有证据**。

**请评估**：这是不是"僵尸代码"？是否应该删掉，让网络指纹逻辑更清晰？

### 4.7 `--check` 里的同步等待

```swift
let sem = DispatchSemaphore(value: 0)
RouterClient.fetch(gateway: ...) { info = $0; sem.signal() }
_ = sem.wait(timeout: .now() + 8)
```

**请评估**：
- 在 CLI 上下文里阻塞主线程是安全的（没有 run loop）。
- 但 `RouterClient.fetch` 内部会根据 `IS_CLI` 决定是否 dispatch 到主队列 ——
  这种"同一个函数两种调度行为"的设计是否容易出错？有没有更好的写法？

### 4.8 单位换算的一致性

十进制单位集中在 `Fmt.swift`（`kilo/mega/giga/tera`）。
但 `tools/*.sh` 里有**独立的**换算常量。

**请评估**：
- 是否有更好的方式保证两边一致？（跨语言共享常量比较麻烦）
- 建议在两处都加注释互相引用，还是有别的办法？

---

## 5. 已知问题 / 待办

| 优先级 | 问题 | 说明 |
|---|---|---|
| 中 | 单一固件验证 | 只在 `F50ProV1.0.0B27` 上测过。多字段候选是缓解措施，但未经真实样本验证 |
| 中 | 网络指纹可能冲突 | 若另一个路由器也是 `192.168.0.1` 且 DNS 指向自己，会与 F50 合并统计 |
| 中 | 未做代码签名/公证 | 用户需自行编译。若要走分发需 Apple 开发者账号 |
| 低 | 没有单元测试 | `RouterClient.parse` 和 `Fmt` 是纯函数，非常适合加测试 |
| 低 | 没有图标 | 菜单栏目前是纯文字 |
| 低 | 未本地化 | 界面为中文硬编码 |
| 低 | 无 iPad/多机同步 | 不在范围内 |

---

## 6. 如何验证

```bash
# 编译（应无警告）
./build.sh build

# 诊断：打印所有数据源状态
build/F50Dashboard.app/Contents/MacOS/F50Dashboard --check
```

**期望输出**（在连着 F50 Pro 的机器上）：

```
── 系统命令 ──
  netstat   /usr/sbin/netstat  ✅
  route     /sbin/route  ✅
── 网络 ──
  网络标识    f50（专属统计桶）
── 接口计数 ──
  计数器      ✅
  标题预览    ↓ 1.4K ↑ 1.6K  (宽度固定)
── 路由器 ──
  状态        ✅ 可达
  命中字段    flux_monthly_tx_bytes+flux_monthly_rx_bytes
```

**注意**：`--check` 是**只读**的，可以安全反复运行。
唯一的副作用是它会让路由器做一次 `ping`（为了填 ARP 表）。

---

## 7. 审查时请特别留意

1. **任何可能导致静默失败的地方** —— 这个项目最初的两个 bug
   （`netstat` 路径错、单位错）都是**静默**的，用户只看到"数字是 0"或"数字不对"。
   `try?` 和 `catch { return "" }` 用得比较多，请判断哪些地方应该改为显式报错。

2. **是否有任何凭据泄漏风险** —— 项目宣称不持有凭据。
   请确认没有硬编码密码、没有把用户输入写进日志、没有把敏感数据上传。

3. **权限声明是否与实际行为一致** —— `Info.plist` 里没有位置/网络权限声明，
   代码也不读 SSID。请确认没有未声明的权限使用。

4. **单位与量纲的一致性** —— 十进制/二进制混用是这个项目最大的历史教训，
   请检查是否有遗漏。

---

## 8. 背景材料

- [docs/PROTOCOL.md](PROTOCOL.md) —— 路由器接口协议（含登录算法，本工具未使用）
- [docs/PITFALLS.md](PITFALLS.md) —— 10 个已定位的坑，含两个系统级怪癖

**两个最值得看的坑**：

1. **`netstat` 在 `/usr/sbin` 而非 `/usr/bin`** —— 硬编码路径导致静默失败
2. **从 Swift 进程调用 `arp` 恒返回空** —— 试了 6 种调用方式均无效，
   而 `netstat`/`route`/`ipconfig`/`ndp` 全部正常。**根因未知**，
   如果你知道原因请告诉我。
