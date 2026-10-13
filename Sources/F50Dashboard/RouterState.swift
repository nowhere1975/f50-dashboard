import Foundation

struct RouterRequest: Equatable {
    let serial: UInt64
    let network: NetworkContext
    let gateway: String

    var targetsCurrentGateway: Bool {
        URLComponents(string: "http://\(gateway)")?.host == network.gateway
    }
}

struct ConfirmedDevice: Codable {
    let gatewayMAC: String
    let model: String
    let verifiedAt: Date
}

enum F50ModuleState: String {
    case hidden, loading, ready, unavailable
}

/// 请求和当前网络绑定；取消、切网或新请求发生后，旧响应不能覆盖快照。
struct RouterState {
    private var serial: UInt64 = 0
    private(set) var pending: RouterRequest?
    private(set) var info: RouterInfo?
    private(set) var updatedAt: Date?
    private(set) var errorMessage: String?
    private var responseNetwork: NetworkContext?
    private var identifiedNetwork: NetworkContext?
    private var identifiedModel: String?

    mutating func invalidate() {
        serial &+= 1
        pending = nil; info = nil; updatedAt = nil; errorMessage = nil
        responseNetwork = nil; identifiedNetwork = nil; identifiedModel = nil
    }
    mutating func begin(network: NetworkContext, gateway: String) -> RouterRequest {
        serial &+= 1
        let request = RouterRequest(serial: serial, network: network, gateway: gateway)
        pending = request
        return request
    }
    @discardableResult
    mutating func accept(_ response: RouterInfo, request: RouterRequest,
                         current: NetworkContext?, date: Date) -> Bool {
        guard pending == request, current == request.network else { return false }
        pending = nil
        responseNetwork = request.network
        errorMessage = request.targetsCurrentGateway ? response.errorMessage : "管理地址未确认为当前网关，请使用 auto 或当前网关 IP"
        if request.targetsCurrentGateway, response.responded, !response.model.isEmpty {
            identifiedNetwork = request.network
            identifiedModel = response.model
        }
        // 请求失败不保留之前成功的额度数字，避免把旧读数当成实时值。
        info = request.targetsCurrentGateway && response.responded ? response : nil
        updatedAt = info != nil ? date : nil
        return true
    }

    func moduleState(current: NetworkContext?, knownDevice: ConfirmedDevice?) -> F50ModuleState {
        guard let current = current, current.hasIPv4Gateway else { return .hidden }
        // 当前响应中的真实型号优先；用户网络名称和旧网络快照不能决定板块显示。
        let model = identifiedNetwork == current ? identifiedModel
            : (!current.gatewayMAC.isEmpty && knownDevice?.gatewayMAC == current.gatewayMAC ? knownDevice?.model : nil)
        guard let model = model, RouterInfo.isF50ProModel(model) else { return .hidden }
        if responseNetwork == current, info?.isF50Pro == true { return .ready }
        if pending?.network == current { return .loading }
        return .unavailable
    }
}
