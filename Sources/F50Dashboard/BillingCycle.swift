import Foundation

struct BillingPeriod: Codable, Equatable {
    let start: Date
    let end: Date
    let resetDay: Int
    let timeZoneID: String

    var key: String { "\(resetDay)@\(timeZoneID):\(Int(start.timeIntervalSince1970))" }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        return calendar
    }
    var label: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: start)) 至 \(formatter.string(from: end.addingTimeInterval(-1)))"
    }

    static func containing(_ date: Date, resetDay: Int, timeZoneID: String) -> BillingPeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let month = calendar.dateInterval(of: .month, for: date)!.start
        func boundary(_ month: Date) -> Date {
            let days = calendar.range(of: .day, in: .month, for: month)!.count
            return calendar.date(byAdding: .day, value: min(resetDay, days) - 1, to: month)!
        }
        let startMonth = date < boundary(month) ? calendar.date(byAdding: .month, value: -1, to: month)! : month
        return BillingPeriod(start: boundary(startMonth),
                             end: boundary(calendar.date(byAdding: .month, value: 1, to: startMonth)!),
                             resetDay: resetDay, timeZoneID: timeZoneID)
    }
}

/// 独立于设备清零的月度记录。首次设备读数只建立基线，不冒充此前的套餐用量。
struct BillingUsage: Codable {
    let period: BillingPeriod
    var total: UInt64 = 0
    var observedSince: Date
    var calibratedAt: Date?
    var lastSampleAt: Date
    var lastRx: UInt64
    var lastTx: UInt64
    var fields: String
    var adapterID: String? = nil
    var hasGap = false
    var counterResets = 0
    var notified: [Int] = []

    var canEstimateQuota: Bool { calibratedAt != nil && !hasGap }

    mutating func sample(rx: UInt64, tx: UInt64, fields: String, date: Date, maxGap: TimeInterval) throws {
        guard date >= lastSampleAt else { hasGap = true; return }
        let reset = rx < lastRx || tx < lastTx
        if date.timeIntervalSince(lastSampleAt) > maxGap || reset || self.fields != fields { hasGap = true }
        // 字段来源变更不作差；同一字段下降只接续清零后的读数，不清空本月累计。
        if self.fields == fields {
            let rxDelta = rx >= lastRx ? rx - lastRx : rx
            let txDelta = tx >= lastTx ? tx - lastTx : tx
            let delta = rxDelta.addingReportingOverflow(txDelta)
            let sum = total.addingReportingOverflow(delta.partialValue)
            guard !delta.overflow, !sum.overflow else { throw ConfigError(message: "套餐累计计数溢出，原记录已保留") }
            total = sum.partialValue
        }
        if reset { counterResets += 1 }
        lastRx = rx; lastTx = tx; self.fields = fields; lastSampleAt = date
    }

    mutating func calibrate(usedGB: Double, rx: UInt64, tx: UInt64, fields: String, date: Date) throws {
        guard usedGB.isFinite, (0...1_000_000).contains(usedGB) else {
            throw ConfigError(message: "运营商已用量必须为 0–1000000 GB")
        }
        total = UInt64((usedGB * Fmt.giga).rounded())
        calibratedAt = date; observedSince = date; lastSampleAt = date
        lastRx = rx; lastTx = tx; self.fields = fields; hasGap = false
        // 同一套餐周期内校准不会重新发送已经发出的提醒。
    }

    mutating func quotaAlert(quotaGB: Double) -> Int? {
        guard canEstimateQuota else { return nil }
        let percent = Double(total) / Fmt.giga / quotaGB * 100
        let threshold = [100, 90, 80].first { percent >= Double($0) && !notified.contains($0) }
        if let threshold = threshold { notified += [80, 90, 100].filter { $0 <= threshold && !notified.contains($0) } }
        return threshold
    }
}
