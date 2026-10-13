import Foundation

struct Config: Codable, Equatable {
    var quotaGB: Double = 100
    var routerGateway = "auto"
    var interface = "auto"
    var localPollSec: Double = 2
    var routerPollSec: Double = 30
    var showRateInTitle = true
    var networkNames: [String: String] = [:]
    var enableQuotaAlerts = false
    var billingCycleDay: Int?
    var billingTimeZone = "Asia/Shanghai"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("F50Dashboard", isDirectory: true)
    }
    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case quotaGB, routerGateway, interface, localPollSec, routerPollSec, showRateInTitle
        case networkNames, enableQuotaAlerts, billingCycleDay, billingTimeZone
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quotaGB = try c.decodeIfPresent(Double.self, forKey: .quotaGB) ?? 100
        routerGateway = try c.decodeIfPresent(String.self, forKey: .routerGateway) ?? "auto"
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? "auto"
        localPollSec = try c.decodeIfPresent(Double.self, forKey: .localPollSec) ?? 2
        routerPollSec = try c.decodeIfPresent(Double.self, forKey: .routerPollSec) ?? 30
        showRateInTitle = try c.decodeIfPresent(Bool.self, forKey: .showRateInTitle) ?? true
        networkNames = try c.decodeIfPresent([String: String].self, forKey: .networkNames) ?? [:]
        enableQuotaAlerts = try c.decodeIfPresent(Bool.self, forKey: .enableQuotaAlerts) ?? false
        billingCycleDay = try c.decodeIfPresent(Int.self, forKey: .billingCycleDay)
        billingTimeZone = try c.decodeIfPresent(String.self, forKey: .billingTimeZone) ?? "Asia/Shanghai"
        try validate()
    }

    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ConfigError(message: message) }
        }
        try require(quotaGB.isFinite && quotaGB > 0 && quotaGB <= 1_000_000, "quotaGB 必须大于 0，且不超过 1000000 GB")
        try require(billingCycleDay.map { (1...31).contains($0) } ?? true, "套餐重置日必须为 1–31，或留空")
        try require(TimeZone(identifier: billingTimeZone) != nil, "套餐时区无效")
        try require(localPollSec.isFinite && (1...60).contains(localPollSec), "localPollSec 必须为 1–60 秒")
        try require(routerPollSec.isFinite && (5...3600).contains(routerPollSec), "routerPollSec 必须为 5–3600 秒")
        try require(interface == "auto" || (!interface.isEmpty && interface.utf8.count < 16
            && interface.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }), "interface 必须为 auto 或有效网卡名称")
        try require(routerGateway == "auto" || RouterClient.url(gateway: routerGateway) != nil,
                    "routerGateway 必须为 auto、IP 地址或主机名（可带端口）")
    }

    /// 仅首次运行创建文件。出错时保留原文件和上一份有效配置。
    static func read(at url: URL = fileURL, fallback: Config = Config()) -> (config: Config, warning: String?) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try fallback.save(to: url); return (fallback, nil) }
            catch { return (fallback, "无法创建配置：\(error.localizedDescription)") }
        }
        do { return (try JSONDecoder().decode(Config.self, from: Data(contentsOf: url)), nil) }
        catch { return (fallback, "配置未加载，原文件已保留：\(error.localizedDescription)") }
    }

    func save(to url: URL = Config.fileURL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            guard let parsed = try JSONSerialization.jsonObject(with: old) as? [String: Any] else {
                throw ConfigError(message: "配置文件格式有误，请先修复原文件")
            }
            object = parsed
        }
        let current = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        object.merge(current) { _, new in new }
        if billingCycleDay == nil { object.removeValue(forKey: "billingCycleDay") }
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
}

struct ConfigError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
