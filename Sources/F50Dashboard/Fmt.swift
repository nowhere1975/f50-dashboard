import Foundation

/// 显示格式化。
///
/// 单位一律用**十进制**（1 KB = 1000 B，1 GB = 10⁹ B）。
/// 原因：运营商的计费和路由器后台都用 10⁹ 口径的 GB。若用二进制 2³⁰ 却在
/// 标签上写 GB，100 GB 的配额会算错约 7.4% —— 这是本工具最初的真实 bug。
enum Fmt {

    static let kilo: Double = 1_000
    static let mega: Double = 1_000_000
    static let giga: Double = 1_000_000_000
    static let tera: Double = 1_000_000_000_000

    // MARK: - 容量

    static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= tera { return String(format: "%.2f TB", d / tera) }
        if d >= giga { return String(format: "%.2f GB", d / giga) }
        if d >= mega { return String(format: "%.1f MB", d / mega) }
        if d >= kilo { return String(format: "%.0f KB", d / kilo) }
        return "\(b) B"
    }

    // MARK: - 速率（固定宽度）

    /// 固定 5 字符、右对齐。
    ///
    /// 这是菜单栏不抖动的关键：数字长度会随量级变化（8.5K / 1.2M / 340K），
    /// 补齐到固定宽度后，菜单栏项宽度就恒定了。
    /// 配合 `NSFont.monospacedSystemFont` 使用 —— 比例字体里空格宽度不同，补了也白补。
    static func rate(_ bps: Double) -> String {
        let s: String
        if      bps >= giga     { s = String(format: "%.1fG", bps / giga) }
        else if bps >= 100 * mega { s = String(format: "%.0fM", bps / mega) }
        else if bps >= 10 * mega  { s = String(format: "%.0fM", bps / mega) }
        else if bps >= mega       { s = String(format: "%.1fM", bps / mega) }
        else if bps >= 100 * kilo { s = String(format: "%.0fK", bps / kilo) }
        else if bps >= 10 * kilo  { s = String(format: "%.1fK", bps / kilo) }
        else if bps >= kilo       { s = String(format: "%.1fK", bps / kilo) }
        else                      { s = String(format: "%.0fB", bps) }
        return String(repeating: " ", count: max(0, 5 - s.count)) + s
    }

    // MARK: - 其它

    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    static func duration(since: Date) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(since) / 60))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }

    /// 配额进度条（20 格）。
    static func bar(_ percent: Double) -> String {
        let cells = 20
        let filled = min(cells, max(0, Int(percent / 100 * Double(cells))))
        return "[" + String(repeating: "█", count: filled)
                   + String(repeating: "░", count: cells - filled) + "]"
    }

    /// F50 Pro 的网络特征：默认网关与首选 DNS 都指向它自己（出厂配置如此）。
    static func isRouterSignature(gw: String, iface: String) -> Bool {
        gw == RouterClient.defaultGateway && SysInfo.primaryDNS(iface) == RouterClient.defaultGateway
    }
}
