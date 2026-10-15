import Foundation

struct RouterRequest: Equatable {
    let serial: UInt64
    let network: NetworkContext
    let gateway: String
    var targetsCurrentGateway: Bool { URLComponents(string: "http://\(gateway)")?.host == network.gateway }
}

struct ConfirmedDevice: Codable {
    let gatewayMAC: String
    let model: String
    let verifiedAt: Date
    var adapterID: String? = nil
    var displayName: String? = nil

    func descriptor(in registry: RouterAdapterRegistry = .builtIn) -> RouterDescriptor? {
        let adapter = adapterID.flatMap { registry.adapter(id: $0) } ?? (adapterID == nil ? registry.matching(model: model) : nil)
        guard let adapter = adapter, adapter.matches(model: model) else { return nil }
        return adapter.descriptor
    }
}

struct RouterNetworkRecord: Codable, Equatable {
    let adapterID: String
    let name: String
    let model: String
}

enum RouterModuleState: String { case hidden, loading, ready, unavailable }

/// 请求、模块证明和当前网络绑定；迟到响应不能跨网络或跨模块覆盖状态。
struct RouterState {
    let registry: RouterAdapterRegistry
    private var serial: UInt64 = 0
    private(set) var pending: RouterRequest?
    private(set) var info: RouterInfo?
    private(set) var updatedAt: Date?
    private(set) var errorMessage: String?
    private var responseNetwork: NetworkContext?
    private var identifiedNetwork: NetworkContext?
    private var identifiedAdapter: RouterDescriptor?

    init(registry: RouterAdapterRegistry = .builtIn) { self.registry = registry }
    mutating func invalidate() {
        serial &+= 1
        pending = nil; info = nil; updatedAt = nil; errorMessage = nil
        responseNetwork = nil; identifiedNetwork = nil; identifiedAdapter = nil
    }
    mutating func begin(network: NetworkContext, gateway: String) -> RouterRequest {
        serial &+= 1
        let request = RouterRequest(serial: serial, network: network, gateway: gateway)
        pending = request
        return request
    }
    @discardableResult
    mutating func accept(_ response: RouterInfo, request: RouterRequest, current: NetworkContext?, date: Date) -> Bool {
        guard pending == request, current == request.network else { return false }
        pending = nil; responseNetwork = request.network
        errorMessage = request.targetsCurrentGateway ? response.errorMessage : "管理地址未确认为当前网关，请使用 auto 或当前网关 IP"
        var checked = response
        checked.adapter = registry.descriptor(for: response)
        if request.targetsCurrentGateway, checked.responded, !checked.model.isEmpty {
            identifiedNetwork = request.network; identifiedAdapter = checked.adapter
        }
        info = request.targetsCurrentGateway && checked.responded ? checked : nil
        updatedAt = info != nil ? date : nil
        return true
    }
    func descriptor(current: NetworkContext?, knownDevice: ConfirmedDevice?, selection: String = "auto") -> RouterDescriptor? {
        guard selection != "none", let current = current, current.hasIPv4Gateway else { return nil }
        let descriptor: RouterDescriptor?
        if identifiedNetwork == current { descriptor = identifiedAdapter }
        else if !current.gatewayMAC.isEmpty && knownDevice?.gatewayMAC == current.gatewayMAC {
            descriptor = knownDevice?.descriptor(in: registry)
        } else { descriptor = nil }
        guard let descriptor = descriptor, selection == "auto" || selection == descriptor.id else { return nil }
        return descriptor
    }
    func moduleState(current: NetworkContext?, knownDevice: ConfirmedDevice?, selection: String = "auto") -> RouterModuleState {
        guard let descriptor = descriptor(current: current, knownDevice: knownDevice, selection: selection) else { return .hidden }
        if responseNetwork == current, info?.adapter?.id == descriptor.id { return .ready }
        if pending?.network == current { return .loading }
        return .unavailable
    }
}
