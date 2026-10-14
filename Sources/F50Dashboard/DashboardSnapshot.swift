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
        var shortLabel: String { String(id.suffix(2)) }
        var detail: String { "\(id) · \(total.map(Fmt.bytes) ?? "未记录")\(isToday ? " · 当日累计" : "")" }
    }
    var networkKey = ""
    var networkName = "等待系统网络信息"
    var interface = ""
    var localTotal = "—"
    var localAvailable = false
    var download = Rate()
    var upload = Rate()
    var phase = F50ModuleState.hidden
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
            knownDevice: tracker.context.flatMap { tracker.state.devices[$0.key] })
        value.details = entries.first { $0.title == "详细信息" }?.children ?? []
        // 七天数据已在图中呈现；展开历史仍可查各网络累计和系统网卡累计。
        value.history = (entries.first { $0.title == "历史用量" }?.children ?? []).filter { $0.title != "近七天（当前网络）" }
        value.warnings = warnings + (value.phase == .hidden ? [] : deviceWarnings)
        for offset in (0..<7).reversed() {
            let day = TrafficTracker.dayKey(Calendar.current.date(byAdding: .day, value: -offset, to: date)!)
            let usage = tracker.context.flatMap { tracker.state.daily[day]?[$0.key] }
            value.days.append(Day(id: day, total: usage?.total, isToday: offset == 0))
        }
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
        value.signal = "\(info.netType.isEmpty ? "移动网络未知" : info.netType)"
        if !info.sigBar.isEmpty { value.signal += " · \(info.sigBar)/5" }
        if !info.rsrp.isEmpty { value.signal += " · \(info.rsrp) dBm" }
        value.stationCount = info.hasStationList ? "\(info.stations.count) 台接入" : "接入设备未知"
        if let updated = router.updatedAt {
            value.updated = "设备更新于 \(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))"
        }
        guard configWarning == nil else { value.quotaNotice = "配置未加载，暂不估算套餐余量"; return value }
        guard config.billingCycleDay != nil else { value.quotaNotice = "请在设置中填写重置日和运营商本月已用量"; return value }
        guard info.monthlyTotal != nil else { value.quotaNotice = "设备用量暂不可用，等待下次刷新"; return value }
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
}

struct DailyChartScale: Equatable {
    let divisor: Double
    let unit: String
    let ceiling: Double
    init(days: [DashboardSnapshot.Day]) {
        let maximum = Double(days.compactMap(\.total).max() ?? 0)
        if maximum == 0 || maximum >= Fmt.giga { divisor = Fmt.giga; unit = "GB" }
        else if maximum >= Fmt.mega { divisor = Fmt.mega; unit = "MB" }
        else if maximum >= Fmt.kilo { divisor = Fmt.kilo; unit = "KB" }
        else { divisor = 1; unit = "B" }
        let scaled = max(1, maximum / divisor)
        let base = pow(10, floor(log10(scaled)))
        ceiling = ([1.0, 2, 2.5, 5, 10].first { $0 >= scaled / base } ?? 10) * base
    }
    func fraction(_ total: UInt64) -> Double { min(1, Double(total) / divisor / ceiling) }
    func label(_ value: Double) -> String {
        var result = String(format: "%.2f", value)
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }
}
