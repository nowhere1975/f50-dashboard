import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let now = ISO8601DateFormatter().date(from: "2026-10-14T09:00:00+08:00")!
var config = Config(); config.quotaGB = 200; config.billingCycleDay = 1
let pro = NetworkContext(interface: "en0", gateway: "192.168.0.1", dns: "192.168.0.1", gatewayMAC: "01:02:03:04:05:06")
let home = NetworkContext(interface: "en7", gateway: "192.168.0.1", dns: "192.168.0.1", gatewayMAC: "11:12:13:14:15:16")
var tracker = TrafficTracker()
tracker.sample(context: pro, counters: InterfaceCounters(rx: 1000, tx: 100), uptime: 0, date: now, maxGap: 30)
tracker.setLabel("F50 Pro", for: pro.key)
var info = RouterInfo()
info.responded = true; info.model = "F50ProV1.0.0B27"; info.firmware = "MU3356V1.0.0B27"
info.monthlyRx = 28_000_000; info.monthlyTx = 27_000_000; info.usedFields = "fixture"
info.netType = "LTE"; info.sigBar = "5"; info.rsrp = "-92"; info.wanIP = "10.2.3.4"
info.hasStationList = true; info.stations = [(mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.0.101")]
tracker.rememberDevice(info, key: pro.key, date: now)
try tracker.sampleBilling(info, key: pro.key, config: config, date: now, calibratedGB: 27.03)
var router = RouterState()
let initialRequest = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: initialRequest, current: pro, date: now)

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
func snapshot(_ configWarning: String? = nil) -> DashboardSnapshot {
    DashboardSnapshot.make(tracker: tracker, router: router, config: config, date: now,
                           configWarning: configWarning, deviceWarnings: ["device-only warning"])
}
tracker.state.daily["2026-09-30"] = [pro.key: Usage(rx: 99_000_000_000)]
tracker.state.daily["2026-10-11"] = [home.key: Usage()]
tracker.state.daily["2026-10-12"] = [home.key: Usage(rx: 500_000_000)]
tracker.state.daily["2026-10-13"] = [pro.key: Usage(rx: 590_000_000, tx: 3_000_000), home.key: Usage(rx: 100_000_000)]
tracker.state.daily["2026-10-14"] = [pro.key: Usage(rx: 2_300_000_000, tx: 80_000_000), home.key: Usage(rx: 500_000_000)]
tracker.state.daily["2026-10-20"] = [pro.key: Usage(rx: 8_000_000_000)] // 时钟异常留下的未来记录不纳入当月已用。
tracker.state.daily["2026-11-01"] = [pro.key: Usage(rx: 88_000_000_000)]
let encodedBefore = try JSONEncoder().encode(tracker.state)
var first = snapshot()
first.warnings = []
expect(first.phase == .ready, "confirmed current Pro creates quota card")
expect(abs(first.remainingGB! - 172.97) < 0.000001, "remaining comes from calibrated SIM baseline")
expect(first.usedBytes == 27_030_000_000, "SIM baseline does not use raw router counter")
expect(first.reset == "11 月 1 日重置", "reset uses next cycle boundary in billing timezone")
expect(first.days.count == 31 && first.days[13].isToday && first.days.last!.isFuture, "month includes every date and distinguishes today and future")
expect(first.days.first!.total == nil, "unrecorded dates stay unknown")
expect(first.days[13].total == 2_880_000_000 && first.days[13].f50Total == 2_380_000_000, "all-network local total includes F50 without SIM calibration or double counting")
expect(first.monthTotal == 4_073_000_000 && first.monthF50Total == 2_973_000_000 && first.monthOtherTotal == 1_100_000_000,
       "month sums both directions across networks and excludes adjacent months and future records")
expect(first.recordedDays == 4, "valid zero counts as an observed day, unknown and future dates do not")
expect(first.days[10].total == 0 && !first.days[10].hasF50, "a recorded idle day is gray, not an unknown empty square")
expect(first.days[12].detail.contains("F50 Pro") && first.days[12].detail.contains("本机总量")
       && !first.days[11].detail.contains("F50 Pro"), "hover details distinguish colored and gray days")
expect(first.days[19].total == nil && first.days[19].detail.contains("尚未到来"), "future days cannot display collected use")
let encodedAfter = try JSONEncoder().encode(tracker.state)
let beforeObject = try JSONSerialization.jsonObject(with: encodedBefore) as! NSDictionary
let afterObject = try JSONSerialization.jsonObject(with: encodedAfter) as! NSDictionary
expect(beforeObject == afterObject, "building a card never mutates saved statistics")
for (text, count) in [("2024-02-18T09:00:00+08:00", 29), ("2025-02-18T09:00:00+08:00", 28),
                      ("2026-04-18T09:00:00+08:00", 30), ("2026-12-18T09:00:00+08:00", 31)] {
    let day = ISO8601DateFormatter().date(from: text)!
    let empty = DashboardSnapshot.make(tracker: TrafficTracker(), router: RouterState(), config: config, date: day)
    expect(empty.days.count == count, "calendar uses actual month length, including leap February")
    expect(empty.monthTotal == nil && empty.monthF50Total == nil && empty.monthOtherTotal == nil,
           "empty month is unknown, never invented zero")
}
var classification = tracker
var otherModel = info; otherModel.model = "MF79"
classification.rememberDevice(otherModel, key: pro.key, date: now)
expect(classification.state.devices[pro.key] == nil && classification.state.f50Networks.contains(pro.key),
       "current device proof can expire without erasing historical classification")
let savedHistory = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(classification.state))
classification.state = savedHistory
expect(DashboardSnapshot.make(tracker: classification, router: RouterState(), config: config, date: now).monthF50Total == first.monthF50Total,
       "historical classification and monthly totals survive reload without current device proof")
