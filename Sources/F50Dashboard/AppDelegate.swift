import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let menuRenderer = MenuRenderer()
    private lazy var dashboard = DashboardPopover(version: appVersion) { [weak self] action in
        self?.handleDashboardAction(action)
    }
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
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleDashboard(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            // 切网时关闭当前快照，避免在菜单中继续浏览上个网络的数据。
            if menuOpen { menu.cancelTracking() }
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
                if request.targetsCurrentGateway {
                    self.tracker.rememberDevice(info, key: request.network.key, date: Date())
                }
                if info.isF50Pro && request.targetsCurrentGateway {
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
        guard menu === self.menu else { return }
        let loaded = Config.read(fallback: config)
        if loaded.config != config { applyConfig(loaded.config) }
        configWarning = loaded.warning
        tick()
        rebuild(allowStructureChanges: true)
        menuOpen = true
        refreshRouter()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { menuOpen = false }
    }
    private func rebuildIfOpen() {
        if menuOpen { rebuild() }
        if dashboard.isShown { dashboard.update(dashboardSnapshot()) }
    }

    private func dashboardSnapshot() -> DashboardSnapshot {
        DashboardSnapshot.make(tracker: tracker, router: router, config: config,
            configWarning: configWarning,
            warnings: [configWarning, stateWarning, saveWarning].compactMap { $0 },
            deviceWarnings: [notificationWarning, billingWarning].compactMap { $0 })
    }

    @objc private func toggleDashboard(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            dashboard.close()
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
            return
        }
        if !dashboard.isShown {
            let loaded = Config.read(fallback: config)
            if loaded.config != config { applyConfig(loaded.config) }
            configWarning = loaded.warning
            tick()
            dashboard.update(dashboardSnapshot())
            refreshRouter()
        }
        dashboard.toggle(from: sender)
    }

    private func handleDashboardAction(_ action: MenuEntry.Action) {
        if action != .refresh { dashboard.close() }
        switch action {
        case .settings: openSettings()
        case .config: openConfig()
        case .data: openData()
        case .refresh: doRefresh()
        case .quit: quit()
        }
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
        value.target = action == nil ? nil : self
        value.isEnabled = action != nil
        return value
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

    private func menuEntries() -> [MenuEntry] {
        DashboardMenu.entries(tracker: tracker, router: router, config: config,
            configWarning: configWarning,
            warnings: [configWarning, stateWarning, saveWarning].compactMap { $0 },
            deviceWarnings: [notificationWarning, billingWarning].compactMap { $0 })
    }

    private func menuItem(_ entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let selector = entry.action.map { action -> Selector in
            switch action {
            case .settings: return #selector(openSettings)
            case .config: return #selector(openConfig)
            case .data: return #selector(openData)
            case .refresh: return #selector(doRefresh)
            case .quit: return #selector(quit)
            }
        }
        let value = item(entry.title, action: selector)
        if let children = entry.children {
            let submenu = NSMenu()
            for child in children { submenu.addItem(menuItem(child)) }
            value.submenu = submenu
            value.isEnabled = true
        }
        return value
    }

    private func rebuild(allowStructureChanges: Bool? = nil) {
        menuRenderer.update(menuEntries(), menu: menu,
            allowStructureChanges: allowStructureChanges ?? !menuOpen, makeItem: menuItem)
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
            "dashboardStyle": "compact-card", "dashboardVisible": dashboard.isShown,
            "updatedAt": Date().timeIntervalSince1970,
            "networkKey": tracker.context?.key ?? "", "interface": tracker.context?.interface ?? "",
            "localPollSec": config.localPollSec, "routerPollSec": config.routerPollSec,
            "routerModel": router.info?.model ?? "",
            "routerUsageValid": router.info?.isF50Pro == true && router.info?.monthlyTotal != nil,
            "lastSavedAt": lastSavedAt?.timeIntervalSince1970 ?? 0,
            "billingCycleDay": config.billingCycleDay ?? 0, "billingTimeZone": config.billingTimeZone,
            "warnings": [configWarning, stateWarning, saveWarning, notificationWarning, billingWarning].compactMap { $0 }
        ]
        let module = router.moduleState(current: tracker.context,
            knownDevice: tracker.context.flatMap { tracker.state.devices[$0.key] })
        status["f50ModuleState"] = module.rawValue
        status["f50ModuleVisible"] = module != .hidden
        status["menuTitles"] = menuEntries().filter { !$0.isSeparator }.map(\.title)
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
                      let info = self.router.info, info.isF50Pro, let sampledAt = self.router.updatedAt,
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
    @objc private func doRefresh() { tick(); refreshRouter(force: true); rebuildIfOpen(); saveState() }
    @objc private func quit() { saveState(); NSApp.terminate(nil) }
}
