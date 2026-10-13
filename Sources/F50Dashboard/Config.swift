import Foundation

/// 用户配置。首次运行会在
/// `~/Library/Application Support/F50Dashboard/config.json` 生成一份默认配置。
///
/// 这个文件**不进版本库**（见 .gitignore）—— 每个用户的月配额和网关都不同。
struct Config: Codable {

    /// 5G 套餐每月额度，单位 GB（十进制，与运营商后台一致）。
    var quotaGB: Double = 100

    /// 路由器管理地址。"auto" 表示用当前默认网关。
    var routerGateway: String = "auto"

    /// 监控的网卡。"auto" 表示用默认路由所在接口。
    var interface: String = "auto"

    /// 本机速率刷新间隔（秒）。
    var localPollSec: Double = 2

    /// 路由器数据刷新间隔（秒）。
    var routerPollSec: Double = 30

    /// 是否在菜单栏显示实时速率。关掉可只看累计。
    var showRateInTitle: Bool = true

    // MARK: - 位置

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("F50Dashboard", isDirectory: true)
    }

    static var fileURL: URL { supportDir.appendingPathComponent("config.json") }

    // MARK: - 读写

    /// 缺失的键一律回落到默认值，这样升级版本新增配置项时不会让老配置失效。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent 返回 T?，键不存在时给 nil，正好用 ?? 落回默认值
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback
        }
        quotaGB          = d(.quotaGB, 100)
        routerGateway    = d(.routerGateway, "auto")
        interface        = d(.interface, "auto")
        localPollSec     = d(.localPollSec, 2)
        routerPollSec    = d(.routerPollSec, 30)
        showRateInTitle  = d(.showRateInTitle, true)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case quotaGB, routerGateway, interface, localPollSec, routerPollSec, showRateInTitle
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else {
            let fresh = Config()
            fresh.save()          // 首次运行落一份默认配置，方便用户直接编辑
            return fresh
        }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.fileURL)
        }
    }

    // MARK: - 解析 "auto"

    /// 实际使用的网卡。
    var effectiveInterface: String {
        interface == "auto" ? SysInfo.defaultInterface() : interface
    }

    /// 实际使用的路由器地址。
    ///
    /// "auto" 时直接用当前默认网关 —— F50 Pro 联网时它就是网关。
    /// 若当前在别的网络上，这次请求自然会失败，界面会如实显示"不在 5G 路由器上"，
    /// 不需要事先探测（事先探测会阻塞主线程）。
    func effectiveGateway() -> String {
        if routerGateway != "auto" { return routerGateway }
        let gw = SysInfo.defaultGateway()
        return gw.isEmpty ? RouterClient.defaultGateway : gw
    }
}