var legacyObject = beforeObject as! [String: Any]; legacyObject.removeValue(forKey: "f50Networks")
let legacyState = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: legacyObject))
expect(legacyState.f50Networks.contains(pro.key), "old files seed historical classification from confirmed model evidence")
legacyObject["f50Networks"] = ["iface:unverified"]
do {
    _ = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: legacyObject))
    expect(false, "invalid historical identity must be rejected")
} catch { expect(true, "invalid historical identity cannot silently change usage attribution") }
expect(snapshot("config invalid").remainingGB == nil, "invalid config cannot estimate quota")
let popup = DashboardMenuCard(version: "test")
popup.update(first, allowResize: true)
let host = popup.view
let hostIdentity = ObjectIdentifier(popup.item)
let viewIdentity = ObjectIdentifier(host)
let openingHeight = host.frame.height
expect(popup.state.hoveredDay == nil, "day details are hidden until a square is hovered")
expect(openingHeight > 300 && openingHeight < 600, "menu card uses measured compact height, not a 740-point panel")
expect(popup.item.view === host && !host.isOpaque, "native menu owns a transparent card row")
expect(!host.hosting.allowsVibrancy, "host preserves explicit primary and secondary text colors in native menus")
func scrollViews(_ view: NSView) -> Int { (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollViews($1) } }
expect(scrollViews(host) == 0, "card contains no embedded scroll view or scrollbar")
popup.state.selectedDay = "2026-10-13"
for index in 1...100 {
    tracker.sample(context: pro, counters: InterfaceCounters(rx: UInt64(1000 + index * 10000), tx: UInt64(100 + index * 1000)),
                   uptime: Double(index * 2), date: now.addingTimeInterval(Double(index * 2)), maxGap: 30)
    popup.update(snapshot(), allowResize: false)
    expect(ObjectIdentifier(popup.item) == hostIdentity && ObjectIdentifier(popup.view) == viewIdentity && host.frame.height == openingHeight,
           "refresh retains native menu row, view and opening geometry")
    expect(popup.state.selectedDay == "2026-10-13",
           "refresh retains inspected day")
}
expect(popup.state.snapshot.download.value != first.download.value, "speed remains live")
var request = router.begin(network: pro, gateway: pro.gateway)
var failure = RouterInfo(); failure.errorMessage = "timeout"
router.accept(failure, request: request, current: pro, date: now)
popup.update(snapshot(), allowResize: false)
expect(popup.state.snapshot.phase == .unavailable, "temporary failure retains Pro identity")
expect(popup.state.snapshot.remainingGB == nil && popup.state.snapshot.remainingPercent == nil
       && popup.state.snapshot.usedBytes == nil && popup.state.snapshot.signal.isEmpty, "failure clears previous quota and radio values")
