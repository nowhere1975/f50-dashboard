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
tracker.state.daily["2026-10-13"] = [pro.key: Usage(rx: 590_000_000, tx: 3_000_000)]
tracker.state.daily["2026-10-14"] = [pro.key: Usage(rx: 2_300_000_000, tx: 80_000_000)]
let encodedBefore = try JSONEncoder().encode(tracker.state)
var first = snapshot()
first.warnings = []
expect(first.phase == .ready, "confirmed current Pro creates quota card")
expect(abs(first.remainingGB! - 172.97) < 0.000001, "remaining comes from calibrated SIM baseline")
expect(first.usedBytes == 27_030_000_000, "SIM baseline does not use raw router counter")
expect(first.reset == "11 月 1 日重置", "reset uses next cycle boundary in billing timezone")
expect(first.days.count == 7 && first.days.last!.isToday, "chart is chronological and includes current partial day")
expect(first.days.first!.total == nil, "unrecorded dates stay unknown")
expect(first.days.last!.total == 2_380_000_000, "chart uses local daily totals, not SIM calibration")
let encodedAfter = try JSONEncoder().encode(tracker.state)
let beforeObject = try JSONSerialization.jsonObject(with: encodedBefore) as! NSDictionary
let afterObject = try JSONSerialization.jsonObject(with: encodedAfter) as! NSDictionary
expect(beforeObject == afterObject, "building a card never mutates saved statistics")
expect(DailyChartScale(days: first.days).unit == "GB", "daily chart selects correct unit")
expect(DailyChartScale(days: first.days).ceiling == 2.5, "chart scale pads the observed maximum")
expect(DailyChartScale(days: first.days).label(1.25) == "1.25", "axis labels preserve fractional tick precision")
expect(snapshot("config invalid").remainingGB == nil, "invalid config cannot estimate quota")
let popup = DashboardPopover(version: "test") { _ in }
popup.update(first)
let host = popup.popover.contentViewController!
let hostIdentity = ObjectIdentifier(host)
let viewIdentity = ObjectIdentifier(host.view)
popup.state.selectedDay = "2026-10-13"
popup.state.detailsExpanded = true
popup.state.historyExpanded = true
for index in 1...100 {
    tracker.sample(context: pro, counters: InterfaceCounters(rx: UInt64(1000 + index * 10000), tx: UInt64(100 + index * 1000)),
                   uptime: Double(index * 2), date: now.addingTimeInterval(Double(index * 2)), maxGap: 30)
    popup.update(snapshot())
    expect(ObjectIdentifier(popup.popover.contentViewController!) == hostIdentity && ObjectIdentifier(host.view) == viewIdentity,
           "refresh retains the native hosting controller and view")
    expect(popup.state.selectedDay == "2026-10-13" && popup.state.detailsExpanded && popup.state.historyExpanded,
           "refresh retains inspected day and both expanded sections")
}
expect(popup.state.snapshot.download.value != first.download.value, "speed remains live")
var request = router.begin(network: pro, gateway: pro.gateway)
var failure = RouterInfo(); failure.errorMessage = "timeout"
router.accept(failure, request: request, current: pro, date: now)
popup.update(snapshot())
expect(popup.state.snapshot.phase == .unavailable, "temporary failure retains Pro identity")
expect(popup.state.snapshot.remainingGB == nil && popup.state.snapshot.remainingPercent == nil
       && popup.state.snapshot.usedBytes == nil && popup.state.snapshot.signal.isEmpty, "failure clears previous quota and radio values")
expect(!popup.state.snapshot.details.contains { $0.title.contains("10.2.3.4") }, "failure clears previous WAN address")
expect(popup.state.detailsExpanded && popup.state.selectedDay == "2026-10-13", "failure does not interrupt browsing")
request = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: request, current: pro, date: now)
popup.update(snapshot())
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
popup.update(snapshot())
expect(popup.state.snapshot.phase == .hidden && popup.state.snapshot.details.isEmpty
       && popup.state.snapshot.remainingGB == nil && popup.state.snapshot.warnings.isEmpty, "home router with Pro alias hides the device card and warnings")
expect(popup.state.selectedDay == nil && !popup.state.detailsExpanded && !popup.state.historyExpanded, "network switch clears previous-network browsing state")
expect(popup.state.snapshot.days.dropLast().allSatisfy { $0.total == nil }
       && popup.state.snapshot.days.last!.total == 0, "home chart shows its valid zero sample without borrowing Pro daily data")
let zeros = [DashboardSnapshot.Day(id: "zero", total: 0, isToday: false), DashboardSnapshot.Day(id: "unknown", total: nil, isToday: true)]
expect(zeros[0].detail.contains("0 B") && zeros[1].detail.contains("未记录"), "zero and unknown have distinct descriptions")
for total: UInt64 in [0, 2, 3_000, 4_000_000, 5_000_000_000] {
    let scale = DailyChartScale(days: [.init(id: "value", total: total, isToday: true)])
    expect(scale.ceiling > 0 && scale.fraction(total) <= 1 && scale.fraction(total).isFinite, "scale stays finite and bounds small or large values")
}
expect(DashboardSnapshot.Rate(nil).value == "—" && DashboardSnapshot.Rate(.nan).value == "—", "invalid rates use unknown, not zero")
expect(DashboardSnapshot.Rate(0).value == "0", "valid idle rate remains zero")

// 可选渲染使用同一生产视图，便于检查明暗主题与失败状态；不写用户运行数据。
if CommandLine.arguments.contains("--render") {
    let output = URL(fileURLWithPath: "build/tests/dashboard", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: -2000, y: 0, width: 390, height: 740),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = host
    window.orderFrontRegardless()
    func capture(_ name: String, _ appearance: NSAppearance.Name, _ data: DashboardSnapshot, details: Bool = false, height: CGFloat = 740) throws {
        popup.update(data); popup.state.detailsExpanded = details
        popup.state.panelHeight = height
        window.setContentSize(NSSize(width: 390, height: height))
        window.appearance = NSAppearance(named: appearance)
        host.view.frame = NSRect(x: 0, y: 0, width: 390, height: height)
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
        expect(abs(host.view.bounds.height - height) < 1, "native first-open layout retains configured panel height")
        let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds)!
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
    }
    try capture("light", .aqua, first)
    try capture("dark", .darkAqua, first)
    var unavailable = first; unavailable.phase = .unavailable; unavailable.remainingGB = nil; unavailable.remainingPercent = nil
    unavailable.usedBytes = nil; unavailable.signal = ""; unavailable.quotaNotice = "设备数据暂不可用，等待下次刷新"; unavailable.details = []
    try capture("unavailable", .aqua, unavailable)
    try capture("home", .aqua, snapshot(), height: 560)
    try capture("expanded", .aqua, first, details: true)
    try capture("short", .aqua, first, height: 420)
    try capture("light", .aqua, first)
    window.orderOut(nil)
}
print("PASS: \(checks) dashboard checks, including 100 refreshes retaining native view and browsing state")

