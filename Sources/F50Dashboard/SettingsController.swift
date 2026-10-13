import Cocoa

final class SettingsController: NSWindowController {
    private var config: Config
    private let networkKey: String?
    private let onSave: (Config) -> Void
    private let quota = NSTextField()
    private let localPoll = NSTextField()
    private let routerPoll = NSTextField()
    private let gateway = NSTextField()
    private let interface = NSTextField()
    private let networkName = NSTextField()
    private let rates = NSButton(checkboxWithTitle: "菜单栏显示实时速率", target: nil, action: nil)
    private let alerts = NSButton(checkboxWithTitle: "启用 80%、90%、100% 配额提醒", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")

    init(config: Config, networkKey: String?, onSave: @escaping (Config) -> Void) {
        self.config = config; self.networkKey = networkKey; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "F50 Dashboard 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        quota.stringValue = Fmt.trim(config.quotaGB)
        localPoll.stringValue = Fmt.trim(config.localPollSec)
        routerPoll.stringValue = Fmt.trim(config.routerPollSec)
        gateway.stringValue = config.routerGateway
        interface.stringValue = config.interface
        networkName.stringValue = networkKey.flatMap { config.networkNames[$0] } ?? ""
        networkName.isEnabled = networkKey != nil
        rates.state = config.showRateInTitle ? .on : .off
        alerts.state = config.enableQuotaAlerts ? .on : .off
        let rows: [[NSView]] = [
            [NSTextField(labelWithString: "套餐额度（GB）"), quota],
            [NSTextField(labelWithString: "本机刷新（1–60 秒）"), localPoll],
            [NSTextField(labelWithString: "路由器刷新（5–3600 秒）"), routerPoll],
            [NSTextField(labelWithString: "管理地址"), gateway],
            [NSTextField(labelWithString: "网卡"), interface],
            [NSTextField(labelWithString: "当前网络名称"), networkName]
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        message.font = NSFont.systemFont(ofSize: 11)
        message.stringValue = "管理地址和网卡可填 auto。额度与路由器读数仅用于估算；每日用量只统计本机在 App 运行期间的流量。"
        let save = NSButton(title: "保存并生效", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"
        let stack = NSStackView(views: [grid, rates, alerts, message, save])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func saveSettings() {
        guard let q = Double(quota.stringValue), let local = Double(localPoll.stringValue),
              let router = Double(routerPoll.stringValue) else {
            message.stringValue = "额度和刷新间隔必须填写数字"
            return
        }
        var next = config
        next.quotaGB = q; next.localPollSec = local; next.routerPollSec = router
        next.routerGateway = gateway.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        next.interface = interface.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        next.showRateInTitle = rates.state == .on
        next.enableQuotaAlerts = alerts.state == .on
        if let key = networkKey {
            let name = networkName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { next.networkNames.removeValue(forKey: key) }
            else { next.networkNames[key] = name }
        }
        do {
            try next.save()
            onSave(next)
            close()
        } catch { message.stringValue = error.localizedDescription }
    }
}
