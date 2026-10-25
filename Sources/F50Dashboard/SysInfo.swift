import Foundation
import SystemConfiguration
import Darwin

enum SysInfo {
    static func dictionary(_ key: String, store: SCDynamicStore?) -> [String: Any] {
        guard let store = store else { return [:] }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
    }

    /// 直接读系统网络状态，避免在主线程启动 route、ping、arp 进程。
    static func networkContext(interface configured: String) -> NetworkContext {
        let store = SCDynamicStoreCreate(nil, "F50Dashboard" as CFString, nil, nil)
        let global = dictionary("State:/Network/Global/IPv4", store: store)
        let iface = configured == "auto" ? (global["PrimaryInterface"] as? String ?? "") : configured
        var ipv4: [String: Any] = [:]
        var dns: [String: Any] = [:]
        if let service = global["PrimaryService"] as? String {
            ipv4 = dictionary("State:/Network/Service/\(service)/IPv4", store: store)
            dns = dictionary("State:/Network/Service/\(service)/DNS", store: store)
        }
        if configured != "auto", ipv4["InterfaceName"] as? String != iface, let store = store,
           let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] {
            ipv4 = [:]; dns = [:]
            for key in keys {
                let candidate = dictionary(key, store: store)
                if candidate["InterfaceName"] as? String == iface {
                    ipv4 = candidate
                    dns = dictionary(String(key.dropLast(4)) + "DNS", store: store)
                    break
                }
            }
        }
        let gateway = ipv4["Router"] as? String ?? (configured == "auto" ? global["Router"] as? String ?? "" : "")
        let servers = dns["ServerAddresses"] as? [String] ?? []
        let mac = (ipv4["ARPResolvedIPAddress"] as? String == gateway)
            ? normalizeMAC(ipv4["ARPResolvedHardwareAddress"] as? String ?? "") : ""
        return NetworkContext(interface: iface, gateway: gateway, dns: servers.joined(separator: ","), gatewayMAC: mac,
                              localIP: localIPv4(ipv4, interface: iface))
    }

    static func localIPv4(_ ipv4: [String: Any], interface: String) -> String {
        guard !interface.isEmpty, ipv4["InterfaceName"] as? String == interface else { return "" }
        return (ipv4["Addresses"] as? [String])?.first(where: { !$0.isEmpty }) ?? ""
    }

    static func normalizeMAC(_ value: String) -> String {
        let parts = value.split(separator: ":")
        guard parts.count == 6 else { return "" }
        var bytes: [String] = []
        for part in parts {
            guard part.count <= 2, let byte = UInt8(part, radix: 16) else { return "" }
            bytes.append(String(format: "%02x", byte))
        }
        return bytes.joined(separator: ":")
    }

    /// 后台读取 netstat 的 64 位累计，失败返回 nil，合法零值保留。
    /// 当前系统的原生 sysctl 计数在第三方进程中与 netstat 不一致，因此采用实测可对齐的来源。
    static func ifaceCounters(_ iface: String) -> InterfaceCounters? {
        guard !iface.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn", "-I", iface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 11, fields[0] == iface, fields[2].hasPrefix("<Link"),
               let rx = UInt64(fields[6]), let tx = UInt64(fields[9]) {
                return InterfaceCounters(rx: rx, tx: tx)
            }
        }
        return nil
    }
}
