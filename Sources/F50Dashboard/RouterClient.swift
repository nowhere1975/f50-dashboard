import Foundation
import CoreFoundation

struct RouterInfo {
    var responded = false
    var model = ""
    var firmware = ""
    var monthlyRx: UInt64?
    var monthlyTx: UInt64?
    var usedFields = ""
    var rsrp = ""
    var netType = ""
    var sigBar = ""
    var wanIP = ""
    var stations: [(mac: String, ip: String)] = []
    var errorMessage: String?
    var autoClearDay: Int?

    var isF50: Bool { model.lowercased().hasPrefix("f50") }
    // 固件将该计数命名为 monthly；它可在套餐周期内清零，不代表完整月度账单。
    var monthlyTotal: UInt64? {
        guard let rx = monthlyRx, let tx = monthlyTx else { return nil }
        let result = rx.addingReportingOverflow(tx)
        return result.overflow ? nil : result.partialValue
    }
}

enum RouterClient {
    static let defaultGateway = "192.168.0.1"
    private static let txCandidates = ["flux_monthly_tx_bytes", "monthly_tx_bytes"]
    private static let rxCandidates = ["flux_monthly_rx_bytes", "monthly_rx_bytes"]
    private static let rsrpCandidates = ["Z5g_rsrp", "nr5g_rsrp", "lte_rsrp", "network_lte_rsrp"]
    private static let typeCandidates = ["network_type"]
    private static let barCandidates = ["network_signalbar", "signalbar"]
    private static let ipCandidates = ["wan_ipaddr", "wan_ip_address"]
    private static let modelCandidates = ["wa_inner_version", "device_name"]
    private static let fwCandidates = ["cr_version", "wa_inner_version"]
    private static var allFields: [String] {
        Array(Set(txCandidates + rxCandidates + rsrpCandidates + typeCandidates
            + barCandidates + ipCandidates + modelCandidates + fwCandidates
            + ["station_list", "flux_auto_clear_flow_data_switch", "flux_clear_date"])).sorted()
    }

    static func url(gateway: String) -> URL? {
        guard !gateway.isEmpty, !gateway.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
              let components = URLComponents(string: "http://\(gateway)"),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        var c = components
        c.path = "/goform/goform_get_cmd_process"
        c.queryItems = [URLQueryItem(name: "isTest", value: "false"),
                        URLQueryItem(name: "cmd", value: allFields.joined(separator: ",")),
                        URLQueryItem(name: "multi_data", value: "1")]
        return c.url
    }

    @discardableResult
    static func fetch(gateway: String, completion: @escaping (RouterInfo) -> Void) -> URLSessionDataTask? {
        guard let url = url(gateway: gateway) else {
            var info = RouterInfo(); info.errorMessage = "管理地址格式有误"
            completion(info); return nil
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.setValue("http://\(gateway)/index.html", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                var info = RouterInfo(); info.errorMessage = "读取失败：\(error.localizedDescription)"
                completion(info); return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                var info = RouterInfo()
                info.errorMessage = "管理接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                completion(info); return
            }
            completion(parse(data))
        }
        task.resume()
        return task
    }

    static func parse(_ data: Data?) -> RouterInfo {
        var info = RouterInfo()
        guard let data = data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else {
            info.errorMessage = "管理接口未返回有效 JSON"
            return info
        }
        info.responded = true
        func str(_ key: String) -> String {
            if let value = object[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
            return ""
        }
        func first(_ keys: [String]) -> String {
            keys.lazy.map(str).first(where: { !$0.isEmpty }) ?? ""
        }
        func bytes(_ keys: [String]) -> (UInt64?, String) {
            for key in keys {
                let value = str(key)
                if let number = UInt64(value) { return (number, key) }
            }
            return (nil, "")
        }
        let (tx, txField) = bytes(txCandidates), (rx, rxField) = bytes(rxCandidates)
        info.monthlyTx = tx; info.monthlyRx = rx
        info.usedFields = [txField, rxField].filter { !$0.isEmpty }.joined(separator: "+")
        info.model = first(modelCandidates); info.firmware = first(fwCandidates)
        info.rsrp = first(rsrpCandidates); info.netType = first(typeCandidates)
        info.sigBar = first(barCandidates); info.wanIP = first(ipCandidates)
        if ["on", "1"].contains(str("flux_auto_clear_flow_data_switch").lowercased()),
           let day = Int(str("flux_clear_date")), (1...31).contains(day) { info.autoClearDay = day }
        if let list = object["station_list"] as? [[String: Any]] {
            info.stations = list.map { (mac: $0["mac_addr"] as? String ?? "?",
                                       ip: $0["ip_addr"] as? String ?? "?") }
        }
        if !info.isF50 { info.errorMessage = "设备型号未确认为 F50：\(info.model.isEmpty ? "缺少型号字段" : info.model)" }
        else if info.monthlyTotal == nil { info.errorMessage = "流量字段缺失或无效，暂不估算余量" }
        return info
    }
}
