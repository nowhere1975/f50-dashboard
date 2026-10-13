import Foundation

struct Usage: Codable, Equatable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var total: UInt64 { rx + tx }
}

struct Bucket: Codable, Equatable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var firstSeen: Date = Date()
    var label = ""
}

struct AlertRecord: Codable {
    var lastTotal: UInt64 = 0
    var notified: [Int] = []
}

struct PersistedState: Codable {
    var buckets: [String: Bucket] = [:]
    var daily: [String: [String: Usage]] = [:]
    var alerts: [String: AlertRecord] = [:]
    var billing: [String: [String: BillingUsage]] = [:]
    var devices: [String: ConfirmedDevice] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case buckets, daily, alerts, billing, devices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decode([String: Bucket].self, forKey: .buckets)
        daily = try c.decodeIfPresent([String: [String: Usage]].self, forKey: .daily) ?? [:]
        alerts = try c.decodeIfPresent([String: AlertRecord].self, forKey: .alerts) ?? [:]
        billing = try c.decodeIfPresent([String: [String: BillingUsage]].self, forKey: .billing) ?? [:]
        devices = try c.decodeIfPresent([String: ConfirmedDevice].self, forKey: .devices) ?? [:]
        for (key, device) in devices {
            guard key.hasPrefix("mac:"), !SysInfo.normalizeMAC(String(key.dropFirst(4))).isEmpty,
                  key == "mac:\(device.gatewayMAC)", SysInfo.normalizeMAC(device.gatewayMAC) == device.gatewayMAC,
                  RouterInfo.isF50ProModel(device.model) else { throw ConfigError(message: "设备识别记录无效") }
        }
        for records in billing.values {
            for (key, record) in records {
                guard TimeZone(identifier: record.period.timeZoneID) != nil,
                      (1...31).contains(record.period.resetDay), record.period.start < record.period.end,
                      record.period.start.timeIntervalSince1970 >= -62_135_596_800,
                      record.period.end.timeIntervalSince1970 <= 253_402_300_800,
                      key == record.period.key,
                      record.observedSince >= record.period.start, record.observedSince < record.period.end,
                      record.lastSampleAt >= record.period.start, record.lastSampleAt < record.period.end,
                      record.calibratedAt.map({ $0 >= record.period.start && $0 < record.period.end }) ?? true,
                      record.counterResets >= 0, record.counterResets < 1_000_000,
                      !record.lastRx.addingReportingOverflow(record.lastTx).overflow else {
                    throw ConfigError(message: "套餐周期记录无效")
                }
            }
        }
        var aggregate: UInt64 = 0
        for bucket in buckets.values {
            let total = bucket.rx.addingReportingOverflow(bucket.tx)
            let sum = aggregate.addingReportingOverflow(total.partialValue)
            guard !total.overflow, !sum.overflow else { throw ConfigError(message: "累计计数溢出") }
            aggregate = sum.partialValue
        }
        for day in daily.values {
            for usage in day.values {
                guard !usage.rx.addingReportingOverflow(usage.tx).overflow else { throw ConfigError(message: "每日计数溢出") }
            }
        }
    }
}

struct InterfaceCounters: Equatable {
    let rx: UInt64
    let tx: UInt64
}

struct NetworkContext: Equatable {
    let interface: String
    let gateway: String
    let dns: String
    let gatewayMAC: String

    var key: String {
        if !gatewayMAC.isEmpty { return "mac:\(gatewayMAC)" }
        if gateway.isEmpty { return "iface:\(interface)|no-gateway" }
        return "iface:\(interface)|gw:\(gateway)|dns:\(dns)"
    }
    var hasIPv4Gateway: Bool { !gateway.isEmpty }
}

/// 由主线程使用；可通过离线样本验证跨网络、读数失败和重置。
struct TrafficTracker {
    var state = PersistedState()
    private(set) var context: NetworkContext?
    private(set) var connectedSince = Date()
    private(set) var rateRx: Double = 0
    private(set) var rateTx: Double = 0
    private(set) var counters: InterfaceCounters?
    private var baseline: InterfaceCounters?
    private var sampledAt: TimeInterval?
    private(set) var dirty = false

    mutating func resetBaseline() {
        baseline = nil; sampledAt = nil
        rateRx = 0; rateTx = 0
    }

    @discardableResult
    mutating func sample(context next: NetworkContext, counters current: InterfaceCounters?,
                         uptime: TimeInterval, date: Date, maxGap: TimeInterval) -> Bool {
        let changed = context != next
        if changed {
            context = next; connectedSince = date
            resetBaseline()
        }
        if state.buckets[next.key] == nil {
            state.buckets[next.key] = Bucket(firstSeen: date)
            dirty = true
        }
        counters = current
        guard let current = current else { resetBaseline(); return changed }
        let day = Self.dayKey(date)
        if state.daily[day]?[next.key] == nil {
            state.daily[day, default: [:]][next.key] = Usage()
            dirty = true
        }
        defer { baseline = current; sampledAt = uptime }
        guard let previous = baseline, let last = sampledAt else { return changed }
        let dt = uptime - last
        guard dt > 0, dt <= maxGap, current.rx >= previous.rx, current.tx >= previous.tx else {
            rateRx = 0; rateTx = 0
            return changed
        }
        let rx = current.rx - previous.rx, tx = current.tx - previous.tx
        rateRx = Double(rx) / dt; rateTx = Double(tx) / dt
        guard rx > 0 || tx > 0 else { return changed }
        state.buckets[next.key]!.rx += rx
        state.buckets[next.key]!.tx += tx
        // 跨午夜的一个短采样窗口记入采样结束日。
        var usage = state.daily[day]?[next.key] ?? Usage()
        usage.rx += rx; usage.tx += tx
        state.daily[day, default: [:]][next.key] = usage
        dirty = true
        return changed
    }

