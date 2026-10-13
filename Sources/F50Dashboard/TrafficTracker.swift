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

    init() {}
    private enum CodingKeys: String, CodingKey { case buckets, daily, alerts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decode([String: Bucket].self, forKey: .buckets)
        daily = try c.decodeIfPresent([String: [String: Usage]].self, forKey: .daily) ?? [:]
        alerts = try c.decodeIfPresent([String: AlertRecord].self, forKey: .alerts) ?? [:]
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

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 同一计数周期只提醒一次；计数下降后开始新周期。
    mutating func quotaAlert(total: UInt64, quotaGB: Double, key: String) -> Int? {
        var record = state.alerts[key] ?? AlertRecord()
        if total < record.lastTotal { record.notified = [] }
        record.lastTotal = total
        let percent = Double(total) / Fmt.giga / quotaGB * 100
        let threshold = [100, 90, 80].first { percent >= Double($0) && !record.notified.contains($0) }
        if let threshold = threshold {
            record.notified.append(contentsOf: [80, 90, 100].filter { $0 <= threshold && !record.notified.contains($0) })
        }
        state.alerts[key] = record
        dirty = true
        return threshold
    }
}
