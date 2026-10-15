import Foundation
import CoreFoundation

/// 中兴 F50 Pro 的只读 WebUI 协议。固件字段、请求路径和型号识别仅在此模块维护。
struct F50ProAdapter: RouterAdapter {
    let descriptor = RouterDescriptor(id: "zte.f50pro", name: "F50 Pro",
        capabilities: [.traffic, .signal, .clients], counterPolicy: .resettable)

    func matches(model: String) -> Bool {
        model.lowercased().filter { $0.isLetter || $0.isNumber }.hasPrefix("f50pro")
    }
    func request(gateway: String) -> URLRequest? {
        guard let url = url(gateway: gateway) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("http://\(gateway)/index.html", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        return request
    }
    private let txCandidates = ["flux_monthly_tx_bytes", "monthly_tx_bytes"]
    private let rxCandidates = ["flux_monthly_rx_bytes", "monthly_rx_bytes"]
    private let rsrpCandidates = ["Z5g_rsrp", "nr5g_rsrp", "lte_rsrp", "network_lte_rsrp"]
    private let typeCandidates = ["network_type"]
    private let barCandidates = ["network_signalbar", "signalbar"]
    private let ipCandidates = ["wan_ipaddr", "wan_ip_address"]
    private let modelCandidates = ["wa_inner_version", "device_name"]
    private let fwCandidates = ["cr_version", "wa_inner_version"]
    private var allFields: [String] {
        Array(Set(txCandidates + rxCandidates + rsrpCandidates + typeCandidates
            + barCandidates + ipCandidates + modelCandidates + fwCandidates
            + ["station_list", "flux_auto_clear_flow_data_switch", "flux_clear_date"])).sorted()
    }

    func url(gateway: String) -> URL? {
        guard var c = RouterAddress.components(gateway) else { return nil }
        c.path = "/goform/goform_get_cmd_process"
        c.queryItems = [URLQueryItem(name: "isTest", value: "false"),
                        URLQueryItem(name: "cmd", value: allFields.joined(separator: ",")),
                        URLQueryItem(name: "multi_data", value: "1")]
        return c.url
    }

    func decode(_ data: Data?) -> RouterInfo {
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
        info.counterTx = tx; info.counterRx = rx
        info.counterSource = [txField, rxField].filter { !$0.isEmpty }.joined(separator: "+")
        info.model = first(modelCandidates); info.firmware = first(fwCandidates)
        info.rsrp = first(rsrpCandidates); info.netType = first(typeCandidates)
        info.sigBar = first(barCandidates); info.wanIP = first(ipCandidates)
        if ["on", "1"].contains(str("flux_auto_clear_flow_data_switch").lowercased()),
           let day = Int(str("flux_clear_date")), (1...31).contains(day) { info.autoClearDay = day }
        if let list = object["station_list"] as? [[String: Any]] {
            info.hasStationList = true
            info.stations = list.map { (mac: $0["mac_addr"] as? String ?? "?",
                                       ip: $0["ip_addr"] as? String ?? "?") }
        }
        if !matches(model: info.model) { info.errorMessage = "设备型号未确认为 F50 Pro：\(info.model.isEmpty ? "缺少型号字段" : info.model)" }
        else if info.counterTotal == nil { info.errorMessage = "流量字段缺失或无效，暂不估算余量" }
        return info
    }
}
