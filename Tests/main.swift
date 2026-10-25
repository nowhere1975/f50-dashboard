import Foundation

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) {
    checks += 1
    if (try? condition()) != true { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
func rejects(_ json: String) -> Bool {
    (try? JSONDecoder().decode(Config.self, from: Data(json.utf8))) == nil
}
func parse(_ json: String) -> RouterInfo { RouterAdapterRegistry.builtIn.decode(Data(json.utf8), using: F50ProAdapter()) }
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("f50-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let valid = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":123,"flux_monthly_rx_bytes":"456"}"#)
expect(valid.isSupported && valid.counterTotal == 579, "numeric and string counters")
let zero = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":0,"flux_monthly_rx_bytes":0}"#)
expect(zero.isSupported && zero.counterTotal == 0 && !zero.counterSource.isEmpty, "zero is valid")
let primary = parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":0,"monthly_tx_bytes":999,"flux_monthly_rx_bytes":0}"#)
expect(primary.counterTotal == 0, "primary zero does not fall through")
expect(parse(#"{"wa_inner_version":"F50ProV1","station_list":[]}"#).counterTotal == nil, "missing fields are unknown")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":123}"#).counterTotal == nil, "partial counters are unknown")
expect(!parse(#"{"wa_inner_version":"MF79","station_list":[]}"#).isSupported, "other ZTE model rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":true,"flux_monthly_rx_bytes":0}"#).counterTotal == nil, "boolean rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":-1,"flux_monthly_rx_bytes":0}"#).counterTotal == nil, "negative rejected")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_monthly_tx_bytes":"18446744073709551615","flux_monthly_rx_bytes":1}"#).counterTotal == nil, "sum overflow rejected")
expect(!parse("<html>404</html>").responded, "invalid response rejected")
expect(RouterAddress.components("192.168.0.1") != nil, "IPv4 URL")
expect(RouterAddress.components("[::1]:8080") != nil, "IPv6 URL")
expect(RouterAddress.components("host/path") == nil && RouterAddress.components("user@host") == nil, "invalid management address")
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

let ipv4State: [String: Any] = ["InterfaceName": "en0", "Addresses": ["192.168.0.100"], "Router": "192.168.0.1"]
expect(SysInfo.localIPv4(ipv4State, interface: "en0") == "192.168.0.100", "local IP comes from Addresses, not Router")
expect(SysInfo.localIPv4(ipv4State, interface: "en7").isEmpty, "manual interface cannot borrow another interface's address")
expect(SysInfo.localIPv4(["InterfaceName": "en0", "Router": "192.168.0.1"], interface: "en0").isEmpty,
       "missing address never falls back to gateway")
expect(SysInfo.localIPv4([:], interface: "").isEmpty, "offline network has no local address")

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

var migration = TrafficTracker()
migration.state = legacy
migration.state.buckets[f50.key] = Bucket(rx: 100, tx: 20, firstSeen: date, label: "F50 Pro")
migration.state.buckets[home.key] = Bucket(rx: 7, tx: 3, firstSeen: date, label: "Home")
migration.state.daily["2026-10-13"] = ["f50": Usage(rx: 4, tx: 2), f50.key: Usage(rx: 10, tx: 5)]
migration.state.alerts["f50"] = AlertRecord(lastTotal: 80, notified: [80])
let originalHome = migration.state.buckets[home.key]
let rawArchive = try store.archiveBeforeF50Merge(migration.state)
expect(try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: rawArchive)).buckets["f50"]?.rx == 42, "independent archive keeps original records")
expect(try migration.mergeLegacyF50(), "known single F50 merges even while offline")
expect(migration.state.buckets["f50"] == nil, "no separate legacy entry")
expect(migration.state.buckets[f50.key]?.rx == 142 && migration.state.buckets[f50.key]?.tx == 28, "both counters conserved")
expect(migration.state.buckets[f50.key]?.firstSeen == Date(timeIntervalSinceReferenceDate: 0), "earliest statistics date kept")
expect(migration.state.buckets[f50.key]?.label == "F50 Pro", "unified device name")
expect(migration.state.buckets[home.key] == originalHome, "other network unchanged")
expect(migration.state.daily["2026-10-13"]?[f50.key] == Usage(rx: 14, tx: 7), "existing daily records conserved")
expect(migration.state.daily["2026-10-13"]?["f50"] == nil, "daily records use unified identity")
expect(migration.state.alerts[f50.key]?.notified == [80] && migration.state.alerts["f50"] == nil, "alert record transferred")
expect(try !migration.mergeLegacyF50(), "migration is idempotent")
try store.save(migration.state)
var reloadedMigration = TrafficTracker()
reloadedMigration.state = StateStore(url: stateURL).load().state
expect(try !reloadedMigration.mergeLegacyF50() && reloadedMigration.state.buckets[f50.key]?.rx == 142, "restart never adds legacy twice")
expect(try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: rawArchive)).buckets["f50"]?.rx == 42, "periodic saves do not replace raw archive")
var unidentified = TrafficTracker()
unidentified.state = legacy
unidentified.state.buckets[home.key] = Bucket(label: "Home")
expect(try !unidentified.mergeLegacyF50() && unidentified.state.buckets["f50"]?.rx == 42, "ordinary current network cannot receive F50 history")
unidentified.state.buckets[f50.key] = Bucket(label: "F50 Pro")
unidentified.state.buckets[home.key]!.label = "F50 Pro"
expect(try !unidentified.mergeLegacyF50(), "multiple F50 devices are not mixed")
var noDailyHistory = TrafficTracker()
noDailyHistory.state = legacy
noDailyHistory.state.buckets[f50.key] = Bucket(label: "F50 Pro")
expect(try noDailyHistory.mergeLegacyF50() && noDailyHistory.state.daily.isEmpty, "undated usage not invented as daily history")
var overflowMigration = TrafficTracker()
overflowMigration.state = legacy
overflowMigration.state.buckets[f50.key] = Bucket(label: "F50 Pro")
overflowMigration.state.daily["day"] = ["f50": Usage(rx: UInt64.max), f50.key: Usage(rx: 1)]
do {
    _ = try overflowMigration.mergeLegacyF50()
    expect(false, "overflow must reject migration")
} catch {
    expect(overflowMigration.state.buckets["f50"]?.rx == 42 && overflowMigration.state.buckets[f50.key]?.rx == 0,
           "failed migration changes neither record")
}

let iso = ISO8601DateFormatter()
func at(_ text: String) -> Date { iso.date(from: text)! }
let october = at("2026-10-14T02:00:00+08:00")
func period(_ date: Date, _ day: Int) -> BillingPeriod {
    BillingPeriod.containing(date, resetDay: day, timeZoneID: "Asia/Shanghai")
}
expect(period(october, 1).label == "2026-10-01 至 2026-10-31", "calendar month is explicit")
expect(period(october, 15).label == "2026-09-15 至 2026-10-14", "non-first billing day")
expect(period(at("2026-10-15T00:00:00+08:00"), 15).label == "2026-10-15 至 2026-11-14", "exact boundary starts new cycle")
expect(period(at("2026-02-28T00:00:00+08:00"), 31).label == "2026-02-28 至 2026-03-30", "short month clamps without shifting following month")
expect(period(at("2024-02-29T00:00:00+08:00"), 31).label == "2024-02-29 至 2024-03-30", "leap month")
expect(period(at("2027-01-01T00:00:00+08:00"), 15).label == "2026-12-15 至 2027-01-14", "year rollover")
expect(period(at("2026-10-31T16:00:00Z"), 1).label == "2026-11-01 至 2026-11-30", "billing timezone independent of machine timezone")
expect(rejects(#"{"billingCycleDay":0}"#) && rejects(#"{"billingCycleDay":32}"#), "billing day bounds")
expect(rejects(#"{"billingTimeZone":"invalid/timezone"}"#), "invalid billing timezone rejected")
expect(Config().billingCycleDay == nil, "old config does not invent carrier period")
var monthlyConfig = Config(); monthlyConfig.billingCycleDay = 1
try monthlyConfig.save(to: configURL)
try Config().save(to: configURL)
expect((try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))).billingCycleDay == nil, "clearing billing day removes saved value")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_auto_clear_flow_data_switch":"on","flux_clear_date":"1"}"#).autoClearDay == 1, "device automatic reset setting parsed")
expect(parse(#"{"wa_inner_version":"F50ProV1","flux_auto_clear_flow_data_switch":"off","flux_clear_date":"1"}"#).autoClearDay == nil, "disabled reset not shown as active")

func reading(_ rx: UInt64, _ tx: UInt64, fields: String = "same-fields") -> RouterInfo {
    var info = RouterInfo(); info.adapter = F50ProAdapter().descriptor; info.responded = true; info.model = "F50ProV1"
    info.counterRx = rx; info.counterTx = tx; info.counterSource = fields
    return info
}
var monthly = TrafficTracker()
try monthly.sampleBilling(reading(5_000_000_000, 2_000_000_000), key: f50.key, config: Config(), date: october)
expect(monthly.state.billing.isEmpty, "unset cycle cannot report monthly percentage")
try monthly.sampleBilling(reading(5_000_000_000, 2_000_000_000), key: f50.key, config: monthlyConfig, date: october)
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 0, "first raw counter not assigned to unknown monthly history")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.canEstimateQuota == false, "unknown initial usage suppresses quota")
try monthly.sampleBilling(reading(5_000_000_100, 2_000_000_020), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(30))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 120, "both directions accumulated")
try monthly.sampleBilling(reading(5_000_000_100, 2_000_000_020), key: f50.key, config: monthlyConfig,
                          date: october.addingTimeInterval(30), calibratedGB: 7)
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 7_000_000_000, "carrier calibration replaces partial total")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.canEstimateQuota == true, "calibrated cycle can estimate quota")
let billingURL = temp.appendingPathComponent("billing-state.json")
let billingStore = StateStore(url: billingURL)
try billingStore.save(monthly.state)
monthly.state = billingStore.load().state
try monthly.sampleBilling(reading(5_000_000_100, 2_000_000_020), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(60))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 7_000_000_000, "restart never recounts old device counter")
try monthly.sampleBilling(reading(50, 2_000_000_040), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(90))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 7_000_000_070, "one-sided reset preserves monthly total and adds post-reset bytes")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.hasGap == true, "reset warns of unobservable traffic before clearing")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.canEstimateQuota == false, "reset cannot fabricate exact monthly remainder")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.period == period(october, 1), "device reset does not change billing cycle")
try monthly.sampleBilling(reading(80, 2_000_000_050), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(120))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 7_000_000_110, "sampling continues after reset")
try monthly.sampleBilling(reading(90, 2_000_000_060, fields: "new-fields"), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(150))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 7_000_000_110, "field-source change never creates historical spike")
try monthly.sampleBilling(reading(100, 2_000_000_070, fields: "new-fields"), key: f50.key, config: monthlyConfig,
                          date: october.addingTimeInterval(180), calibratedGB: 8)
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.canEstimateQuota == true, "new carrier calibration repairs unknown interval")
try monthly.sampleBilling(reading(200, 2_000_000_170, fields: "new-fields"), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(400))
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.total == 8_000_000_200, "long gap retains observed delta")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: october)?.canEstimateQuota == false, "long gap suppresses precise remainder")
let november = at("2026-11-01T00:00:05+08:00")
try monthly.sampleBilling(reading(9_000_000_000, 4_000_000_000), key: f50.key, config: monthlyConfig, date: november)
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: november)?.total == 0, "new calendar cycle cannot import previous-month raw count")
expect(monthly.state.billing[f50.key]?.count == 2, "previous billing cycle preserved")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: november)?.canEstimateQuota == false, "new cycle needs known initial usage")
try monthly.sampleBilling(reading(0, 0), key: home.key, config: monthlyConfig, date: november, calibratedGB: 0)
expect(monthly.billingUsage(key: home.key, config: monthlyConfig, date: november)?.canEstimateQuota == true, "zero carrier usage is valid")
expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: november)?.calibratedAt == nil, "different router calibrations remain isolated")
let beforeInvalid = monthly.billingUsage(key: f50.key, config: monthlyConfig, date: november)?.total
do {
    try monthly.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: november, calibratedGB: -1)
    expect(false, "negative carrier calibration must fail")
} catch { expect(monthly.billingUsage(key: f50.key, config: monthlyConfig, date: november)?.total == beforeInvalid, "invalid calibration leaves state untouched") }

