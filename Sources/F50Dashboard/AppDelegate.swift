import Cocoa

/// 单个「接入网络」的累计量。
/// 按网络分开记账是核心需求：5G 路由器有月度配额，
/// 不能和手机热点 / 家里 Wi-Fi / 有线的流量混在一起。
struct Bucket: Codable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var firstSeen: Date = Date()
    var label: String = ""
}

struct PersistedState: Codable {
    var buckets: [String: Bucket] = [:]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - 组件

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var localTimer: Timer?
    private var netTimer: Timer?
    private var routerTimer: Timer?

    // MARK: - 状态

    private var config = Config.load()
    private var router = RouterInfo()
    private var buckets: [String: Bucket] = [:]
    private var netKey = "none"

    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastSample = Date()
    private var rateRx: Double = 0
    private var rateTx: Double = 0

    private var iface: String { config.effectiveInterface }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 等宽字体：标题里补的空格才有固定宽度，菜单栏项不会随数字抖动
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusItem.button?.title = "↓  --- ↑  ---"
        menu.delegate = self
        statusItem.menu = menu

        loadState()
        netKey = currentNetKey()
        touchBucket(netKey)

        let c = SysInfo.ifaceCounters(iface)
        lastRx = c.rx; lastTx = c.tx; lastSample = Date()

        localTimer = schedule(config.localPollSec) { [weak self] in self?.tick() }
        netTimer   = schedule(10)                  { [weak self] in self?.checkNetwork() }
        routerTimer = schedule(config.routerPollSec) { [weak self] in self?.refreshRouter() }

