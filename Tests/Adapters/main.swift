import Foundation

var checks = 0
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    precondition((try? condition()) == true, message); checks += 1
}
struct FixtureAdapter: RouterAdapter {
    let descriptor = RouterDescriptor(id: "fixture.vendor", name: "Fixture 5G",
        capabilities: [.traffic], counterPolicy: .persistent)
    func matches(model: String) -> Bool { model == "Fixture-5G" }
    func request(gateway: String) -> URLRequest? {
        guard var c = RouterAddress.components(gateway) else { return nil }
        c.path = "/fixture"
        return c.url.map { URLRequest(url: $0) }
    }
    func decode(_ data: Data?) -> RouterInfo {
        var info = RouterInfo()
        guard let data = data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        info.responded = true; info.model = value["model"] as? String ?? ""
        info.counterRx = (value["download"] as? NSNumber)?.uint64Value
        info.counterTx = (value["upload"] as? NSNumber)?.uint64Value
        info.counterSource = "fixture.download+upload"
        // 故意提供未声明的能力，验证注册层不会将其当成模块支持的功能。
        info.netType = "5G"; info.rsrp = "-70"; info.hasStationList = true
        info.stations = [(mac: "01:01:01:01:01:01", ip: "127.0.0.1")]
        return info
    }
}
struct AuthFixtureAdapter: RouterAdapter {
    let descriptor = RouterDescriptor(id: "fixture.auth", name: "Fixture Auth",
        capabilities: [.traffic], counterPolicy: .persistent)
    func matches(model: String) -> Bool { FixtureAdapter().matches(model: model) }
    func request(gateway: String) -> URLRequest? { FixtureAdapter().request(gateway: gateway) }
    func decode(_ data: Data?) -> RouterInfo { FixtureAdapter().decode(data) }
    func prepare(gateway: String, session: URLSession,
                 completion: @escaping (Result<URLRequest, Error>) -> Void) -> (any RouterAdapterTask)? {
        var c = RouterAddress.components(gateway)!; c.path = "/auth"
        let task = session.dataTask(with: c.url!) { _, response, error in
            if let error = error { completion(.failure(error)); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(ConfigError(message: "fixture auth rejected"))); return
            }
            var request = self.request(gateway: gateway)!
            request.setValue("fixture", forHTTPHeaderField: "X-Fixture-Auth")
            completion(.success(request))
        }
        task.resume(); return task
    }
}
let adapter = FixtureAdapter()
let registry = RouterAdapterRegistry(adapters: [F50ProAdapter(), adapter, AuthFixtureAdapter()])
let payload = Data(#"{"model":"Fixture-5G","download":21,"upload":4}"#.utf8)
let reading = registry.decode(payload, using: adapter)
expect(reading.adapter?.id == adapter.descriptor.id && reading.counterTotal == 25, "a second adapter produces normalized counters")
expect(reading.netType.isEmpty && reading.rsrp.isEmpty && reading.stations.isEmpty && !reading.hasStationList,
       "undeclared signal and clients are not exposed")
expect(!registry.decode(Data(#"{"model":"other"}"#.utf8), using: adapter).isSupported, "model mismatch cannot claim a module")
expect(registry.candidates(selection: "none", preferred: nil).isEmpty, "local-only mode disables candidates")
expect(registry.candidates(selection: adapter.descriptor.id, preferred: nil).count == 1, "explicit selection only probes chosen module")
expect(registry.candidates(selection: "auto", preferred: adapter.descriptor.id).first?.descriptor.id == adapter.descriptor.id,
       "known module is probed first")
expect((try? JSONDecoder().decode(Config.self, from: Data("{}".utf8)))?.routerAdapter == "auto", "old settings default to automatic discovery")
expect((try? JSONDecoder().decode(Config.self, from: Data(#"{"routerAdapter":"none"}"#.utf8)))?.routerAdapter == "none", "local-only mode persists")
expect((try? JSONDecoder().decode(Config.self, from: Data(#"{"routerAdapter":"missing"}"#.utf8))) == nil, "missing module gives a configuration error")

final class NetworkFixture {
    let lock = NSLock()
    var paths: [String] = []
    var preparedHeaders: [String] = []
    var slow = false
    let started = DispatchSemaphore(value: 0)
    func reset(slow: Bool = false) { lock.lock(); paths = []; preparedHeaders = []; self.slow = slow; lock.unlock() }
    func response(_ request: URLRequest) -> (Int, Data, TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path; paths.append(path)
        if let header = request.value(forHTTPHeaderField: "X-Fixture-Auth") { preparedHeaders.append(header) }
        if path == "/auth" { started.signal(); return (200, Data(), slow ? 0.3 : 0) }
        started.signal()
        if path == "/fixture" { return (200, payload, slow ? 0.3 : 0) }
        return (200, Data(#"{"wa_inner_version":"MF79"}"#.utf8), 0)
    }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
let network = NetworkFixture()
final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    let lock = NSLock()
    var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, delay) = network.response(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
let sessionConfig = URLSessionConfiguration.ephemeral
sessionConfig.protocolClasses = [FixtureURLProtocol.self]
let session = URLSession(configuration: sessionConfig)
defer { session.invalidateAndCancel() }
func fetch(selection: String = "auto", preferred: String? = nil) -> RouterInfo {
    let done = DispatchSemaphore(value: 0)
    var result = RouterInfo()
    let task = RouterClient.fetch(gateway: "fixture.test", selection: selection, preferred: preferred,
        registry: registry, session: session) { result = $0; done.signal() }
    expect(done.wait(timeout: .now() + 3) == .success, "module discovery completes")
    withExtendedLifetime(task) {}
    return result
}
network.reset()
expect(fetch().adapter?.id == adapter.descriptor.id, "transport advances from unrecognized module to recognized module")
expect(network.requests == ["/goform/goform_get_cmd_process", "/fixture"], "automatic probe order is deterministic")
network.reset()
expect(fetch(selection: adapter.descriptor.id).counterTotal == 25 && network.requests == ["/fixture"], "explicit module avoids other device protocols")
network.reset()
expect(fetch(preferred: adapter.descriptor.id).isSupported && network.requests == ["/fixture"], "cached module avoids redundant discovery")
network.reset()
expect(!fetch(selection: "none").isSupported && network.requests.isEmpty, "disabled router mode performs no network I/O")
network.reset()
expect(!fetch(selection: "zte.f50pro").isSupported, "explicit module cannot mislabel unsupported hardware")
network.reset(slow: true)
// 清空此前请求的启动通知，确保取消的是已在途的请求。
while network.started.wait(timeout: .now()) == .success {}
let cancelledCompletion = DispatchSemaphore(value: 0)
let cancelled = RouterClient.fetch(gateway: "fixture.test", selection: adapter.descriptor.id,
    registry: registry, session: session) { _ in cancelledCompletion.signal() }
expect(network.started.wait(timeout: .now() + 2) == .success, "cancellation test starts an in-flight request")
cancelled.cancel()
expect(cancelledCompletion.wait(timeout: .now() + 0.5) == .timedOut, "cancelled probe does not deliver late completion")

let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00+08:00")!
let context = NetworkContext(interface: "en1", gateway: "192.168.0.1", dns: "", gatewayMAC: "01:02:03:04:05:06")
var tracker = TrafficTracker(); tracker.registry = registry
tracker.sample(context: context, counters: InterfaceCounters(rx: 1000, tx: 100), uptime: 0, date: now, maxGap: 30)
tracker.sample(context: context, counters: InterfaceCounters(rx: 1300, tx: 120), uptime: 2, date: now, maxGap: 30)
tracker.rememberDevice(reading, key: context.key, date: now)
var router = RouterState(registry: registry)
let probe = router.begin(network: context, gateway: context.gateway)
expect(router.accept(reading, request: probe, current: context, date: now), "generic router state accepts another module")
let known = tracker.state.devices[context.key]!
expect(router.moduleState(current: context, knownDevice: known) == .ready, "module visibility does not depend on F50 model")
expect(router.moduleState(current: context, knownDevice: known, selection: "none") == .hidden, "disabled module hides current data")
expect(router.moduleState(current: context, knownDevice: known, selection: "zte.f50pro") == .hidden, "other explicit module cannot reuse a proof")
var config = Config(); config.billingCycleDay = 1
try tracker.sampleBilling(reading, key: context.key, config: config, date: now, calibratedGB: 1.5)
var advanced = reading; advanced.counterRx = 31
try tracker.sampleBilling(advanced, key: context.key, config: config, date: now.addingTimeInterval(3600))
expect(tracker.billingUsage(key: context.key, config: config, date: now)?.total == 1_500_000_010,
       "generic billing accumulates normalized device deltas")
expect(tracker.billingUsage(key: context.key, config: config, date: now)?.canEstimateQuota == true,
       "verified persistent counter policy permits reconnection without time-only gaps")
let snapshot = DashboardSnapshot.make(tracker: tracker, router: router, config: config, date: now)
expect(snapshot.phase == .ready && snapshot.monthRouterTotal == 320 && snapshot.routerTrafficLabel == "Fixture 5G",
       "generic card and local history work with a second module")
expect(snapshot.signal.isEmpty && snapshot.stationCount.isEmpty, "card hides unsupported capabilities")
expect(snapshot.details.contains { $0.title.contains("Fixture 5G") }, "details name the active module")
let stored = try JSONEncoder().encode(tracker.state)
var reopened = TrafficTracker(); reopened.state = try JSONDecoder().decode(PersistedState.self, from: stored)
expect(reopened.state.routerNetworks[context.key]?.adapterID == adapter.descriptor.id, "history persists module ownership")
let unavailableRegistry = RouterAdapterRegistry(adapters: [])
let offline = DashboardSnapshot.make(tracker: reopened, router: RouterState(registry: unavailableRegistry), config: config, date: now)
expect(offline.phase == .hidden && offline.monthRouterTotal == 320, "removing a module does not erase its local history")
var timeout = RouterInfo(); timeout.errorMessage = "timeout"
let retry = router.begin(network: context, gateway: context.gateway)
router.accept(timeout, request: retry, current: context, date: now)
expect(router.moduleState(current: context, knownDevice: known) == .unavailable && router.info == nil, "failure retains generic identity but clears stale numbers")
let stale = router.begin(network: context, gateway: context.gateway)
router.invalidate()
expect(!router.accept(reading, request: stale, current: context, date: now), "cancelled generation rejects old module response")
var other = reading; other.model = "Other-device"
let changed = router.begin(network: context, gateway: context.gateway)
router.accept(other, request: changed, current: context, date: now)
expect(router.moduleState(current: context, knownDevice: known) == .hidden, "unrecognized live model revokes cached module")
let f50 = RouterAdapterRegistry.builtIn.decode(Data(#"{"wa_inner_version":"F50ProV1","flux_monthly_rx_bytes":100,"flux_monthly_tx_bytes":0}"#.utf8), using: F50ProAdapter())
try tracker.sampleBilling(f50, key: context.key, config: config, date: now.addingTimeInterval(3601))
let changedBilling = tracker.billingUsage(key: context.key, config: config, date: now)!
expect(changedBilling.total == 1_500_000_010 && changedBilling.hasGap, "module change preserves total without subtracting unrelated counters")
network.reset()
expect(fetch(selection: "fixture.auth").adapter?.id == "fixture.auth", "module can prepare an authenticated request asynchronously")
expect(network.requests == ["/auth", "/fixture"] && network.preparedHeaders == ["fixture"], "prepared request is passed through shared transport")
network.reset(slow: true)
while network.started.wait(timeout: .now()) == .success {}
let authDone = DispatchSemaphore(value: 0)
let authTask = RouterClient.fetch(gateway: "fixture.test", selection: "fixture.auth", registry: registry, session: session) { _ in authDone.signal() }
expect(network.started.wait(timeout: .now() + 2) == .success, "authentication cancellation starts preparation")
authTask.cancel()
expect(authDone.wait(timeout: .now() + 0.5) == .timedOut && network.requests == ["/auth"], "cancelled preparation never sends the final device request")
print("PASS: \(checks) adapter contract, discovery, cancellation, billing and history checks")
