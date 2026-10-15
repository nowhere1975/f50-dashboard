import Foundation

/// 卡片与原生菜单共用当前状态；只有当前网关的有效读数才能生成套餐余量。
struct DashboardSnapshot: Equatable {
    struct Rate: Equatable {
        var value = "—"
        var unit = ""
        init(_ bytes: Double? = nil) {
            guard let bytes = bytes, bytes.isFinite, bytes >= 0, bytes < Double(UInt64.max) else { return }
            let parts = Fmt.bytes(UInt64(bytes)).split(separator: " ")
            value = String(parts[0]); unit = "\(parts[1])/s"
        }
    }
    struct Day: Equatable, Identifiable {
        let id: String
        let total: UInt64?
        let isToday: Bool
        var routerTotal: UInt64? = nil
        var routerLabel = "路由器"
        var isFuture = false
        var shortLabel: String { String(id.suffix(2)) }
        var hasRouterTraffic: Bool { (routerTotal ?? 0) > 0 }
        var otherTotal: UInt64? { total.flatMap { total in routerTotal.map { total - min(total, $0) } } }
        var detail: String {
            if isFuture { return "\(id) · 尚未到来" }
            guard let total = total else { return "\(id) · 未记录" }
            let title = "\(id) · 本机总量 \(Fmt.bytes(total))"
            return hasRouterTraffic ? title + "\n\(routerLabel) \(Fmt.bytes(routerTotal!)) · 其他 \(Fmt.bytes(otherTotal!))" : title
        }
    }
    var networkKey = ""
    var networkName = "等待系统网络信息"
    var interface = ""
    var localTotal = "—"
    var localAvailable = false
    var download = Rate()
    var upload = Rate()
    var phase = RouterModuleState.hidden
    var deviceName = "路由器"
    var supportsTraffic = false
    var supportsClients = false
    var routerTrafficLabel = "路由器"
    var quotaGB: Double = 0
    var remainingGB: Double?
    var remainingPercent: Double?
    var usedBytes: UInt64?
    var period = ""
    var reset = ""
    var quotaNotice = ""
    var signal = ""
    var stationCount = ""
    var updated = ""
    var days: [Day] = []
    var monthTitle = ""
    var monthTotal: UInt64?
    var monthRouterTotal: UInt64?
    var monthOtherTotal: UInt64? { monthTotal.flatMap { total in monthRouterTotal.map { total - min(total, $0) } } }
    var recordedDays: Int { days.filter { $0.total != nil }.count }
    var details: [MenuEntry] = []
    var history: [MenuEntry] = []
    var warnings: [String] = []

