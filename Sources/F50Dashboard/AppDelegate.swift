import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var localTimer: Timer?
    private var routerTimer: Timer?
    private var saveTimer: Timer?
    private var config = Config()
    private var tracker = TrafficTracker()
    private var router = RouterState()
    private let store = StateStore()
    private let networkObserver = NetworkObserver()
    private var routerTask: URLSessionDataTask?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var instanceFD: Int32 = -1
    private var menuOpen = false
    private var configWarning: String?
    private var stateWarning: String?
    private var saveWarning: String?
    private var notificationWarning: String?
    private var billingWarning: String?
    private var notificationsAllowed = false
    private var lastSavedAt: Date?
    private var settingsController: SettingsController?
    private let samplingQueue = DispatchQueue(label: "io.github.nowhere1975.f50dashboard.sampling")
    private var samplePending = false
    private var sampleGeneration: UInt64 = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            try FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
            instanceFD = open(Config.supportDir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard instanceFD >= 0, flock(instanceFD, LOCK_EX | LOCK_NB) == 0 else {
                if instanceFD >= 0 { close(instanceFD) }
                instanceFD = -1
                NSApp.terminate(nil); return
            }
        } catch { NSApp.terminate(nil); return }
        let loaded = Config.read()
        config = loaded.config; configWarning = loaded.warning
        let state = store.load()
        tracker.state = state.state; stateWarning = state.warning
        mergeLegacyF50IfPossible()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusItem.button?.title = "↓  --- ↑  ---"
        statusItem.button?.toolTip = "F50 Dashboard \(appVersion)"
        menu.delegate = self
        statusItem.menu = menu
        networkObserver.onChange = { [weak self] in self?.networkChanged() }
        networkObserver.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sampleGeneration &+= 1
                self?.tracker.resetBaseline()
                self?.invalidateRouter()
                if name == NSWorkspace.didWakeNotification { self?.tick(); self?.refreshRouter() }
                else { self?.saveState() }
            })
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationPermission()
        rebuildTimers()
        tick()
        refreshRouter()
        saveState()
    }

    func applicationWillTerminate(_ note: Notification) {
        routerTask?.cancel()
        if instanceFD >= 0 {
            saveState()
            flock(instanceFD, LOCK_UN)
            close(instanceFD)
        }
    }

    private func schedule(_ sec: Double, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: sec, repeats: true) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func rebuildTimers() {
        localTimer?.invalidate(); routerTimer?.invalidate(); saveTimer?.invalidate()
        localTimer = schedule(config.localPollSec) { [weak self] in self?.tick() }
        routerTimer = schedule(config.routerPollSec) { [weak self] in self?.refreshRouter() }
        saveTimer = schedule(30) { [weak self] in self?.saveState() }
    }

    private func tick() {
        let context = SysInfo.networkContext(interface: config.interface)
        let changed = tracker.context != context
        if changed {
            saveState(); invalidateRouter()
            sampleGeneration &+= 1
            tracker.sample(context: context, counters: nil, uptime: ProcessInfo.processInfo.systemUptime,
                           date: Date(), maxGap: max(30, config.localPollSec * 3))
            updateTitle(); rebuildIfOpen(); refreshRouter()
        }
        guard !samplePending else { return }
        samplePending = true
        let generation = sampleGeneration
        samplingQueue.async { [weak self] in
            let counters = SysInfo.ifaceCounters(context.interface)
            let uptime = ProcessInfo.processInfo.systemUptime
            let date = Date()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.samplePending = false
                guard generation == self.sampleGeneration,
                      SysInfo.networkContext(interface: self.config.interface) == context else {
                    self.tick(); return
                }
                self.tracker.sample(context: context, counters: counters, uptime: uptime, date: date,
                                    maxGap: max(30, self.config.localPollSec * 3))
                self.updateTitle()
                self.rebuildIfOpen()
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        if tracker.counters == nil { button.title = "↓  --- ↑  ---" }
        else if config.showRateInTitle { button.title = "↓\(Fmt.rate(tracker.rateRx)) ↑\(Fmt.rate(tracker.rateTx))" }
        else { button.title = "↓\(Fmt.bytes(tracker.state.buckets[tracker.context?.key ?? ""]?.rx ?? 0))" }
    }

    private func invalidateRouter() {
        routerTask?.cancel(); routerTask = nil
        router.invalidate()
    }

    private func networkChanged() {
        // 系统通知可能早于下一次速率采样，先作废请求和基线。
        invalidateRouter()
        sampleGeneration &+= 1
        tracker.resetBaseline()
        tick()
        refreshRouter()
    }

    private func refreshRouter(force: Bool = false) {
        guard let context = tracker.context else { return }
        guard context.hasIPv4Gateway else { invalidateRouter(); rebuildIfOpen(); return }
        if force { routerTask?.cancel() }
        else if router.pending != nil { return }
        let gateway = config.routerGateway == "auto" ? context.gateway : config.routerGateway
        let request = router.begin(network: context, gateway: gateway)
        routerTask = RouterClient.fetch(gateway: gateway) { [weak self] info in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let actual = SysInfo.networkContext(interface: self.config.interface)
                guard actual == self.tracker.context else { self.networkChanged(); return }
                guard self.router.accept(info, request: request, current: self.tracker.context, date: Date()) else { return }
                self.routerTask = nil
                if info.isF50 {
                    self.tracker.setLabel("F50 Pro", for: request.network.key)
                    self.mergeLegacyF50IfPossible()
                    if self.configWarning == nil {
                        do {
                            try self.tracker.sampleBilling(info, key: request.network.key, config: self.config, date: Date())
                            self.billingWarning = nil
                            self.checkQuotaAlert(key: request.network.key)
                        } catch { self.billingWarning = error.localizedDescription }
                    }
                }
                self.rebuildIfOpen()
            }
        }
    }

    private func applyConfig(_ next: Config) {
        let old = config
        config = next; configWarning = nil
        if old.interface != next.interface || old.routerGateway != next.routerGateway {
            sampleGeneration &+= 1
            invalidateRouter()
            tracker.resetBaseline()
        }
        if old.localPollSec != next.localPollSec || old.routerPollSec != next.routerPollSec { rebuildTimers() }
        if old.enableQuotaAlerts != next.enableQuotaAlerts { refreshNotificationPermission() }
        tick()
        refreshRouter(force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        let loaded = Config.read(fallback: config)
        if loaded.config != config { applyConfig(loaded.config) }
        configWarning = loaded.warning
        tick()
        rebuild()
        refreshRouter()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }
    private func rebuildIfOpen() { if menuOpen { rebuild() } }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
        value.target = action == nil ? nil : self
        value.isEnabled = action != nil
        return value
    }
    private func add(_ title: String) { menu.addItem(item(title)) }

    private func name(for key: String) -> String {
        if let custom = config.networkNames[key], !custom.isEmpty { return custom }
        if key == "f50" { return "F50 Pro" }
        if let label = tracker.state.buckets[key]?.label, !label.isEmpty { return label }
        if let context = tracker.context, context.key == key {
            return context.gateway.isEmpty ? "未连接 IPv4 网络（\(context.interface)）" : "\(context.interface) · \(context.gateway)"
        }
        return key
    }

    private func mergeLegacyF50IfPossible() {
        guard let key = tracker.legacyF50Destination() else { return }
        do {
            _ = try store.archiveBeforeF50Merge(tracker.state)
            guard try tracker.mergeLegacyF50() else { return }
            // 保留用户给旧记录设置的名称；已设置的目标名称优先。
            if config.networkNames[key] == nil, let alias = config.networkNames["f50"] {
                config.networkNames[key] = alias
                do { try config.save() }
                catch { configWarning = "网络名称保存失败：\(error.localizedDescription)" }
            }
            saveState()
        } catch { stateWarning = "累计合并未完成：\(error.localizedDescription)" }
    }

    private func rebuild() {
        menu.removeAllItems()
        add("实时速率      ↓ \(Fmt.bytes(UInt64(max(0, tracker.rateRx))))/s    ↑ \(Fmt.bytes(UInt64(max(0, tracker.rateTx))))/s")
        if tracker.counters == nil { add("  本机计数读取失败，等待下一次采样") }
        menu.addItem(.separator())
        if let context = tracker.context {
            let bucket = tracker.state.buckets[context.key] ?? Bucket()
            add("当前网络      \(name(for: context.key))")
            add("  本网络累计  ↓ \(Fmt.bytes(bucket.rx))   ↑ \(Fmt.bytes(bucket.tx))")
            add("  本次连接    \(Fmt.duration(since: tracker.connectedSince))")
            add("  开始统计    \(DateFormatter.localizedString(from: bucket.firstSeen, dateStyle: .short, timeStyle: .short))")
            if context.gatewayMAC.isEmpty { add("  网络按网卡、网关与 DNS 区分；相同配置可能合并") }
        }
        menu.addItem(.separator())
        if let info = router.info, info.isF50 {
            if let total = info.monthlyTotal {
                add("路由器流量统计  \(Fmt.bytes(total))")
                add("  下载/上传   \(Fmt.bytes(info.monthlyRx!)) / \(Fmt.bytes(info.monthlyTx!))")
                add("  只统计经过路由器的数据")
                addBillingUsage()
            } else { add("路由器流量统计  暂未取得有效读数") }
            if let date = router.updatedAt {
                let age = Int(max(0, Date().timeIntervalSince(date)))
                add("  更新于      \(DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium))（\(age) 秒前）")
            }
            var signal = "移动网络      \(info.netType.isEmpty ? "未知" : info.netType)"
            if !info.sigBar.isEmpty { signal += " · \(info.sigBar)/5" }
            if !info.rsrp.isEmpty { signal += " · \(info.rsrp) dBm" }
            add(signal)
            add("接入设备      \(info.stations.count) 台")
            for station in info.stations.prefix(8) { add("  \(station.ip)   \(station.mac)") }
            if !info.wanIP.isEmpty { add("WAN IP        \(info.wanIP)") }
        } else if router.pending != nil { add("路由器用量    正在读取…") }
        else if let error = router.errorMessage { add("路由器用量    暂不可用"); add("  \(error)") }
        else { add("路由器用量    当前无可用的 F50 数据") }
        menu.addItem(.separator())
        let history = NSMenuItem(title: "近七天本机用量", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if let key = tracker.context?.key {
            for offset in 0..<7 {
                let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                let day = TrafficTracker.dayKey(date)
                let usage = tracker.state.daily[day]?[key]
                submenu.addItem(item("\(day)    \(usage.map { Fmt.bytes($0.total) } ?? "—（未记录）")"))
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(item("仅统计本网络在 App 运行期间的用量"))
        history.submenu = submenu
        menu.addItem(history)
        var all = Usage()
        for bucket in tracker.state.buckets.values { all.rx += bucket.rx; all.tx += bucket.tx }
        add("全部网络累计  ↓ \(Fmt.bytes(all.rx))   ↑ \(Fmt.bytes(all.tx))")
        for (key, bucket) in tracker.state.buckets.sorted(by: { $0.value.firstSeen > $1.value.firstSeen })
            where key != tracker.context?.key {
            add("  \(name(for: key))  ↓ \(Fmt.bytes(bucket.rx))  ↑ \(Fmt.bytes(bucket.tx))")
        }
        if let counters = tracker.counters { add("当前网卡累计  ↓ \(Fmt.bytes(counters.rx))  ↑ \(Fmt.bytes(counters.tx))") }
        for warning in [configWarning, stateWarning, saveWarning, notificationWarning, billingWarning].compactMap({ $0 }) {
            add("提示：\(warning)")
        }
        menu.addItem(.separator())
        menu.addItem(item("设置…", action: #selector(openSettings)))
        menu.addItem(item("打开配置文件", action: #selector(openConfig)))
        menu.addItem(item("打开数据目录", action: #selector(openData)))
        menu.addItem(item("刷新", action: #selector(doRefresh)))
        menu.addItem(item("退出", action: #selector(quit)))
    }

    private func addBillingUsage() {
        guard configWarning == nil else { add("套餐月度用量  配置未加载，暂不估算余量"); return }
        guard let day = config.billingCycleDay else {
            add("SIM 卡套餐    \(Fmt.trim(config.quotaGB)) GB（手动设置）")
            add("  请在设置中填写重置日和运营商本周期已用量")
            return
        }
        let period = BillingPeriod.containing(Date(), resetDay: day, timeZoneID: config.billingTimeZone)
        add("SIM 卡月度用量（估算）")
        add("  套餐额度    \(Fmt.trim(config.quotaGB)) GB（手动设置）")
        add("  套餐周期    \(period.label)")
        guard let key = tracker.context?.key,
              let usage = tracker.billingUsage(key: key, config: config, date: Date()) else {
            add("  月度已记录  尚未取得有效采样")
            return
        }
        if usage.canEstimateQuota {
            let used = Double(usage.total) / Fmt.giga
            let percent = used / config.quotaGB * 100
            add("  已用估算    \(Fmt.bytes(usage.total)) / \(Fmt.trim(config.quotaGB)) GB · \(String(format: "%.2f", percent))%")
            add("  估算剩余    \(String(format: "%.2f", max(0, config.quotaGB - used))) GB")
            add("  \(Fmt.bar(percent))")
            add("  套餐余量以运营商查询结果为准")
        } else {
            add("  月度已记录  \(Fmt.bytes(usage.total)) · \(Fmt.trim(config.quotaGB)) GB 套餐")
            add(usage.calibratedAt == nil ? "  周期初始用量未知，请用运营商已用量校准"
                : "  断采或设备清零可能漏记，请用运营商已用量校准")
        }
        if config.enableQuotaAlerts && !usage.canEstimateQuota { add("  月度配额提醒等待用量校准") }
    }

    private func saveState() {
        guard instanceFD >= 0 else { return }
        if tracker.dirty || lastSavedAt == nil {
            do {
                try store.save(tracker.state)
                tracker.didSave()
                lastSavedAt = Date()
                saveWarning = nil
            } catch { saveWarning = "累计保存失败：\(error.localizedDescription)" }
        }
        // 本地运行快照用于排查；不向外发送。
        var status: [String: Any] = [
            "version": appVersion, "pid": ProcessInfo.processInfo.processIdentifier,
            "updatedAt": Date().timeIntervalSince1970,
            "networkKey": tracker.context?.key ?? "", "interface": tracker.context?.interface ?? "",
            "localPollSec": config.localPollSec, "routerPollSec": config.routerPollSec,
            "routerModel": router.info?.model ?? "",
            "routerUsageValid": router.info?.isF50 == true && router.info?.monthlyTotal != nil,
            "lastSavedAt": lastSavedAt?.timeIntervalSince1970 ?? 0,
            "billingCycleDay": config.billingCycleDay ?? 0, "billingTimeZone": config.billingTimeZone,
            "warnings": [configWarning, stateWarning, saveWarning, notificationWarning, billingWarning].compactMap { $0 }
        ]
        if let total = router.info?.monthlyTotal { status["routerCounterBytes"] = total }
        if let key = tracker.context?.key, let usage = tracker.billingUsage(key: key, config: config, date: Date()) {
            status["billingPeriod"] = usage.period.label
            status["billingRecordedBytes"] = usage.total
            status["billingQuotaReady"] = usage.canEstimateQuota
        }
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Config.supportDir.appendingPathComponent("runtime.json"), options: .atomic)
        }
    }

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.notificationsAllowed = settings.authorizationStatus == .authorized
                self.notificationWarning = self.config.enableQuotaAlerts && !self.notificationsAllowed
                    ? "配额提醒未授权，请在设置中启用并允许通知" : nil
            }
        }
    }

    private func checkQuotaAlert(key: String) {
        let now = Date()
        guard configWarning == nil, config.enableQuotaAlerts, notificationsAllowed,
              let previous = tracker.billingUsage(key: key, config: config, date: now),
              let threshold = tracker.billingQuotaAlert(key: key, config: config, date: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = "F50 用量达到配置额度的 \(threshold)%"
        content.body = "\(previous.period.label)，月度估算用量 \(Fmt.bytes(previous.total))，套餐额度 \(Fmt.trim(config.quotaGB)) GB。实际余量请查询运营商。"
        content.sound = .default
        let submitted = tracker.state.billing[key]?[previous.period.key]?.notified
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                // 只恢复这次失败的提醒，保留提交通知后的流量采样。
                if self?.tracker.state.billing[key]?[previous.period.key]?.notified == submitted {
                    self?.tracker.state.billing[key]?[previous.period.key]?.notified = previous.notified
                }
                self?.tracker.markDirty()
                self?.notificationWarning = "配额提醒发送失败：\(error.localizedDescription)"
            }
        }
        saveState()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func openSettings() {
        let settingsNetwork = tracker.context?.key
        settingsController = SettingsController(config: config, networkKey: settingsNetwork) { [weak self] next, usedGB in
            guard let self = self else { return }
            var candidate = self.tracker
            if let usedGB = usedGB {
                let now = Date()
                guard let context = self.tracker.context,
                      context.key == settingsNetwork,
                      SysInfo.networkContext(interface: self.config.interface) == context,
                      self.config.interface == next.interface, self.config.routerGateway == next.routerGateway,
                      let info = self.router.info, info.isF50, let sampledAt = self.router.updatedAt,
                      now.timeIntervalSince(sampledAt) >= 0,
                      now.timeIntervalSince(sampledAt) <= min(60, max(10, self.config.routerPollSec * 2)) else {
                    throw ConfigError(message: "请连接 F50 并刷新设备读数，再填写运营商当前已用量；网卡或管理地址请另行保存")
                }
                try candidate.sampleBilling(info, key: context.key, config: next, date: now, calibratedGB: usedGB)
            }
            try next.save()
            self.tracker = candidate
            let enable = next.enableQuotaAlerts
            self.applyConfig(next)
            if enable {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    self.refreshNotificationPermission()
                }
            }
            self.saveState()
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.fileURL) }
    @objc private func openData() { NSWorkspace.shared.open(Config.supportDir) }
    @objc private func doRefresh() { tick(); refreshRouter(force: true); saveState() }
    @objc private func quit() { saveState(); NSApp.terminate(nil) }
}
