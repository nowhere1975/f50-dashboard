import Foundation

enum RouterCapability: String, Codable, Hashable {
    case traffic, signal, clients, clientTraffic
}

enum RouterCounterPolicy: String, Codable {
    /// 设备可能清零，长时间未读取时不能证明计数连续。
    case resettable
    /// 模块已验证为持续保存的累计计数；仍检查回退与字段切换。
    case persistent
}

struct RouterDescriptor: Codable, Equatable {
    let id: String
    let name: String
    let capabilities: Set<RouterCapability>
    let counterPolicy: RouterCounterPolicy

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }
}

/// 内置适配模块：归一化设备读数，不负责 App 的历史保存、套餐累计或界面。
protocol RouterAdapter {
    var descriptor: RouterDescriptor { get }
    func matches(model: String) -> Bool
    func request(gateway: String) -> URLRequest?
    func decode(_ data: Data?) -> RouterInfo
    /// 需要鉴权的模块可在此异步准备请求；返回的操作由主程序统一取消。
    func prepare(gateway: String, session: URLSession,
                 completion: @escaping (Result<URLRequest, Error>) -> Void) -> (any RouterAdapterTask)?
}

protocol RouterAdapterTask: AnyObject { func cancel() }
extension URLSessionTask: RouterAdapterTask {}

extension RouterAdapter {
    func prepare(gateway: String, session: URLSession,
                 completion: @escaping (Result<URLRequest, Error>) -> Void) -> (any RouterAdapterTask)? {
        if let request = request(gateway: gateway) { completion(.success(request)) }
        else { completion(.failure(ConfigError(message: "管理地址格式有误"))) }
        return nil
    }
}

struct RouterAdapterRegistry {
    let adapters: [any RouterAdapter]
    static let builtIn = RouterAdapterRegistry(adapters: [F50ProAdapter()])

    init(adapters: [any RouterAdapter]) {
        precondition(Set(adapters.map { $0.descriptor.id }).count == adapters.count, "模块 ID 重复")
        precondition(adapters.allSatisfy { RouterDescriptor.validID($0.descriptor.id) && !$0.descriptor.name.isEmpty })
        self.adapters = adapters
    }
    func adapter(id: String) -> (any RouterAdapter)? { adapters.first { $0.descriptor.id == id } }
    func matching(model: String) -> (any RouterAdapter)? { adapters.first { $0.matches(model: model) } }
    func descriptor(for info: RouterInfo) -> RouterDescriptor? {
        guard let id = info.adapter?.id, let adapter = adapter(id: id), adapter.matches(model: info.model) else { return nil }
        return adapter.descriptor
    }
    func candidates(selection: String, preferred: String?) -> [any RouterAdapter] {
        if selection == "none" { return [] }
        if selection != "auto" { return adapter(id: selection).map { [$0] } ?? [] }
        guard let preferred = preferred, let first = adapter(id: preferred) else { return adapters }
        return [first] + adapters.filter { $0.descriptor.id != preferred }
    }
    func decode(_ data: Data?, using adapter: any RouterAdapter) -> RouterInfo {
        var info = adapter.decode(data)
        info.adapter = info.responded && adapter.matches(model: info.model) ? adapter.descriptor : nil
        if !adapter.descriptor.capabilities.contains(.traffic) { info.counterRx = nil; info.counterTx = nil }
        if !adapter.descriptor.capabilities.contains(.signal) { info.netType = ""; info.sigBar = ""; info.rsrp = "" }
        if !adapter.descriptor.capabilities.contains(.clients) { info.stations = []; info.hasStationList = false }
        if !adapter.descriptor.capabilities.contains(.clientTraffic) { info.clientTraffic = nil }
        return info
    }
}

enum RouterAddress {
    static func components(_ gateway: String) -> URLComponents? {
        guard !gateway.isEmpty, !gateway.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
              let components = URLComponents(string: "http://\(gateway)"),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return components
    }
}

struct RouterInfo {
    var responded = false
    var adapter: RouterDescriptor?
    var model = ""
    var firmware = ""
    var counterRx: UInt64?
    var counterTx: UInt64?
    var counterSource = ""
    var rsrp = ""
    var netType = ""
    var sigBar = ""
    var wanIP = ""
    var stations: [(mac: String, ip: String)] = []
    var errorMessage: String?
    var autoClearDay: Int?
    var hasStationList = false
    var clientTraffic: [RouterStationTraffic]?

    var isSupported: Bool { adapter != nil }
    var canCountTraffic: Bool { adapter?.capabilities.contains(.traffic) == true && counterTotal != nil }
    var counterTotal: UInt64? {
        guard let rx = counterRx, let tx = counterTx else { return nil }
        let sum = rx.addingReportingOverflow(tx)
        return sum.overflow ? nil : sum.partialValue
    }
}

struct RouterStationTraffic {
    let mac: String
    let rx: UInt64
    let tx: UInt64
    let source: String
}
