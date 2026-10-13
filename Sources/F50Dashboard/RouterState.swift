import Foundation

struct RouterRequest: Equatable {
    let serial: UInt64
    let network: NetworkContext
    let gateway: String
}

/// 请求和当前网络绑定；取消、切网或新请求发生后，旧响应不能覆盖快照。
struct RouterState {
    private var serial: UInt64 = 0
    private(set) var pending: RouterRequest?
    private(set) var info: RouterInfo?
    private(set) var updatedAt: Date?
    private(set) var errorMessage: String?

    mutating func invalidate() {
        serial &+= 1
        pending = nil; info = nil; updatedAt = nil; errorMessage = nil
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
        errorMessage = response.errorMessage
        // 请求失败不保留之前成功的额度数字，避免把旧读数当成实时值。
        info = response.responded ? response : nil
        updatedAt = response.responded ? date : nil
        return true
    }
}