        refreshRouter()
        tick()
    }

    func applicationWillTerminate(_ note: Notification) { saveState() }

    private func schedule(_ sec: Double, _ body: @escaping () -> Void) -> Timer {
        let t = Timer.scheduledTimer(withTimeInterval: sec, repeats: true) { _ in body() }
        RunLoop.current.add(t, forMode: .common)
        return t
    }

    // MARK: - 采样

    /// 每 `localPollSec` 秒：算实时速率，并把这期间的增量记到「当前网络」的桶里。
    private func tick() {
        let c = SysInfo.ifaceCounters(iface)
        let now = Date()
        let dt = now.timeIntervalSince(lastSample)

        // 计数器单调递增；若变小说明接口重置或换网卡，跳过这次避免负数
        if dt > 0, c.rx >= lastRx, c.tx >= lastTx {
            let dRx = c.rx - lastRx
            let dTx = c.tx - lastTx
            rateRx = Double(dRx) / dt
            rateTx = Double(dTx) / dt
            buckets[netKey, default: Bucket()].rx += dRx
            buckets[netKey, default: Bucket()].tx += dTx
        }
        lastRx = c.rx; lastTx = c.tx; lastSample = now
        updateTitle()
    }

    private func updateTitle() {
        if config.showRateInTitle {
            statusItem.button?.title = "↓\(Fmt.rate(rateRx)) ↑\(Fmt.rate(rateTx))"
        } else {
            statusItem.button?.title = "↓\(Fmt.bytes(buckets[netKey]?.rx ?? 0))"
        }
    }

    /// 每 10 秒：网络是否换了。换了就换桶，并把速率清零（避免跨网络算出一个假速率）。
    private func checkNetwork() {
        let k = currentNetKey()
        guard k != netKey else { return }
        saveState()
        netKey = k
        touchBucket(k)
        rateRx = 0; rateTx = 0
    }

    private func touchBucket(_ key: String) {
        if buckets[key] == nil { buckets[key] = Bucket(firstSeen: Date()) }
    }

    private func refreshRouter() {
        let gw = config.effectiveGateway()
        RouterClient.fetch(gateway: gw) { [weak self] info in
            guard let self = self else { return }
            self.router = info
            if info.reachable {
                // 用路由器自报的型号给桶打标签，比裸 MAC/IP 好认
                let label = info.model.isEmpty ? "F50 Pro" : "F50 Pro (\(info.model))"
                self.buckets[self.netKey, default: Bucket()].label = label
            }
            if !Thread.isMainThread { DispatchQueue.main.async { self.rebuildIfOpen() } }
        }
    }

    // MARK: - 网络指纹

    /// 当前网络的稳定标识。
    ///
    /// 用「默认网关 + DNS」组合，而不是 SSID（macOS 位置隐私会拦住）也不是网关 MAC
    /// （App 进程里 `arp` 恒返回空，见 docs/PITFALLS.md）。
    /// 若网关正好是 F50 Pro 的出厂地址且 DNS 指向自己，直接标记为独立的 "f50" 桶。
    private func currentNetKey() -> String {
        let gw = SysInfo.defaultGateway()
        if gw.isEmpty { return "none" }
        if Fmt.isRouterSignature(gw: gw, iface: iface) { return "f50" }
        let mac = SysInfo.gatewayMAC(gw)
        if !mac.isEmpty { return "mac:\(mac)" }
        let dns = SysInfo.primaryDNS(iface)
        return dns.isEmpty ? "gw:\(gw)" : "gw:\(gw)|dns:\(dns)"
    }

    private var onRouter: Bool { netKey == "f50" || (router.reachable && config.effectiveGateway() == SysInfo.defaultGateway()) }

    // MARK: - 菜单

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        config = Config.load()          // 允许用户改完配置直接生效
        tick()
        rebuild()
        refreshRouter()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private var menuOpen = false

    /// 路由器数据是异步回来的：只在菜单展开时才重建，避免无谓的开销。
    private func rebuildIfOpen() { if menuOpen { rebuild() } }

    private func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = action == nil ? nil : self
        if action == nil { it.isEnabled = false }
        return it
    }

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(item("实时速率      ↓ \(Fmt.bytes(UInt64(max(0, rateRx))))/s    ↑ \(Fmt.bytes(UInt64(max(0, rateTx))))/s"))
        menu.addItem(.separator())

        // ---- 当前网络 ----
        let b = buckets[netKey] ?? Bucket()
        let name = !b.label.isEmpty ? b.label : (onRouter ? "5G 路由器 F50 Pro" : netKey)
        menu.addItem(item("当前网络      \(name)"))
        menu.addItem(item("  本网络累计  ↓ \(Fmt.bytes(b.rx))   ↑ \(Fmt.bytes(b.tx))   合计 \(Fmt.bytes(b.rx + b.tx))"))
        menu.addItem(item("  已接入      \(Fmt.duration(since: b.firstSeen))"))
        menu.addItem(.separator())

        // ---- 5G 路由器专属 ----
        if onRouter, router.reachable {
            let usedGB = Double(router.monthlyTotal) / Fmt.giga
            let pct = usedGB / max(0.01, config.quotaGB) * 100
            menu.addItem(item("本月计费      \(Fmt.bytes(router.monthlyTotal)) / \(Fmt.trim(config.quotaGB)) GB   已用 \(String(format: "%.2f", pct))%"))
            menu.addItem(item("  剩余        \(String(format: "%.2f", max(0, config.quotaGB - usedGB))) GB"))
            menu.addItem(item("  下载/上传   \(Fmt.bytes(router.monthlyRx)) / \(Fmt.bytes(router.monthlyTx))"))
            menu.addItem(item("  \(Fmt.bar(pct))"))
            menu.addItem(.separator())
            var sig = "5G 信号       \(router.netType.isEmpty ? "?" : router.netType)"
            if !router.sigBar.isEmpty { sig += "   \(router.sigBar)/5" }
            if !router.rsrp.isEmpty { sig += "   \(router.rsrp) dBm" }
            menu.addItem(item(sig))
            menu.addItem(item("接入设备      \(router.stations.count) 台"))
            for s in router.stations.prefix(8) {
                menu.addItem(item("      \(s.ip)   \(s.mac)"))
            }
            if !router.wanIP.isEmpty { menu.addItem(item("WAN IP        \(router.wanIP)")) }
        } else if onRouter {
            menu.addItem(item("本月计费      读取中…"))
        } else {
            menu.addItem(item("本月计费      —（当前不在 5G 路由器上）"))
            if !router.reachable {
                menu.addItem(item("  （\(config.effectiveGateway()) 未响应 F50 接口）"))
            }
        }
        menu.addItem(.separator())

        // ---- 全部网络，明确标注避免误读 ----
        var allRx: UInt64 = 0, allTx: UInt64 = 0
        for (_, v) in buckets { allRx += v.rx; allTx += v.tx }
        menu.addItem(item("全部网络合计  ↓ \(Fmt.bytes(allRx))   ↑ \(Fmt.bytes(allTx))"))
        if buckets.count > 1 {
            for (k, v) in buckets.sorted(by: { ($0.value.rx + $0.value.tx) > ($1.value.rx + $1.value.tx) }) where k != netKey {
                let n = v.label.isEmpty ? k : v.label
                menu.addItem(item("      \(n)  ↓ \(Fmt.bytes(v.rx))  ↑ \(Fmt.bytes(v.tx))"))
            }
        }
        menu.addItem(item("  本机开机以来 ↓ \(Fmt.bytes(lastRx))   ↑ \(Fmt.bytes(lastTx))"))
        menu.addItem(.separator())

        menu.addItem(item("打开配置文件", #selector(openConfig)))
        menu.addItem(item("打开数据目录", #selector(openData)))
        menu.addItem(item("刷新", #selector(doRefresh)))
        menu.addItem(item("退出", #selector(quit)))
    }

    // MARK: - 持久化

    private var stateURL: URL { Config.supportDir.appendingPathComponent("state.json") }

    private func saveState() {
        try? FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(PersistedState(buckets: buckets)) {
            try? data.write(to: stateURL)
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let st = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        buckets = st.buckets
    }

    // MARK: - 动作

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) { config.save() }
        NSWorkspace.shared.open(Config.fileURL)
    }
    @objc private func openData() {
        NSWorkspace.shared.open(Config.supportDir)
    }
    @objc private func doRefresh() { refreshRouter(); tick() }
    @objc private func quit() { saveState(); NSApp.terminate(nil) }
}