var alert = TrafficTracker()
try alert.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: october, calibratedGB: 80)
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == 80, "monthly 80 percent alert")
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == nil, "monthly alert not repeated")
try alert.sampleBilling(reading(1, 1), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(30), calibratedGB: 95)
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == 90, "monthly 90 percent alert")
try alert.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(60))
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == nil, "raw counter reset neither repeats nor enables quota alerts")
try alert.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(90), calibratedGB: 95)
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == nil, "same-cycle recalibration preserves notified thresholds")
try alert.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: october.addingTimeInterval(120), calibratedGB: 100)
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: october) == 100, "monthly 100 percent alert")
try alert.sampleBilling(reading(0, 0), key: f50.key, config: monthlyConfig, date: november, calibratedGB: 85)
expect(alert.billingQuotaAlert(key: f50.key, config: monthlyConfig, date: november) == 80, "only new calendar period resets notification thresholds")
try billingStore.save(alert.state)
expect(billingStore.load().state.billing[f50.key]?.count == 2, "billing records and alerts survive disk round trip")
var actualPlan = Config(); actualPlan.quotaGB = 200; actualPlan.billingCycleDay = 1
var actualTracker = TrafficTracker()
try actualTracker.sampleBilling(reading(28_000_000, 27_000_000), key: f50.key, config: actualPlan,
                                date: october, calibratedGB: actualPlan.quotaGB - 173.93)
