import Cocoa

// ============================================================
//  f50-dashboard —— 菜单栏流量看板（macOS）
//
//  用法：
//      F50Dashboard            # 启动菜单栏看板
//      F50Dashboard --check    # 打印诊断信息后退出（排查问题用）
//      F50Dashboard --version
// ============================================================

func printCheck() {
    let cfg = Config.load()
    let iface = cfg.effectiveInterface

    print("── 配置 ──")
    print("  配置文件    \(Config.fileURL.path)")
    print("  月配额      \(Fmt.trim(cfg.quotaGB)) GB")
    print("  网关设置    \(cfg.routerGateway)   (实际使用 \(cfg.effectiveGateway()))")
    print("  网卡设置    \(cfg.interface)   (实际使用 \(iface))")
    print("")

    print("── 系统命令 ──")
    for (name, path) in [("netstat", SysInfo.netstat), ("route", SysInfo.route),
                         ("arp", SysInfo.arp), ("ping", SysInfo.ping),
                         ("ipconfig", SysInfo.ipconfig)] {
        let ok = FileManager.default.isExecutableFile(atPath: path)
        print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0))\(path)  \(ok ? "✅" : "❌")")
    }
    print("")

    print("── 网络 ──")
    let gw = SysInfo.defaultGateway()
    print("  默认网关    \(gw.isEmpty ? "无" : gw)")
    print("  首选 DNS    \(SysInfo.primaryDNS(iface).isEmpty ? "无" : SysInfo.primaryDNS(iface))")
    let mac = SysInfo.gatewayMAC(gw)
    print("  网关 MAC    \(mac.isEmpty ? "未获取（预期行为，见 docs/PITFALLS.md）" : mac)")
    print("  网络标识    \(Fmt.isRouterSignature(gw: gw, iface: iface) ? "f50（专属统计桶）" : "gw:\(gw)")")
    print("")

    print("── 接口计数 ──")
    let a = SysInfo.ifaceCounters(iface)
    Thread.sleep(forTimeInterval: 3)
    let b = SysInfo.ifaceCounters(iface)
    print("  \(iface) 累计   ↓ \(Fmt.bytes(a.rx))   ↑ \(Fmt.bytes(a.tx))")
    print(String(format: "  %@ 速率   ↓ %.0f B/s   ↑ %.0f B/s", iface,
                 Double(b.rx - a.rx) / 3.0, Double(b.tx - a.tx) / 3.0))
    print("  标题预览    ↓\(Fmt.rate(Double(b.rx - a.rx) / 3.0)) ↑\(Fmt.rate(Double(b.tx - a.tx) / 3.0))  (宽度固定)")
    print("  计数器      \(b.rx > 0 ? "✅" : "❌ 读数为 0")")
    print("")

    print("── 路由器 ──")
    let sem = DispatchSemaphore(value: 0)
    var info = RouterInfo()
    RouterClient.fetch(gateway: cfg.effectiveGateway()) { info = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 8)

    if info.reachable {
        let usedGB = Double(info.monthlyTotal) / Fmt.giga
        let pct = usedGB / max(0.01, cfg.quotaGB) * 100
        print("  状态        ✅ 可达")
        print("  型号/固件   \(info.model.isEmpty ? "?" : info.model)  \(info.firmware)")
        print("  命中字段    \(info.usedFields)")
        print("  本月计费    \(Fmt.bytes(info.monthlyTotal)) / \(Fmt.trim(cfg.quotaGB)) GB   已用 \(String(format: "%.2f", pct))%")
        print("  原始字节    \(info.monthlyTotal)  (下载 \(info.monthlyRx) + 上传 \(info.monthlyTx))，十进制 GB = 字节/1e9")
        print("  网络/信号   \(info.netType)  \(info.sigBar)/5  \(info.rsrp) dBm")
        print("  接入设备    \(info.stations.count) 台")
        for s in info.stations { print("      \(s.ip)   \(s.mac)") }
        print("  WAN IP      \(info.wanIP)")
    } else {
        print("  状态        ❌ 不可达（不在 F50 Pro 网络上，或固件字段不同）")
    }
}

// ---- 入口 ----
let args = CommandLine.arguments

if args.contains("--version") {
    print("f50-dashboard 0.1.0")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    f50-dashboard —— 中兴 F50 Pro 菜单栏流量看板

      F50Dashboard              启动菜单栏看板
      F50Dashboard --check      打印诊断信息后退出
      F50Dashboard --version    显示版本
      F50Dashboard --help       显示帮助

    配置文件：~/Library/Application Support/F50Dashboard/config.json
    项目主页：https://github.com/nowhere1975/f50-dashboard
    """)
    exit(0)
}
if args.contains("--check") {
    printCheck()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)      // 只出现在菜单栏，不进 Dock
app.run()
