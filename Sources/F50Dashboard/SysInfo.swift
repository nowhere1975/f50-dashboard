import Foundation

/// 系统命令与网络信息的封装。
///
/// 所有外部命令的路径都通过 `findBin` 解析，绝不硬编码 —— 见 docs/PITFALLS.md
/// 里记录的 `netstat` 在 `/usr/sbin` 而非 `/usr/bin` 的坑。
enum SysInfo {

    // MARK: - 命令执行

    static func findBin(_ candidates: [String]) -> String {
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return candidates.first ?? ""
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        guard !path.isEmpty else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()          // 吞掉 stderr，避免污染菜单栏 App 的日志
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static let netstat  = findBin(["/usr/sbin/netstat", "/usr/bin/netstat", "/bin/netstat"])
    static let route    = findBin(["/sbin/route", "/usr/sbin/route", "/usr/bin/route"])
    static let arp      = findBin(["/usr/sbin/arp", "/usr/bin/arp", "/sbin/arp"])
    static let ping     = findBin(["/sbin/ping", "/usr/bin/ping", "/bin/ping"])
    static let ipconfig = findBin(["/usr/sbin/ipconfig", "/usr/bin/ipconfig"])

    // MARK: - 接口计数

    /// 读某个网络接口自开机以来的累计收发字节。
    /// 解析 `netstat -ib` 的 `<Link#N>` 汇总行 —— 该行才是接口总数，
    /// 其它行是按协议/地址分列的。
    static func ifaceCounters(_ iface: String) -> (rx: UInt64, tx: UInt64) {
        for line in run(netstat, ["-ib"]).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // 列序: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            if f.count >= 11, f[0] == iface, f[2].hasPrefix("<Link") {
                return (UInt64(f[6]) ?? 0, UInt64(f[9]) ?? 0)
            }
        }
        return (0, 0)
    }

    // MARK: - 网络路由信息

    /// 默认网关地址。
    static func defaultGateway() -> String {
        for line in run(route, ["-n", "get", "default"]).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// 默认路由使用的接口名（en0 / en7 …）。
    static func defaultInterface() -> String {
        for line in run(route, ["-n", "get", "default"]).split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return "en0"
    }

    /// 该接口的第一个 DNS 服务器。用作网络指纹的一部分。
    static func primaryDNS(_ iface: String) -> String {
        let out = run(ipconfig, ["getoption", iface, "domain_name_server"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.split(separator: " ").first.map(String.init) ?? ""
    }

    /// 网关 MAC。
    ///
    /// 注意：在 macOS 上，从 App 进程里调用 `arp` **恒返回空**
    /// （同为系统命令的 netstat / route / ipconfig / ndp 均正常，
    /// 详见 docs/PITFALLS.md）。因此这个函数很可能拿不到值，
    /// 调用方必须有降级方案。
    static func gatewayMAC(_ gw: String) -> String {
        guard !gw.isEmpty else { return "" }
        run(ping, ["-c1", "-t1", gw])          // 先 ping 一次，确保 ARP 表里有记录
        for line in run(arp, ["-n", gw]).split(separator: "\n") {
            for tok in line.split(separator: " ", omittingEmptySubsequences: true) {
                let s = String(tok)
                if s.contains(":"),
                   s.filter({ $0 != ":" }).count == 12,
                   s.allSatisfy({ $0.isHexDigit || $0 == ":" }) {
                    return s.lowercased()
                }
            }
        }
        return ""
    }
}
