import Foundation

struct MenuEntry: Equatable {
    enum Action { case settings, config, data, refresh, quit }
    let id: String
    let title: String
    let children: [MenuEntry]?
    let action: Action?
    let isSeparator: Bool

    init(_ title: String, id: String? = nil, children: [MenuEntry]? = nil, action: Action? = nil, isSeparator: Bool = false) {
        self.id = id ?? (action.map { "action.\($0)" }
            ?? title.components(separatedBy: "  ").first(where: { !$0.isEmpty }) ?? title)
        self.title = title; self.children = children; self.action = action; self.isSeparator = isSeparator
    }
    static var separator: MenuEntry { MenuEntry("", isSeparator: true) }
}

/// 菜单内容与 AppKit 分离，切网和读取失败的显示规则可用离线样本验证。
enum DashboardMenu {
    static func entries(tracker: TrafficTracker, router: RouterState, config: Config,
                        date: Date = Date(), configWarning: String? = nil,
                        warnings: [String] = [], deviceWarnings: [String] = []) -> [MenuEntry] {
        var rows: [MenuEntry] = []
        func add(_ title: String) { rows.append(MenuEntry(title)) }
        add(tracker.counters == nil ? "实时速率      ↓ ---    ↑ ---"
            : "实时速率      ↓ \(Fmt.bytes(UInt64(max(0, tracker.rateRx))))/s    ↑ \(Fmt.bytes(UInt64(max(0, tracker.rateTx))))/s")
        if tracker.counters == nil { add("  本机计数读取失败，等待下一次采样") }
        rows.append(.separator)
        if let context = tracker.context {
            let bucket = tracker.state.buckets[context.key] ?? Bucket()
            add("当前网络      \(name(context.key, tracker: tracker, config: config))")
            add("  本网络累计  ↓ \(Fmt.bytes(bucket.rx))   ↑ \(Fmt.bytes(bucket.tx))")
            add("  本次连接    \(Fmt.duration(since: tracker.connectedSince, now: date))")
            add("  开始统计    \(DateFormatter.localizedString(from: bucket.firstSeen, dateStyle: .short, timeStyle: .short))")
            if context.gatewayMAC.isEmpty { add("  网络按网卡、网关与 DNS 区分；相同配置可能合并") }
        } else { add("当前网络      等待系统网络信息") }

        let knownDevice = tracker.context.flatMap { tracker.state.devices[$0.key] }
        let phase = router.moduleState(current: tracker.context, knownDevice: knownDevice)
        if phase != .hidden {
            rows.append(.separator)
            add("F50 Pro")
            switch phase {
            case .ready:
                if let info = router.info {
                    rows += billingEntries(tracker: tracker, info: info, config: config, date: date,
                                           configWarning: configWarning)
                    var signal = "移动网络      \(info.netType.isEmpty ? "未知" : info.netType)"
                    if !info.sigBar.isEmpty { signal += " · \(info.sigBar)/5" }
                    if !info.rsrp.isEmpty { signal += " · \(info.rsrp) dBm" }
                    add(signal)
                    add(info.hasStationList ? "接入设备      \(info.stations.count) 台" : "接入设备      暂未取得有效读数")
                    if let updated = router.updatedAt {
                        add("更新于        \(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))（\(Int(max(0, date.timeIntervalSince(updated)))) 秒前）")
                    }
                }
            case .loading: rows.append(MenuEntry("  正在读取设备数据…", id: "device.status"))
            case .unavailable: rows.append(MenuEntry("  设备数据暂不可用，等待下次刷新", id: "device.status"))
            case .hidden: break
            }
            rows.append(MenuEntry("详细信息", children: deviceDetails(tracker: tracker, router: router,
                                                                    phase: phase, knownDevice: knownDevice)))
            for (index, warning) in deviceWarnings.enumerated() {
                rows.append(MenuEntry("提示：\(warning)", id: "warning.device.\(index)"))
            }
        }
        rows.append(.separator)
        rows.append(MenuEntry("历史用量", children: history(tracker: tracker, config: config, date: date)))
        for (index, warning) in warnings.enumerated() {
            rows.append(MenuEntry("提示：\(warning)", id: "warning.general.\(index)"))
        }
        rows.append(.separator)
        rows += [MenuEntry("设置…", action: .settings), MenuEntry("打开配置文件", action: .config),
                 MenuEntry("打开数据目录", action: .data), MenuEntry("刷新", action: .refresh),
                 MenuEntry("退出", action: .quit)]
        return rows
    }