let actualUsage = actualTracker.billingUsage(key: f50.key, config: actualPlan, date: october)!
expect(actualUsage.total == 26_070_000_000 && actualUsage.canEstimateQuota, "200 GB plan with 173.93 remaining calibrates to 26.07 GB")
expect(String(format: "%.2f", Double(actualUsage.total) / Fmt.giga / actualPlan.quotaGB * 100) == "13.04", "actual plan percentage is 13.04 rather than device 0.05")
var overflowBilling = actualTracker
overflowBilling.state.billing[f50.key]![actualUsage.period.key]!.total = UInt64.max - 5
do {
    try overflowBilling.sampleBilling(reading(28_000_010, 27_000_000), key: f50.key, config: actualPlan, date: october.addingTimeInterval(30))
    expect(false, "billing overflow must fail")
} catch { expect(overflowBilling.billingUsage(key: f50.key, config: actualPlan, date: october)?.total == UInt64.max - 5, "overflow preserves original monthly record") }
let stateJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actualTracker.state)) as! [String: Any]
var corruptBilling = stateJSON
var corruptRecords = corruptBilling["billing"] as! [String: Any]
var corruptDevice = corruptRecords[f50.key] as! [String: Any]
var corruptRecord = corruptDevice[actualUsage.period.key] as! [String: Any]
var corruptPeriod = corruptRecord["period"] as! [String: Any]
corruptPeriod["timeZoneID"] = "invalid/timezone"
corruptRecord["period"] = corruptPeriod; corruptDevice[actualUsage.period.key] = corruptRecord
corruptRecords[f50.key] = corruptDevice; corruptBilling["billing"] = corruptRecords
expect((try? JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: corruptBilling))) == nil,
       "corrupt billing timezone rejected before period rendering")
