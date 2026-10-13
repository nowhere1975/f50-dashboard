import Cocoa

let appVersion = "0.2.1"

func printCheck() -> Bool {
    let loaded = Config.read()
    let config = loaded.config
    print("── F50 Dashboard \(appVersion) ──")
    print("  配置文件    \(Config.fileURL.path)")
    if let warning = loaded.warning { print("  提示        \(warning)") }
    print("  套餐额度    \(Fmt.trim(config.quotaGB)) GB（用于估算）")
    let context = SysInfo.networkContext(interface: config.interface)
    print("── 网络（原生系统接口）──")
    print("  当前网卡    \(context.interface.isEmpty ? "无" : context.interface)")
    print("  网关 / DNS  \(context.gateway) / \(context.dns)")
    print("  网关 MAC    \(context.gatewayMAC.isEmpty ? "未获取，使用网关与 DNS 兜底" : context.gatewayMAC)")
    print("  网络标识    \(context.key)")
    let a = SysInfo.ifaceCounters(context.interface)
    Thread.sleep(forTimeInterval: 1)
    let b = SysInfo.ifaceCounters(context.interface)
    var localOK = false
    if let a = a, let b = b, b.rx >= a.rx, b.tx >= a.tx {
        print("  网卡累计    ↓ \(Fmt.bytes(b.rx))   ↑ \(Fmt.bytes(b.tx))")
        print("  一秒速率    ↓ \(Fmt.rate(Double(b.rx - a.rx)))   ↑ \(Fmt.rate(Double(b.tx - a.tx)))")
        localOK = true
    } else { print("  网卡计数    读取失败或计数重置") }
    print("── 路由器（只读）──")
    guard context.hasIPv4Gateway else { print("  状态        当前无 IPv4 网关"); return false }
    let gateway = config.routerGateway == "auto" ? context.gateway : config.routerGateway
    let sem = DispatchSemaphore(value: 0)
    var response = RouterInfo()
    let task = RouterClient.fetch(gateway: gateway) { response = $0; sem.signal() }
    guard sem.wait(timeout: .now() + 8) == .success else {
        task?.cancel(); print("  状态        请求超时"); return false
    }
    print("  型号 / 固件 \(response.model) / \(response.firmware)")
    if let error = response.errorMessage { print("  提示        \(error)") }
    if response.isF50, let total = response.monthlyTotal {
        let percent = Double(total) / Fmt.giga / config.quotaGB * 100
        print("  命中字段    \(response.usedFields)")
        if loaded.warning == nil {
            print("  本周期用量  \(Fmt.bytes(total)) / \(Fmt.trim(config.quotaGB)) GB · \(String(format: "%.2f", percent))%")
        } else { print("  本周期用量  \(Fmt.bytes(total))（配置未加载，暂不估算余量）") }
        print("  原始字节    \(total)（下载 \(response.monthlyRx!) + 上传 \(response.monthlyTx!)）")
        print("  移动网络    \(response.netType) · \(response.sigBar)/5 · \(response.rsrp) dBm")
        print("  接入设备    \(response.stations.count) 台")
        print("  说明        套餐余量以运营商查询结果为准")
        return localOK && loaded.warning == nil
    }
    return false
}

let args = CommandLine.arguments
if args.contains("--version") { print("f50-dashboard \(appVersion)"); exit(0) }
if args.contains("--help") || args.contains("-h") {
    print("""
    f50-dashboard —— F50 Pro 菜单栏流量看板

      F50Dashboard              启动菜单栏看板
      F50Dashboard --check      诊断本机采样与路由器接口（失败返回非零）
      F50Dashboard --version    显示版本

    配置与数据：~/Library/Application Support/F50Dashboard/
    """)
    exit(0)
}
if args.contains("--check") { exit(printCheck() ? 0 : 1) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