expect(!popup.state.snapshot.details.contains { $0.title.contains("10.2.3.4") }, "failure clears previous WAN address")
expect(popup.state.selectedDay == "2026-10-13", "failure does not interrupt browsing")
request = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: request, current: pro, date: now)
popup.update(snapshot(), allowResize: false)
expect(popup.state.snapshot.remainingGB != nil, "recovery restores current estimate")
var gap = tracker.state.billing[pro.key]!.values.first!; gap.hasGap = true
tracker.state.billing[pro.key]![gap.period.key] = gap
expect(snapshot().remainingGB == nil && snapshot().quotaNotice.contains("缺口"), "sampling gap never displays a confident balance")
try tracker.sampleBilling(info, key: pro.key, config: config, date: now, calibratedGB: 210)
expect(snapshot().remainingGB == 0 && snapshot().remainingPercent == 0, "over-quota use clamps progress and balance to zero")
var noCounts = info; noCounts.monthlyRx = nil
request = router.begin(network: pro, gateway: pro.gateway)
router.accept(noCounts, request: request, current: pro, date: now)
expect(snapshot().remainingGB == nil, "missing current device counts cannot retain estimate")
router.invalidate()
tracker.sample(context: home, counters: InterfaceCounters(rx: 1, tx: 1), uptime: 300, date: now, maxGap: 30)
tracker.setLabel("F50 Pro", for: home.key)
popup.update(snapshot(), allowResize: false)
expect(popup.state.snapshot.phase == .hidden && popup.state.snapshot.details.isEmpty
       && popup.state.snapshot.remainingGB == nil && popup.state.snapshot.warnings.isEmpty, "home router with Pro alias hides the device card and warnings")
expect(popup.state.selectedDay == "2026-10-13", "network switch retains all-network monthly browsing")
expect(popup.state.snapshot.days[12].hasF50 && popup.state.snapshot.days[11].f50Total == 0,
       "other networks keep Pro history visible and a user alias cannot manufacture Pro identity")
let zeros = [DashboardSnapshot.Day(id: "zero", total: 0, isToday: false), DashboardSnapshot.Day(id: "unknown", total: nil, isToday: true)]
expect(zeros[0].detail.contains("0 B") && zeros[1].detail.contains("未记录"), "zero and unknown have distinct descriptions")
expect(DashboardSnapshot.Rate(nil).value == "—" && DashboardSnapshot.Rate(.nan).value == "—", "invalid rates use unknown, not zero")
expect(DashboardSnapshot.Rate(0).value == "0", "valid idle rate remains zero")

// 原生菜单测试使用生产视图与系统子菜单，不写用户运行数据。
let nativeMenu = NSMenu(); nativeMenu.autoenablesItems = false
nativeMenu.addItem(popup.item)
let detailsItem = NSMenuItem(title: "详细信息", action: nil, keyEquivalent: "")
detailsItem.submenu = NSMenu(); detailsItem.submenu!.addItem(withTitle: "fixture firmware", action: nil, keyEquivalent: "")
nativeMenu.addItem(detailsItem)
let historyItem = NSMenuItem(title: "历史用量", action: nil, keyEquivalent: "")
historyItem.submenu = NSMenu(); historyItem.submenu!.addItem(withTitle: "fixture history", action: nil, keyEquivalent: "")
nativeMenu.addItem(historyItem)
nativeMenu.addItem(.separator())
for name in ["设置…", "刷新", "退出"] { nativeMenu.addItem(withTitle: name, action: nil, keyEquivalent: "") }
expect(nativeMenu.items.first?.view === host && nativeMenu.items.filter { $0.submenu != nil }.count == 2,
       "card and native arrow submenus share one NSMenu")
popup.update(first, allowResize: true)
let treeBefore = nativeMenu.items.map(ObjectIdentifier.init)
for _ in 1...100 { popup.update(first, allowResize: false) }
expect(nativeMenu.items.map(ObjectIdentifier.init) == treeBefore, "native menu entries survive card refreshes")