expect(valid.isSupported && F50ProAdapter().matches(model: "F50 Pro V1"), "F50 Pro model variants recognized")
expect(!F50ProAdapter().matches(model: "F50V1") && !F50ProAdapter().matches(model: "MF79"), "other router models cannot open Pro module")
expect(parse(#"{"wa_inner_version":"F50ProV1","station_list":[]}"#).hasStationList,
       "explicit empty client list is valid")
expect(!valid.hasStationList, "missing client list is unknown rather than zero")

var uiTracker = actualTracker
uiTracker.sample(context: f50, counters: InterfaceCounters(rx: 1000, tx: 100), uptime: 0, date: october, maxGap: 30)
uiTracker.setLabel("F50 Pro", for: f50.key)
uiTracker.state.buckets[home.key] = Bucket(rx: 10_000, tx: 1000, firstSeen: october, label: "Home")
var uiInfo = reading(28_000_000, 27_000_000)
uiInfo.netType = "LTE"; uiInfo.sigBar = "5"; uiInfo.rsrp = "-92"; uiInfo.wanIP = "10.2.3.4"
uiInfo.hasStationList = true; uiInfo.stations = [(mac: "aa:bb:cc:dd:ee:ff", ip: "192.168.0.101")]
uiTracker.rememberDevice(uiInfo, key: f50.key, date: october)
let knownPro = uiTracker.state.devices[f50.key]!
var uiRouter = RouterState()
expect(uiRouter.moduleState(current: home, knownDevice: nil) == .hidden, "ordinary network starts without device module")
let initialProbe = uiRouter.begin(network: home, gateway: home.gateway)
expect(uiRouter.moduleState(current: home, knownDevice: nil) == .hidden, "unknown-router probing stays invisible")
let homeInfo = parse(#"{"wa_inner_version":"MF79","monthly_rx_bytes":1,"monthly_tx_bytes":1}"#)
_ = uiRouter.accept(homeInfo, request: initialProbe, current: home, date: october)
expect(uiRouter.moduleState(current: home, knownDevice: knownPro) == .hidden, "actual non-Pro model overrides mismatched stored device")
uiRouter.invalidate()
let f50Probe = uiRouter.begin(network: f50, gateway: f50.gateway)
_ = uiRouter.accept(uiInfo, request: f50Probe, current: f50, date: october)
expect(uiRouter.moduleState(current: f50, knownDevice: knownPro) == .ready, "verified current F50 Pro opens module")
func allEntries(_ entries: [MenuEntry]) -> [MenuEntry] { entries.flatMap { [$0] + allEntries($0.children ?? []) } }
let connectedEntries = DashboardMenu.entries(tracker: uiTracker, router: uiRouter, config: actualPlan, date: october)
let connectedTitles = connectedEntries.map(\.title)
expect(connectedTitles.contains("F50 Pro") && connectedTitles.contains("历史用量"), "connected layout has Pro and history sections")
expect(connectedTitles.first?.hasPrefix("实时速率") == true && connectedTitles.contains { $0.hasPrefix("当前网络") }, "rate and network stay on main menu")
expect(connectedTitles.contains { $0.contains("13.04%") } && connectedTitles.contains { $0.contains("173.93") }, "monthly calibrated estimate remains on main menu")
expect(!connectedTitles.contains { $0.contains("WAN IP") || $0.contains("aa:bb") || $0.contains("设备原始统计") }, "raw counters and client addresses do not clutter main menu")
let details = connectedEntries.first { $0.title == "详细信息" }!.children!
expect(details.contains { $0.title.contains("设备原始统计") } && details.contains { $0.title.contains("10.2.3.4") }
       && details.contains { $0.title.contains("aa:bb:cc:dd:ee:ff") }, "hardware diagnostics remain available in submenu")
let historyRows = connectedEntries.first { $0.title == "历史用量" }!.children!
expect(historyRows.contains { $0.title == "近七天（当前网络）" } && historyRows.contains { $0.title == "各网络累计" }, "history contains both daily and network totals")
expect(!connectedTitles.contains { $0.hasPrefix("全部网络累计") || $0.hasPrefix("系统网卡累计") }, "history totals moved out of main menu")
expect(connectedEntries.suffix(5).compactMap(\.action).count == 5, "all five menu controls retained")

var failure = RouterInfo(); failure.errorMessage = "测试读取超时"
let failedProbe = uiRouter.begin(network: f50, gateway: f50.gateway)
_ = uiRouter.accept(failure, request: failedProbe, current: f50, date: october.addingTimeInterval(30))
expect(uiRouter.info == nil && uiRouter.moduleState(current: f50, knownDevice: knownPro) == .unavailable,
       "temporary failure keeps identity but clears data")
let failedTitles = DashboardMenu.entries(tracker: uiTracker, router: uiRouter, config: actualPlan, date: october).map(\.title)
expect(failedTitles.contains("F50 Pro") && failedTitles.contains { $0.contains("设备数据暂不可用") }, "failed-read Pro card stays visible")
expect(!failedTitles.contains { $0.contains("13.04%") || $0.contains("估算剩余") }, "failed read cannot show stale quota numbers")
let retryProbe = uiRouter.begin(network: f50, gateway: f50.gateway)
expect(uiRouter.moduleState(current: f50, knownDevice: knownPro) == .loading, "known Pro retry remains visible as loading")
_ = uiRouter.accept(uiInfo, request: retryProbe, current: f50, date: october.addingTimeInterval(60))
expect(uiRouter.moduleState(current: f50, knownDevice: knownPro) == .ready, "successful retry restores Pro data")

let staleProbe = uiRouter.begin(network: f50, gateway: f50.gateway)
uiRouter.invalidate()
uiTracker.sample(context: home, counters: InterfaceCounters(rx: 5000, tx: 500), uptime: 2,
                 date: october.addingTimeInterval(2), maxGap: 30)
_ = uiRouter.begin(network: home, gateway: home.gateway)
expect(uiRouter.moduleState(current: home, knownDevice: knownPro) == .hidden, "same gateway IP with different MAC cannot reuse Pro identity")
expect(!uiRouter.accept(uiInfo, request: staleProbe, current: home, date: october), "late Pro response cannot reopen card after switching")
var aliasConfig = actualPlan; aliasConfig.networkNames[home.key] = "F50 Pro"
let homeEntries = DashboardMenu.entries(tracker: uiTracker, router: uiRouter, config: aliasConfig, date: october,
                                       deviceWarnings: ["测试配额提醒错误"])
expect(!homeEntries.map(\.title).contains("F50 Pro") && !homeEntries.map(\.title).contains("详细信息"), "network alias cannot identify hardware or reveal Pro details")
expect(!homeEntries.map(\.title).contains { $0.contains("路由器用量") || $0.contains("测试配额提醒") || $0.contains("SIM 卡") }, "ordinary network has no Pro placeholders or quota warnings")
expect(allEntries(homeEntries).contains { $0.title.contains("F50 Pro") } && homeEntries.map(\.title).contains("历史用量"), "Pro history is retained while Pro module is hidden")
expect(!homeEntries.first!.isSeparator && !homeEntries.last!.isSeparator
       && !zip(homeEntries, homeEntries.dropFirst()).contains { $0.isSeparator && $1.isSeparator }, "hidden card leaves no empty separator block")

try billingStore.save(uiTracker.state)
let savedDevice = billingStore.load().state.devices[f50.key]
expect(savedDevice?.model == uiInfo.model && savedDevice?.gatewayMAC == f50.gatewayMAC, "model and hardware identity survive restart")
var restartRouter = RouterState()
_ = restartRouter.begin(network: f50, gateway: f50.gateway)
expect(restartRouter.moduleState(current: f50, knownDevice: savedDevice) == .loading, "known Pro can keep card during first read after restart")
let usbPro = NetworkContext(interface: "en15", gateway: f50.gateway, dns: f50.dns, gatewayMAC: f50.gatewayMAC)
expect(restartRouter.moduleState(current: usbPro, knownDevice: savedDevice) == .unavailable, "same Pro MAC across interfaces retains device identity")
let noMAC = NetworkContext(interface: "en0", gateway: f50.gateway, dns: f50.dns, gatewayMAC: "")
expect(restartRouter.moduleState(current: noMAC, knownDevice: savedDevice) == .hidden, "missing MAC cannot reuse stored identity across networks")
let noMACProbe = restartRouter.begin(network: noMAC, gateway: noMAC.gateway)
_ = restartRouter.accept(uiInfo, request: noMACProbe, current: noMAC, date: october)
expect(restartRouter.moduleState(current: noMAC, knownDevice: nil) == .ready, "live model proof works even before MAC is available")
let offline = NetworkContext(interface: "", gateway: "", dns: "", gatewayMAC: f50.gatewayMAC)
expect(restartRouter.moduleState(current: offline, knownDevice: savedDevice) == .hidden, "no active gateway means no Pro module")

var wrongTarget = RouterState()
let wrongProbe = wrongTarget.begin(network: home, gateway: "192.168.1.1")
expect(!wrongProbe.targetsCurrentGateway, "custom management address is not assumed to be current gateway")
_ = wrongTarget.accept(uiInfo, request: wrongProbe, current: home, date: october)
expect(wrongTarget.info == nil && wrongTarget.moduleState(current: home, knownDevice: nil) == .hidden, "reachable Pro elsewhere cannot label current home router")
expect(RouterRequest(serial: 1, network: f50, gateway: f50.gateway + ":8080").targetsCurrentGateway, "current gateway IP with custom port remains valid")

var missingCounts = uiInfo; missingCounts.counterRx = nil; missingCounts.hasStationList = false
uiTracker.sample(context: f50, counters: InterfaceCounters(rx: 6000, tx: 600), uptime: 4, date: october, maxGap: 30)
var partialRouter = RouterState()
let partialProbe = partialRouter.begin(network: f50, gateway: f50.gateway)
_ = partialRouter.accept(missingCounts, request: partialProbe, current: f50, date: october)
let partialTitles = DashboardMenu.entries(tracker: uiTracker, router: partialRouter, config: actualPlan, date: october).map(\.title)
expect(partialTitles.contains("F50 Pro") && !partialTitles.contains { $0.contains("13.04%") || $0.contains("估算剩余") }, "confirmed device with missing counts cannot reuse old monthly estimate")
expect(partialTitles.contains { $0.hasPrefix("接入设备") && $0.contains("暂未取得") }, "missing clients never displayed as zero")
let changedModelProbe = partialRouter.begin(network: f50, gateway: f50.gateway)
_ = partialRouter.accept(homeInfo, request: changedModelProbe, current: f50, date: october)
uiTracker.rememberDevice(homeInfo, key: f50.key, date: october)
expect(uiTracker.state.devices[f50.key] == nil && partialRouter.moduleState(current: f50, knownDevice: savedDevice) == .hidden,
       "definitive different model revokes old Pro proof")
print("PASS: \(checks) Swift regression checks")