    static func make(tracker: TrafficTracker, router: RouterState, config: Config, date: Date = Date(),
                     configWarning: String? = nil, warnings: [String] = [], deviceWarnings: [String] = []) -> Self {
        var value = Self()
        value.localAvailable = tracker.counters != nil
        value.download = Rate(value.localAvailable ? tracker.rateRx : nil)
        value.upload = Rate(value.localAvailable ? tracker.rateTx : nil)
        let entries = DashboardMenu.entries(tracker: tracker, router: router, config: config, date: date,
            configWarning: configWarning, warnings: warnings, deviceWarnings: deviceWarnings)
        if let context = tracker.context {
            value.networkKey = context.key; value.interface = context.interface
            value.networkName = DashboardMenu.name(context.key, tracker: tracker, config: config)
            let bucket = tracker.state.buckets[context.key] ?? Bucket()
            value.localTotal = "↓ \(Fmt.bytes(bucket.rx))   ↑ \(Fmt.bytes(bucket.tx))"
        }
        value.phase = router.moduleState(current: tracker.context,
            knownDevice: tracker.context.flatMap { tracker.state.devices[$0.key] }, selection: config.routerAdapter)
        let descriptor = router.descriptor(current: tracker.context,
            knownDevice: tracker.context.flatMap { tracker.state.devices[$0.key] }, selection: config.routerAdapter)
        value.deviceName = descriptor?.name ?? "路由器"
        value.supportsTraffic = descriptor?.capabilities.contains(.traffic) == true
        value.supportsClients = descriptor?.capabilities.contains(.clients) == true
        value.details = entries.first { $0.title == "详细信息" }?.children ?? []
        // 月度图汇总所有网络；历史子菜单仍可查当前网络七天明细和各网络累计。
        value.history = entries.first { $0.title == "历史用量" }?.children ?? []
        value.warnings = warnings + (value.phase == .hidden ? [] : deviceWarnings)
        value.loadMonth(tracker.state, date: date)
        guard value.phase != .hidden else { return value }
        value.quotaGB = config.quotaGB
        if let day = config.billingCycleDay {
            let period = BillingPeriod.containing(date, resetDay: day, timeZoneID: config.billingTimeZone)
            value.period = period.label
            let formatter = DateFormatter()
            formatter.timeZone = period.calendar.timeZone; formatter.dateFormat = "M 月 d 日"
            value.reset = "\(formatter.string(from: period.end))重置"
        }
        guard value.phase == .ready, let info = router.info else {
            value.quotaNotice = value.phase == .loading ? "正在读取设备数据…" : "设备数据暂不可用，等待下次刷新"
            return value
        }
        if descriptor?.capabilities.contains(.signal) == true {
            value.signal = info.netType.isEmpty ? "移动网络未知" : info.netType
            if !info.sigBar.isEmpty { value.signal += " · \(info.sigBar)/5" }
            if !info.rsrp.isEmpty { value.signal += " · \(info.rsrp) dBm" }
        }
        if value.supportsClients { value.stationCount = info.hasStationList ? "\(info.stations.count) 台接入" : "接入设备未知" }
        if let updated = router.updatedAt {
            value.updated = "设备更新于 \(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))"
        }
        guard value.supportsTraffic else { return value }
        guard configWarning == nil else { value.quotaNotice = "配置未加载，暂不估算套餐余量"; return value }
        guard config.billingCycleDay != nil else { value.quotaNotice = "请在设置中填写重置日和运营商本月已用量"; return value }
        guard info.counterTotal != nil else { value.quotaNotice = "设备用量暂不可用，等待下次刷新"; return value }
        guard let key = tracker.context?.key, let usage = tracker.billingUsage(key: key, config: config, date: date) else {
            value.quotaNotice = "尚未取得有效用量采样"; return value
        }
        value.usedBytes = usage.total
        guard usage.canEstimateQuota else {
            value.quotaNotice = usage.calibratedAt == nil ? "请在设置中用运营商本月已用量校准" : "采样存在缺口，请用运营商已用量重新校准"
            return value
        }
        value.remainingGB = max(0, config.quotaGB - Double(usage.total) / Fmt.giga)
        value.remainingPercent = min(100, max(0, value.remainingGB! / config.quotaGB * 100))
        return value
    }

    private mutating func loadMonth(_ state: PersistedState, date: Date) {
        let calendar = Calendar.current
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              let range = calendar.range(of: .day, in: .month, for: date) else { return }
        let components = calendar.dateComponents([.year, .month], from: date)
        monthTitle = "\(components.year!) 年 \(components.month!) 月"
        let today = TrafficTracker.dayKey(date)
        var networks = state.routerNetworks
        for (key, device) in state.devices where networks[key] == nil {
            if let descriptor = device.descriptor() {
                networks[key] = RouterNetworkRecord(adapterID: descriptor.id, name: descriptor.name, model: device.model)
            }
        }
        let routerKeys = Set(networks.keys)
        let names = Set(networks.values.map(\.name))
        routerTrafficLabel = names.count == 1 ? names.first! : "路由器"
        func sum(_ amounts: [UInt64]) -> UInt64? {
            var total: UInt64 = 0
            for amount in amounts {
                let next = total.addingReportingOverflow(amount)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }
        for index in range {
            let day = TrafficTracker.dayKey(calendar.date(byAdding: .day, value: index - 1, to: start)!)
            let future = day > today
            let records = future ? nil : state.daily[day]
            let total = records.flatMap { $0.isEmpty ? nil : sum($0.values.map(\.total)) }
            let router = total == nil ? nil : sum(records!.filter { routerKeys.contains($0.key) }.map { $0.value.total })
            days.append(Day(id: day, total: total, isToday: day == today, routerTotal: router, routerLabel: routerTrafficLabel, isFuture: future))
        }
        guard recordedDays > 0 else { return }
        monthTotal = sum(days.compactMap(\.total))
        monthRouterTotal = sum(days.compactMap(\.routerTotal))
    }
}
