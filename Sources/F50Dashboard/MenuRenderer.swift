import Cocoa

/// 跟踪菜单期间保留菜单项和子菜单对象，避免刷新打断悬停。
final class MenuRenderer {
    private var displayed: [MenuEntry] = []

    func update(_ entries: [MenuEntry], menu: NSMenu, allowStructureChanges: Bool,
                makeItem: (MenuEntry) -> NSMenuItem) {
        if allowStructureChanges && !sameStructure(displayed, entries) {
            menu.removeAllItems()
            for entry in entries { menu.addItem(makeItem(entry)) }
            displayed = entries
        } else {
            updateExisting(menu: menu, displayed: displayed, latest: entries)
        }
    }

    private func sameStructure(_ a: [MenuEntry], _ b: [MenuEntry]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { old, new in
            old.id == new.id && old.action == new.action && old.isSeparator == new.isSeparator
                && (old.children == nil) == (new.children == nil)
                && sameStructure(old.children ?? [], new.children ?? [])
        }
    }

    private func updateExisting(menu: NSMenu, displayed: [MenuEntry], latest: [MenuEntry]) {
        for (old, item) in zip(displayed, menu.items) where !old.isSeparator {
            let next = latest.first { !$0.isSeparator && $0.id == old.id }
            let title = next?.title ?? placeholder(for: old)
            if item.title != title { item.title = title }
            if let submenu = item.submenu {
                updateExisting(menu: submenu, displayed: old.children ?? [], latest: next?.children ?? [])
            }
        }
    }

    private func placeholder(for entry: MenuEntry) -> String {
        if entry.id == "device.status" { return "  设备数据已更新，重新打开菜单查看" }
        if entry.id == "quota.notice" { return "  设备数据暂不可用，请稍后刷新" }
        if entry.id.hasPrefix("device.client.") { return "  接入设备列表已变化" }
        if entry.id.hasPrefix("history.") { return "历史数据已更新，重新打开菜单查看" }
        if entry.id.hasPrefix("warning.") || entry.id == "device.error" { return "提示已更新" }
        if entry.children != nil { return entry.title }
        return "—（数据暂不可用）"
    }
}