if CommandLine.arguments.contains("--render") {
    let output = URL(fileURLWithPath: "build/tests/native-card", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 360, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let material = NSVisualEffectView()
    material.material = .menu; material.blendingMode = .behindWindow; material.state = .active
    window.isOpaque = false; window.backgroundColor = .clear
    window.contentView = material; material.addSubview(host)
    window.orderFrontRegardless()
    func capture(_ name: String, _ appearance: NSAppearance.Name, _ data: DashboardSnapshot) throws {
        popup.update(data, allowResize: true)
        window.setContentSize(host.frame.size); window.appearance = NSAppearance(named: appearance)
        host.frame.origin = .zero
        window.display(); RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        expect(host.frame.height > 200 && host.frame.height < 600, "card fits content without a scroll viewport")
        expect(scrollViews(host) == 0, "rendered hierarchy has no internal scrollbar")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
        let rect = popup.state.chartRect
        expect(rect.width > 300 && rect.height > 30, "month grid exposes real geometry for menu hover inspection: \(rect)")
        expect(popup.state.dayRects.count == data.days.count, "every calendar square has a native hover region: \(popup.state.dayRects.count)/\(data.days.count), missing \(data.days.filter { popup.state.dayRects[$0.id] == nil }.map(\.id))")
        for day in data.days {
            let square = popup.state.dayRects[day.id]!
            host.inspect(at: NSPoint(x: square.midX, y: square.midY))
            expect(popup.state.selectedDay == day.id, "native hit testing maps both rows to the exact calendar date")
            expect(popup.state.hoveredDay?.detail == day.detail && host.frame.height == popup.state.fixedHeight,
                   "hover reveals only the selected detail without changing menu geometry")
        }
        let firstSquare = popup.state.dayRects[data.days[0].id]!
        host.inspect(at: NSPoint(x: firstSquare.maxX + 2, y: firstSquare.midY))
        expect(popup.state.selectedDay == nil, "gaps between squares do not select an adjacent date")
        host.inspect(at: .zero)
        expect(popup.state.selectedDay == nil && popup.state.hoveredDay == nil, "leaving the chart removes the transient detail")
    }
    popup.state.selectedDay = nil
    try capture("light", .aqua, first)
    try capture("dark", .darkAqua, first)
    popup.state.selectedDay = "2026-10-13"
    try capture("hover-f50", .aqua, first)
    popup.state.selectedDay = "2026-10-12"
    try capture("hover-other", .aqua, first)
    var unavailable = first; unavailable.phase = .unavailable; unavailable.remainingGB = nil; unavailable.remainingPercent = nil
    unavailable.usedBytes = nil; unavailable.signal = ""; unavailable.quotaNotice = "设备数据暂不可用，等待下次刷新"; unavailable.details = []
    try capture("unavailable", .aqua, unavailable)
    try capture("home", .aqua, snapshot())
    let february = DashboardSnapshot.make(tracker: TrafficTracker(), router: RouterState(), config: config,
        date: ISO8601DateFormatter().date(from: "2024-02-18T09:00:00+08:00")!)
    try capture("february", .aqua, february)
    try capture("light", .aqua, first)
    window.orderOut(nil)
    host.removeFromSuperview()
    popup.item.view = nil; popup.item.view = host
    // 使用真正 NSMenu 的跟踪循环和窗口渲染，而非把卡片放进弹出面板。
    popup.state.selectedDay = CommandLine.arguments.contains("--hover-menu") ? "2026-10-13" : nil
    nativeMenu.appearance = NSAppearance(named: .aqua)
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        var capturedMenu = false
        var timerFired = false
        let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
            timerFired = true
            defer { nativeMenu.cancelTracking() }
            guard let view = host.window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            let windows = NSApp.windows.map { ["type": String(describing: type(of: $0)), "frame": NSStringFromRect($0.frame), "visible": String($0.isVisible), "parent": $0.parent.map { String(describing: type(of: $0)) } ?? "nil"] }
            try? JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("windows.json"))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let name = CommandLine.arguments.contains("--hover-menu") ? "native-menu-hover.png" : "native-menu.png"
                try? data.write(to: output.appendingPathComponent(name)); capturedMenu = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let shown = nativeMenu.popUp(positioning: nil, at: NSPoint(x: 150, y: (NSScreen.main?.visibleFrame.maxY ?? 800) - 12), in: nil)
        expect(capturedMenu, "system menu capture: shown=\(shown), timer=\(timerFired), view=\(String(describing: host.window)), size=\(host.frame.size)")
        print("PASS: \(checks) native card and rendering checks, including an actual NSMenu tracking window")
        exit(0)
    }
    NSApp.run()

}
print("PASS: \(checks) native card checks, including retained menu objects through 100 refreshes")
