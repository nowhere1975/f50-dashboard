import Foundation

/// 从 F50 Pro 读到的一份快照。
struct RouterInfo {
    var reachable = false
    var model = ""              // wa_inner_version，例如 F50ProV1.0.0B27
    var firmware = ""           // cr_version
    var monthlyRx: UInt64 = 0
    var monthlyTx: UInt64 = 0
    var usedFields = ""         // 实际命中的字段名，便于不同固件排查
    var rsrp = ""
    var netType = ""
    var sigBar = ""
    var wanIP = ""
    var stations: [(mac: String, ip: String)] = []

    var monthlyTotal: UInt64 { monthlyRx + monthlyTx }
}

/// F50 Pro 的只读 API 客户端。
///
/// 关键事实（详见 docs/PROTOCOL.md）：
///   · 端点 `GET /goform/goform_get_cmd_process?isTest=false&cmd=<逗号分隔>&multi_data=1`
///   · **读命令不需要认证**，所以本工具不持有任何凭据
///   · 不同固件的字段名可能不同，因此每个指标都准备多个候选名，逐个尝试
enum RouterClient {

    /// 出厂默认管理地址。
    static let defaultGateway = "192.168.0.1"

    /// 每个指标按优先级排列的候选字段名 —— 这是应对固件差异的核心机制。
    private static let txCandidates = ["flux_monthly_tx_bytes", "monthly_tx_bytes"]
    private static let rxCandidates = ["flux_monthly_rx_bytes", "monthly_rx_bytes"]
    private static let rsrpCandidates = ["Z5g_rsrp", "nr5g_rsrp", "lte_rsrp", "network_lte_rsrp"]
    private static let typeCandidates = ["network_type", "wan_active_band"]
    private static let barCandidates  = ["network_signalbar", "signalbar"]
    private static let ipCandidates   = ["wan_ipaddr", "wan_ip_address"]
    private static let modelCandidates = ["wa_inner_version", "web_version", "device_name"]
    private static let fwCandidates   = ["cr_version", "wa_inner_version"]

    private static var allFields: [String] {
        txCandidates + rxCandidates + rsrpCandidates + typeCandidates
            + barCandidates + ipCandidates + modelCandidates + fwCandidates + ["station_list"]
    }

    /// 发起一次读取。
    static func fetch(gateway: String, completion: @escaping (RouterInfo) -> Void) {
        let cmd = allFields.joined(separator: ",")
        guard let url = URL(string:
            "http://\(gateway)/goform/goform_get_cmd_process?isTest=false&cmd=\(cmd)&multi_data=1")
        else { completion(RouterInfo()); return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("http://\(gateway)/index.html", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                     forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, _ in
            completion(parse(data))
        }.resume()
    }

    /// 解析响应。字段值可能是字符串（"-82"）也可能是数字（5），两种都要认。
    static func parse(_ data: Data?) -> RouterInfo {
        var info = RouterInfo()
        guard let d = data,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              !obj.isEmpty
        else { return info }

        func str(_ key: String) -> String {
            if let v = obj[key] as? String { return v }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return ""
        }
        func bytes(_ keys: [String]) -> (UInt64, String) {
            for k in keys {
                let s = str(k)
                if !s.isEmpty, let v = UInt64(s), v > 0 { return (v, k) }
            }
            return (0, "")
        }
        func first(_ keys: [String]) -> String {
            for k in keys { let s = str(k); if !s.isEmpty { return s } }
            return ""
        }

        let (tx, txField) = bytes(txCandidates)
        let (rx, rxField) = bytes(rxCandidates)

        // 一个字段都没命中，说明对面不是 F50（或者路径不存在）
        if txField.isEmpty && rxField.isEmpty && obj["station_list"] == nil {
            return info
        }

        info.reachable = true
        info.monthlyTx = tx
        info.monthlyRx = rx
        info.usedFields = [txField, rxField].filter { !$0.isEmpty }.joined(separator: "+")
        info.rsrp = first(rsrpCandidates)
        info.netType = first(typeCandidates)
        info.sigBar = first(barCandidates)
        info.wanIP = first(ipCandidates)
        info.model = first(modelCandidates)
        info.firmware = first(fwCandidates)

        if let list = obj["station_list"] as? [[String: Any]] {
            info.stations = list.map {
                (mac: ($0["mac_addr"] as? String) ?? "?",
                 ip:  ($0["ip_addr"]  as? String) ?? "?")
            }
        }
        return info
    }
}
