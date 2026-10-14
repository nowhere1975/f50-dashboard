import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let now = Date()
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
try tracker.sampleBilling(info, key: pro.key, config: config, date: now, calibratedGB: 26.07)
var router = RouterState()
let initialRequest = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: initialRequest, current: pro, date: now)

let renderer = MenuRenderer()
let menu = NSMenu()
var created = 0
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
func item(_ entry: MenuEntry) -> NSMenuItem {
    created += 1
    if entry.isSeparator { return .separator() }
    let result = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
    if let children = entry.children {
        let submenu = NSMenu()
        for child in children { submenu.addItem(item(child)) }
        result.submenu = submenu
    }
    return result
}
func identities(_ menu: NSMenu) -> [ObjectIdentifier] {
    [ObjectIdentifier(menu)] + menu.items.flatMap {
        [ObjectIdentifier($0)] + ($0.submenu.map(identities) ?? [])
    }
}
func titles(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
}
func render(_ tracking: Bool, _ date: Date = now, warnings: [String] = []) {
    renderer.update(DashboardMenu.entries(tracker: tracker, router: router, config: config,
        date: date, warnings: warnings), menu: menu, allowStructureChanges: !tracking, makeItem: item)
}
render(false)
let original = identities(menu)
let originalCreated = created
let originalTitles = titles(menu)
let details = menu.items.first { $0.title == "详细信息" }!.submenu!
let history = menu.items.first { $0.title == "历史用量" }!.submenu!
expect(history.items.filter { $0.submenu != nil }.count == 2, "nested history exists")
for index in 1...100 {
    let date = now.addingTimeInterval(Double(index * 2))
    tracker.sample(context: pro, counters: InterfaceCounters(rx: UInt64(1000 + index * 1_000_000), tx: UInt64(100 + index * 10_000)),
                   uptime: Double(index * 2), date: date, maxGap: 30)
    info.monthlyRx! += 1_000_000
    try tracker.sampleBilling(info, key: pro.key, config: config, date: date)
    let request = router.begin(network: pro, gateway: pro.gateway)
    router.accept(info, request: request, current: pro, date: date)
    render(true, date)
    expect(identities(menu) == original, "refresh must retain every NSMenuItem and NSMenu")
}
expect(created == originalCreated, "tracking refresh never allocates replacement items")
expect(titles(menu) != originalTitles, "live values still update")
expect(details.items.contains { $0.title.contains("155") }, "router raw total updates in details")
expect(titles(history).contains { $0.contains(Fmt.bytes(101_000_000)) }, "local history updates during tracking")
// Structural changes while hovering are deferred, without showing removed client data.
info.stations = []
var request = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: request, current: pro, date: now)
render(true, warnings: ["new warning"])
expect(identities(menu) == original, "client removal and warning insertion retain subtree")
expect(!titles(details).contains { $0.contains("aa:bb:cc:dd:ee:ff") }, "removed client MAC clears immediately")
expect(!titles(menu).contains { $0 == "提示：new warning" }, "new warning deferred until reopening")
let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
render(true, nextDay)
expect(identities(menu) == original, "date rollover retains history objects")
// A router failure must clear old quota/raw/WAN numbers even with the structure frozen.
var failure = RouterInfo(); failure.errorMessage = "fixture timeout"
request = router.begin(network: pro, gateway: pro.gateway)
router.accept(failure, request: request, current: pro, date: now)
render(true)
expect(identities(menu) == original, "temporary failure does not destroy hovered menus")
expect(!titles(menu).contains { $0.contains("%") || $0.contains("估算剩余") || $0.contains("10.2.3.4") }, "failure clears stale values")
request = router.begin(network: pro, gateway: pro.gateway)
router.accept(info, request: request, current: pro, date: now)
render(true)
expect(identities(menu) == original, "recovery retains hovered menus")
expect(titles(menu).contains { $0.contains("估算剩余") }, "recovery restores live quota text")
render(false, nextDay, warnings: ["new warning"])
expect(titles(menu).contains { $0 == "提示：new warning" }, "reopening applies pending structure")
expect(!titles(menu).contains { $0.contains("接入设备列表已变化") }, "reopening removes placeholder client")
let reopened = identities(menu)
render(false, nextDay, warnings: ["new warning"])
expect(identities(menu) == reopened, "same structure is reused even when closed")
// Separate networks can share a name; history updates must target the network key.
tracker.sample(context: home, counters: InterfaceCounters(rx: 1, tx: 1), uptime: 300, date: now, maxGap: 30)
tracker.setLabel("F50 Pro", for: home.key)
router.invalidate()
render(false)
expect(!titles(menu).contains { $0 == "详细信息" }, "other networks hide device details on opening")
expect(titles(menu).contains { $0 == "历史用量" }, "history remains available on other networks")
print("PASS: \(checks) native menu checks; 100 tracking refreshes preserve every menu object")