    mutating func setLabel(_ label: String, for key: String) {
        guard state.buckets[key]?.label != label else { return }
        state.buckets[key, default: Bucket()].label = label
        dirty = true
    }

    mutating func rememberDevice(_ info: RouterInfo, key: String, date: Date) {
        guard key.hasPrefix("mac:"), !SysInfo.normalizeMAC(String(key.dropFirst(4))).isEmpty,
              info.responded, !info.model.isEmpty else { return }
        if info.isF50Pro {
            state.devices[key] = ConfirmedDevice(gatewayMAC: String(key.dropFirst(4)), model: info.model, verifiedAt: date)
            dirty = true
        } else if state.devices.removeValue(forKey: key) != nil { dirty = true }
    }

    /// 升级前后属于同一台设备的累计接续记录；多台已确认 F50 时不猜归属。
    func legacyF50Destination() -> String? {
        guard state.buckets["f50"] != nil else { return nil }
        let candidates = state.buckets.filter { key, bucket in
            key.hasPrefix("mac:") && bucket.label == "F50 Pro"
                && !SysInfo.normalizeMAC(String(key.dropFirst(4))).isEmpty
        }.map(\.key)
        return candidates.count == 1 ? candidates[0] : nil
    }

    @discardableResult
    mutating func mergeLegacyF50() throws -> Bool {
        guard let key = legacyF50Destination(), let legacy = state.buckets["f50"],
              var current = state.buckets[key] else { return false }
        func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
            let result = a.addingReportingOverflow(b)
            guard !result.overflow else { throw ConfigError(message: "累计合并超出计数范围，原记录已保留") }
            return result.partialValue
        }
        var next = state
        current.rx = try add(current.rx, legacy.rx)
        current.tx = try add(current.tx, legacy.tx)
        current.firstSeen = min(current.firstSeen, legacy.firstSeen)
        next.buckets[key] = current
        next.buckets.removeValue(forKey: "f50")
        // 只转移已有的日记录，不把没有日期明细的累计补到某一天。
        for day in Array(next.daily.keys) {
            if let usage = next.daily[day]?.removeValue(forKey: "f50") {
                var merged = next.daily[day]?[key] ?? Usage()
                merged.rx = try add(merged.rx, usage.rx)
                merged.tx = try add(merged.tx, usage.tx)
                guard !merged.rx.addingReportingOverflow(merged.tx).overflow else {
                    throw ConfigError(message: "每日累计合并超出计数范围，原记录已保留")
                }
                next.daily[day]![key] = merged
            }
        }
        if let legacyAlert = next.alerts.removeValue(forKey: "f50"), next.alerts[key] == nil {
            next.alerts[key] = legacyAlert
        }
        state = next
        dirty = true
        return true
    }
    mutating func didSave() { dirty = false }
    mutating func markDirty() { dirty = true }

    func billingUsage(key: String, config: Config, date: Date) -> BillingUsage? {
        guard let day = config.billingCycleDay else { return nil }
        let period = BillingPeriod.containing(date, resetDay: day, timeZoneID: config.billingTimeZone)
        return state.billing[key]?[period.key]
    }

    mutating func sampleBilling(_ info: RouterInfo, key: String, config: Config, date: Date,
                                calibratedGB: Double? = nil) throws {
        guard let day = config.billingCycleDay, key.hasPrefix("mac:"), info.isF50,
              info.monthlyTotal != nil, let rx = info.monthlyRx, let tx = info.monthlyTx else {
            if calibratedGB != nil { throw ConfigError(message: "请设置套餐重置日，并连接可识别的 F50 后校准") }
            return
        }
        let period = BillingPeriod.containing(date, resetDay: day, timeZoneID: config.billingTimeZone)
        var usage = state.billing[key]?[period.key] ?? BillingUsage(period: period, observedSince: date,
            lastSampleAt: date, lastRx: rx, lastTx: tx, fields: info.usedFields)
        if let usedGB = calibratedGB {
            try usage.calibrate(usedGB: usedGB, rx: rx, tx: tx, fields: info.usedFields, date: date)
        } else {
            try usage.sample(rx: rx, tx: tx, fields: info.usedFields, date: date,
                             maxGap: max(120, config.routerPollSec * 3))
        }
        state.billing[key, default: [:]][period.key] = usage
        dirty = true
    }

    mutating func billingQuotaAlert(key: String, config: Config, date: Date) -> Int? {
        guard var usage = billingUsage(key: key, config: config, date: date) else { return nil }
        let threshold = usage.quotaAlert(quotaGB: config.quotaGB)
        if threshold != nil { state.billing[key]![usage.period.key] = usage; dirty = true }
        return threshold
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

}
