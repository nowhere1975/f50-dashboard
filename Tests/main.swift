import Foundation

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    checks += 1
    if (try? condition()) != true { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
func rejects(_ json: String) -> Bool {
    (try? JSONDecoder().decode(Config.self, from: Data(json.utf8))) == nil
}
func parse(_ json: String) -> RouterInfo { RouterClient.parse(Data(json.utf8)) }
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("f50-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let valid = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":123,"flux_monthly_rx_bytes":"456"}"#)
expect(valid.isF50 && valid.monthlyTotal == 579, "numeric and string counters")
let zero = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":0,"flux_monthly_rx_bytes":0}"#)
expect(zero.isF50 && zero.monthlyTotal == 0 && !zero.usedFields.isEmpty, "zero is valid")
let primary = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":0,"monthly_tx_bytes":999,"flux_monthly_rx_bytes":0}"#)
expect(primary.monthlyTotal == 0, "primary zero does not fall through")
expect(parse(#"{"wa_inner_version":"F50ProV1","station_list":[]}"#).monthlyTotal == nil, "missing fields are unknown")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":123}"#).monthlyTotal == nil, "partial counters are unknown")
expect(!parse(#"{"wa_inner_version":"MF79","station_list":[]}"#).isF50, "other ZTE model rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":true,"flux_monthly_rx_bytes":0}"#).monthlyTotal == nil, "boolean rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":-1,"flux_monthly_rx_bytes":0}"#).monthlyTotal == nil, "negative rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":"18446744073709551615","flux_monthly_rx_bytes":1}"#).monthlyTotal == nil, "sum overflow rejected")
expect(!parse("<html>404</html>").responded, "invalid response rejected")
expect(RouterClient.url(gateway: "192.168.0.1") != nil, "IPv4 URL")
expect(RouterClient.url(gateway: "[::1]:8080") != nil, "IPv6 URL")
expect(RouterClient.url(gateway: "host/path") == nil && RouterClient.url(gateway: "user@host") == nil, "invalid management address")
expect(rejects(#"{"quotaGB":0}"#), "zero quota rejected")
expect(rejects(#"{"quotaGB":-100}"#), "negative quota rejected")
expect(rejects(#"{"localPollSec":0}"#), "zero interval rejected")
expect(rejects(#"{"routerPollSec":-2}"#), "negative interval rejected")
expect(rejects(#"{"quotaGB":"oops"}"#), "type mismatch rejected")
expect((try? JSONDecoder().decode(Config.self, from: Data("{}".utf8)))?.quotaGB == 100, "missing keys keep defaults")
let configURL = temp.appendingPathComponent("config.json")
let corrupt = Data("{invalid-json".utf8)
try corrupt.write(to: configURL)
var fallback = Config(); fallback.quotaGB = 250
let loaded = Config.read(at: configURL, fallback: fallback)
expect(loaded.warning != nil && loaded.config.quotaGB == 250, "bad config keeps last valid values")
expect(try Data(contentsOf: configURL) == corrupt, "bad config file not overwritten")
try Data(#"{"quotaGB":100,"extensionKey":"keep-me"}"#.utf8).write(to: configURL)
try fallback.save(to: configURL)
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
expect(object["extensionKey"] as? String == "keep-me", "settings preserve extension keys")

let f50 = NetworkContext(interface: "en0", gateway: "192.168.0.1", dns: "192.168.0.1", gatewayMAC: "01:02:03:04:05:06")
let home = NetworkContext(interface: "en7", gateway: "192.168.0.1", dns: "192.168.0.1", gatewayMAC: "11:12:13:14:15:16")
let date = Date(timeIntervalSince1970: 1_700_000_000)
var tracker = TrafficTracker()
func sample(_ context: NetworkContext, _ rx: UInt64?, _ time: Double) {
    tracker.sample(context: context, counters: rx.map { InterfaceCounters(rx: $0, tx: $0 / 10) },
                   uptime: time, date: date.addingTimeInterval(time), maxGap: 30)
}
sample(f50, 1_000_000, 0)
sample(f50, 1_000_100, 2)
expect(tracker.state.buckets[f50.key]?.rx == 100, "normal delta")
expect(tracker.rateRx == 50, "rate uses elapsed uptime")
sample(home, 9_000_000_000, 4)
expect(tracker.state.buckets[home.key]?.rx == 0, "interface switch has no historical spike")
sample(home, 9_000_000_200, 6)
expect(tracker.state.buckets[home.key]?.rx == 200, "new interface subsequent delta")
sample(home, nil, 8)
expect(tracker.rateRx == 0, "read failure clears rate")
sample(home, 9_000_000_210, 10)
expect(tracker.state.buckets[home.key]?.rx == 200, "read recovery does not recount history")
sample(home, 9_000_000_220, 12)
expect(tracker.state.buckets[home.key]?.rx == 210, "recovery next delta")
sample(home, 10, 14)
expect(tracker.state.buckets[home.key]?.rx == 210 && tracker.rateRx == 0, "counter reset skips historical window")
sample(home, 20, 16)
expect(tracker.state.buckets[home.key]?.rx == 220, "reset next delta")
sample(home, 999_999, 1000)
expect(tracker.state.buckets[home.key]?.rx == 220, "long sleep gap creates baseline")
expect(tracker.connectedSince == date.addingTimeInterval(4), "connection time separate from bucket age")
expect(tracker.state.daily[TrafficTracker.dayKey(date)]?[f50.key]?.rx == 100, "daily delta recorded")
expect(f50.key != home.key, "same IP and DNS but distinct routers")
expect(SysInfo.normalizeMAC("a:b:c:d:e:f") == "0a:0b:0c:0d:0e:0f", "MAC normalization")
expect(SysInfo.normalizeMAC("invalid") == "", "invalid MAC ignored")

var router = RouterState()
let old = router.begin(network: f50, gateway: f50.gateway)
router.invalidate()
let new = router.begin(network: home, gateway: home.gateway)
expect(!router.accept(valid, request: old, current: home, date: date), "late old-network response rejected")
expect(router.info == nil, "late response cannot populate snapshot")
expect(router.accept(valid, request: new, current: home, date: date), "current response accepted")
let superseded = router.begin(network: home, gateway: home.gateway)
_ = router.begin(network: home, gateway: home.gateway)
expect(!router.accept(valid, request: superseded, current: home, date: date), "superseded refresh rejected")
router.invalidate()
expect(router.info == nil && router.updatedAt == nil, "network change clears old display")

let stateURL = temp.appendingPathComponent("state.json")
let store = StateStore(url: stateURL)
_ = store.load()
try store.save(tracker.state)
var later = tracker.state
later.buckets[f50.key]!.rx += 500
try store.save(later)
expect(FileManager.default.fileExists(atPath: store.backupURL.path), "previous valid state backed up")
expect(try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL)).buckets[f50.key]?.rx == 600, "current state saved")
try corrupt.write(to: stateURL)
let recovery = StateStore(url: stateURL)
let restored = recovery.load()
expect(restored.warning != nil && restored.state.buckets[f50.key]?.rx == 100, "corrupt primary recovers backup")
let preserved = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("state.corrupt.") }
expect(preserved.count == 1, "corrupt evidence preserved")
try recovery.save(restored.state)
expect(try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: stateURL)).buckets[f50.key]?.rx == 100, "recovered state repaired")
let legacy = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"buckets":{"f50":{"rx":42,"tx":8,"firstSeen":0,"label":"F50"}}}"#.utf8))
expect(legacy.buckets["f50"]?.rx == 42 && legacy.daily.isEmpty, "legacy history preserved")
expect((try? JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))) == nil, "incomplete state rejected")
var alert = TrafficTracker()
expect(alert.quotaAlert(total: 80_000_000_000, quotaGB: 100, key: "f50") == 80, "80 percent alert")
expect(alert.quotaAlert(total: 81_000_000_000, quotaGB: 100, key: "f50") == nil, "alert not repeated")
expect(alert.quotaAlert(total: 95_000_000_000, quotaGB: 100, key: "f50") == 90, "90 percent alert")
expect(alert.quotaAlert(total: 100_000_000_000, quotaGB: 100, key: "f50") == 100, "100 percent alert")
_ = alert.quotaAlert(total: 0, quotaGB: 100, key: "f50")
expect(alert.quotaAlert(total: 85_000_000_000, quotaGB: 100, key: "f50") == 80, "counter cycle resets alerts")
print("PASS: \(checks) Swift regression checks")
