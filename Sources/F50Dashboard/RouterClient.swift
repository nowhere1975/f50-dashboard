import Foundation

/// 所有模块共用的传输与取消逻辑，当前已确认模块优先。
enum RouterClient {
    static func fetch(gateway: String, selection: String = "auto", preferred: String? = nil,
                      registry: RouterAdapterRegistry = .builtIn, session: URLSession = .shared,
                      completion: @escaping (RouterInfo) -> Void) -> RouterFetchTask {
        let operation = RouterFetchTask(gateway: gateway,
            adapters: registry.candidates(selection: selection, preferred: preferred),
            registry: registry, session: session, completion: completion)
        operation.start()
        return operation
    }
}

final class RouterFetchTask {
    private let queue = DispatchQueue(label: "traffic-monitor.router-fetch")
    private let gateway: String
    private let adapters: [any RouterAdapter]
    private let registry: RouterAdapterRegistry
    private let session: URLSession
    private let completion: (RouterInfo) -> Void
    private var current: URLSessionDataTask?
    private var preparation: (any RouterAdapterTask)?
    private var cancelled = false
    private var finished = false
    private var fallback: RouterInfo?

    init(gateway: String, adapters: [any RouterAdapter], registry: RouterAdapterRegistry,
         session: URLSession, completion: @escaping (RouterInfo) -> Void) {
        self.gateway = gateway; self.adapters = adapters; self.registry = registry
        self.session = session; self.completion = completion
    }
    func start() { queue.async { self.next(0) } }
    func cancel() {
        queue.async {
            self.cancelled = true; self.preparation?.cancel(); self.current?.cancel()
            self.preparation = nil; self.current = nil
        }
    }
    private func finish(_ info: RouterInfo) {
        guard !cancelled, !finished else { return }
        finished = true; current = nil; preparation = nil
        completion(info)
    }
    private func next(_ index: Int) {
        guard !cancelled, !finished else { return }
        guard index < adapters.count else {
            var info = fallback ?? RouterInfo()
            if info.errorMessage == nil { info.errorMessage = "未识别到已支持的路由器模块" }
            finish(info); return
        }
        let adapter = adapters[index]
        preparation = adapter.prepare(gateway: gateway, session: session) { result in
            self.queue.async {
                guard !self.cancelled, !self.finished else { return }
                self.preparation = nil
                switch result {
                case .success(let request): self.send(request, adapter: adapter, index: index)
                case .failure(let error):
                    var info = RouterInfo(); info.errorMessage = error.localizedDescription
                    if self.fallback?.responded != true { self.fallback = info }
                    self.next(index + 1)
                }
            }
        }
    }
    private func send(_ request: URLRequest, adapter: any RouterAdapter, index: Int) {
        current = session.dataTask(with: request) { data, response, error in
            self.queue.async {
                guard !self.cancelled, !self.finished else { return }
                self.current = nil
                var info: RouterInfo
                if let error = error {
                    info = RouterInfo(); info.errorMessage = "读取失败：\(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    info = self.registry.decode(data, using: adapter)
                } else {
                    info = RouterInfo()
                    info.errorMessage = "管理接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                }
                if info.isSupported { self.finish(info); return }
                if self.fallback?.responded != true || (info.responded && !info.model.isEmpty) { self.fallback = info }
                self.next(index + 1)
            }
        }
        current?.resume()
    }
}
