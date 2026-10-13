import Foundation

/// 显示格式化。
///
/// 单位一律用**十进制**（1 KB = 1000 B，1 GB = 10⁹ B）。
/// 字节计数按十进制 GB 显示并与配置额度比较；设备 WebUI 自身可能采用不同单位。
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
        String(format: v == v.rounded() ? "%.0f" : "%.1f", v)
    }

    static func duration(since: Date) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(since) / 60))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }

    /// 配额进度条（20 格）。
    static func bar(_ percent: Double) -> String {
        let cells = 20
        let bounded = percent.isFinite ? min(100, max(0, percent)) : 0
        let filled = Int(bounded / 100 * Double(cells))
        return "[" + String(repeating: "█", count: filled)
                   + String(repeating: "░", count: cells - filled) + "]"
    }

}