    private static func billingEntries(tracker: TrafficTracker, info: RouterInfo, config: Config,
                                       date: Date, configWarning: String?) -> [MenuEntry] {
        guard configWarning == nil else { return [MenuEntry("SIM 卡用量    配置未加载，暂不估算余量", id: "quota.notice")] }
        var rows = [MenuEntry("SIM 卡月度用量（估算）"),
                    MenuEntry("  套餐额度    \(Fmt.trim(config.quotaGB)) GB（手动设置）")]
        guard let day = config.billingCycleDay else {
            rows.append(MenuEntry("  请在设置中填写重置日和运营商本周期已用量", id: "quota.notice"))
            return rows
        }
        let period = BillingPeriod.containing(date, resetDay: day, timeZoneID: config.billingTimeZone)
        rows.append(MenuEntry("  套餐周期    \(period.label)"))
        guard info.monthlyTotal != nil else {
            rows.append(MenuEntry("  设备用量暂不可用，等待下次刷新"))
            return rows
        }
        guard let key = tracker.context?.key, let usage = tracker.billingUsage(key: key, config: config, date: date) else {
            rows.append(MenuEntry("  月度已记录  尚未取得有效采样"))
            return rows
        }
        if usage.canEstimateQuota {
            let used = Double(usage.total) / Fmt.giga
            let percent = used / config.quotaGB * 100
            rows += [MenuEntry("  已用估算    \(Fmt.bytes(usage.total)) / \(Fmt.trim(config.quotaGB)) GB · \(String(format: "%.2f", percent))%", id: "quota.used"),
                     MenuEntry("  估算剩余    \(String(format: "%.2f", max(0, config.quotaGB - used))) GB"),
                     MenuEntry("  \(Fmt.bar(percent))", id: "quota.progress"), MenuEntry("  套餐余量以运营商查询结果为准", id: "quota.notice")]
        } else {
            rows.append(MenuEntry("  月度已记录  \(Fmt.bytes(usage.total))", id: "quota.used"))
            rows.append(MenuEntry(usage.calibratedAt == nil ? "  请查询运营商本月已用量，在设置中校准"
                : "  采样存在缺口，请用运营商已用量重新校准", id: "quota.notice"))
        }
        if config.enableQuotaAlerts && !usage.canEstimateQuota { rows.append(MenuEntry("  月度配额提醒等待用量校准")) }
        return rows
    }

    private static func deviceDetails(tracker: TrafficTracker, router: RouterState,
                                       phase: F50ModuleState, knownDevice: ConfirmedDevice?) -> [MenuEntry] {
        var rows: [MenuEntry] = []
        let info = phase == .ready ? router.info : nil
        if let info = info {
            rows += [MenuEntry("型号          \(info.model)", id: "device.model"), MenuEntry("固件          \(info.firmware)")]
            if let total = info.monthlyTotal {
                rows += [.separator, MenuEntry("设备原始统计  \(Fmt.bytes(total))"),
                         MenuEntry("  下载/上传   \(Fmt.bytes(info.monthlyRx!)) / \(Fmt.bytes(info.monthlyTx!))"),
                         MenuEntry("  字段        \(info.usedFields)"),
                         MenuEntry("设备原始统计不代表完整套餐月度用量")]
            }
            if !info.wanIP.isEmpty { rows.append(MenuEntry("WAN IP        \(info.wanIP)")) }
            if info.hasStationList {
                rows.append(.separator)
                rows.append(MenuEntry("接入设备地址（最多列出 8 台）"))
                rows += info.stations.prefix(8).enumerated().map {
                    MenuEntry("  \($0.element.ip)   \($0.element.mac)", id: "device.client.\($0.offset)")
                }
            }
        } else if let device = knownDevice { rows.append(MenuEntry("已确认型号    \(device.model)", id: "device.model")) }
        if let context = tracker.context {
            rows += [.separator, MenuEntry("当前网卡      \(context.interface)"),
                     MenuEntry("当前网关      \(context.gateway)"),
                     MenuEntry("网关 MAC      \(context.gatewayMAC.isEmpty ? "未获取" : context.gatewayMAC)")]
        }
        if let error = router.errorMessage { rows.append(MenuEntry("读取提示：\(error)", id: "device.error")) }
        return rows
    }

    private static func history(tracker: TrafficTracker, config: Config, date: Date) -> [MenuEntry] {
        var days: [MenuEntry] = []
        if let key = tracker.context?.key {
            for offset in 0..<7 {
                let day = TrafficTracker.dayKey(Calendar.current.date(byAdding: .day, value: -offset, to: date)!)
                let usage = tracker.state.daily[day]?[key]
                days.append(MenuEntry("\(day)    \(usage.map { Fmt.bytes($0.total) } ?? "—（未记录）")", id: "history.day.\(day)"))
            }
        } else { days.append(MenuEntry("尚未取得当前网络")) }
        var all = Usage()
        for bucket in tracker.state.buckets.values { all.rx += bucket.rx; all.tx += bucket.tx }
        var networks = [MenuEntry("全部网络累计  ↓ \(Fmt.bytes(all.rx))   ↑ \(Fmt.bytes(all.tx))"), .separator]
        for (key, bucket) in tracker.state.buckets.sorted(by: { $0.value.firstSeen > $1.value.firstSeen }) {
            networks.append(MenuEntry("\(name(key, tracker: tracker, config: config))  ↓ \(Fmt.bytes(bucket.rx))  ↑ \(Fmt.bytes(bucket.tx))", id: "history.network.\(key)"))
        }
        var rows = [MenuEntry("近七天（当前网络）", children: days),
                    MenuEntry("各网络累计", children: networks), .separator,
                    MenuEntry("仅统计本机在 App 运行期间的有效采样")]
        if let counters = tracker.counters {
            rows += [.separator, MenuEntry("系统网卡累计  ↓ \(Fmt.bytes(counters.rx))   ↑ \(Fmt.bytes(counters.tx))")]
        }
        return rows
    }

    private static func name(_ key: String, tracker: TrafficTracker, config: Config) -> String {
        if let custom = config.networkNames[key], !custom.isEmpty { return custom }
        if key == "f50" { return "F50 Pro" }
        if let label = tracker.state.buckets[key]?.label, !label.isEmpty { return label }
        if let context = tracker.context, context.key == key {
            return context.gateway.isEmpty ? "未连接 IPv4 网络（\(context.interface)）" : "\(context.interface) · \(context.gateway)"
        }
        return key
    }
}
