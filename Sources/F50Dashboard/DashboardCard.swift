import Cocoa
import SwiftUI

final class DashboardCardState: ObservableObject {
    @Published var panelHeight: CGFloat = 740
    @Published private(set) var snapshot = DashboardSnapshot()
    @Published var selectedDay: String?
    @Published var detailsExpanded = false
    @Published var historyExpanded = false

    func update(_ next: DashboardSnapshot) {
        if next.networkKey != snapshot.networkKey {
            selectedDay = nil; detailsExpanded = false; historyExpanded = false
        }
        if let selected = selectedDay, !next.days.contains(where: { $0.id == selected }) { selectedDay = nil }
        if next.phase == .hidden { detailsExpanded = false }
        if next != snapshot { snapshot = next }
    }
    var inspectedDay: DashboardSnapshot.Day? {
        snapshot.days.first { $0.id == selectedDay } ?? snapshot.days.last
    }
}

private enum DashboardPalette {
    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.408, green: 0.729, blue: 0.776, alpha: 1)
        }
        return NSColor(srgbRed: 0.224, green: 0.561, blue: 0.616, alpha: 1)
    })
}

struct DashboardCard: View {
    @ObservedObject var state: DashboardCardState
    let version: String
    let onAction: (MenuEntry.Action) -> Void
    private var data: DashboardSnapshot { state.snapshot }
    private var accent: Color {
        guard let remaining = data.remainingPercent else { return .secondary }
        return remaining <= 10 ? .red : remaining <= 20 ? .orange : DashboardPalette.teal
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("F50 Dashboard").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !data.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(data.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                        Divider()
                    }
                    rates
                    Divider()
                    if data.phase != .hidden {
                        quota
                        Divider()
                    }
                    chart
                    Divider()
                    if data.phase != .hidden {
                        DisclosureGroup("设备详情", isExpanded: $state.detailsExpanded) {
                            EntryRows(entries: data.details).padding(.top, 10)
                            if !data.updated.isEmpty {
                                Text(data.updated).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 12)
                        Divider()
                    }
                    DisclosureGroup("历史用量", isExpanded: $state.historyExpanded) {
                        EntryRows(entries: data.history).padding(.top, 10)
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            Divider()
            HStack {
                Button { onAction(.settings) } label: { Label("设置", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button { onAction(.refresh) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("打开配置文件") { onAction(.config) }
                    Button("打开数据目录") { onAction(.data) }
                    Divider()
                    Button("退出") { onAction(.quit) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
                    .fixedSize().accessibilityLabel("更多操作")
            }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .font(.system(size: 13)).foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 390, height: state.panelHeight)
        .transaction { $0.animation = nil }
    }

    private var rates: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("实时速率", caption: "本机")
            HStack {
                rate(data.download, label: "↓ 下载")
                Spacer()
                rate(data.upload, label: "↑ 上传")
                Spacer(minLength: 0)
            }
            HStack {
                Label("当前网络", systemImage: "network")
                Spacer()
                Text(data.networkName).fontWeight(.medium).lineLimit(1).help(data.networkName)
            }
            Text("本网络累计　\(data.localTotal)").font(.system(size: 12)).foregroundStyle(.secondary)
            if !data.localAvailable {
                Text("等待有效的本机速率采样").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func rate(_ rate: DashboardSnapshot.Rate, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rate.value).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                Text(rate.unit).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("SIM 卡月度套餐", caption: "估算")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剩余").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(data.remainingGB.map { String(format: "%.2f", $0) } ?? "—")
                            .font(.system(size: 31, weight: .semibold)).monospacedDigit()
                        Text("GB").font(.system(size: 13))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(data.remainingPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                        .font(.system(size: 18, weight: .medium)).monospacedDigit()
                    Text("剩余占比").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.bottom, 3)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4).fill(accent)
                        .frame(width: proxy.size.width * (data.remainingPercent ?? 0) / 100)
                }
            }.frame(height: 8)
                .accessibilityLabel(data.remainingPercent.map { "月度套餐剩余 \(String(format: "%.2f", $0))%" } ?? "套餐余量暂不可用")
            HStack(alignment: .top) {
                Text(data.usedBytes.map { "\(data.remainingGB == nil ? "月度已记录" : "已用") \(Fmt.bytes($0)) / \(Fmt.trim(data.quotaGB)) GB" }
                    ?? "套餐 \(Fmt.trim(data.quotaGB)) GB（手动设置）")
                Spacer(minLength: 5)
                Text(data.reset).foregroundStyle(.secondary)
            }.font(.system(size: 12))
            if !data.quotaNotice.isEmpty {
                Text(data.quotaNotice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if !data.period.isEmpty {
                Text(data.period).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("余量以运营商查询结果为准").font(.system(size: 11)).foregroundStyle(.secondary)
            if !data.signal.isEmpty {
                HStack { Text(data.signal); Spacer(); Text(data.stationCount) }.font(.system(size: 12))
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var chart: some View {
        let scale = DailyChartScale(days: data.days)
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("近七天本机用量", caption: "当前网络 · \(scale.unit)")
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading) {
                    Text(scale.label(scale.ceiling)); Spacer(); Text(scale.label(scale.ceiling / 2)); Spacer(); Text("0")
                }.font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 30, height: 95)
                ForEach(data.days) { day in
                    Button { state.selectedDay = day.id } label: {
                        VStack(spacing: 5) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                if let total = day.total, total > 0 {
                                    RoundedRectangle(cornerRadius: 3).fill(DashboardPalette.teal)
                                        .opacity(state.inspectedDay?.id == day.id ? 1 : 0.55)
                                        .frame(width: 23, height: 95 * scale.fraction(total))
                                } else {
                                    Text(day.total == nil ? "—" : "0").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.frame(height: 95)
                            Text(day.shortLabel).font(.system(size: 11, weight: state.inspectedDay?.id == day.id ? .semibold : .regular))
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).help(day.detail).accessibilityLabel(day.detail)
                }
            }.padding(.top, 3)
            Text(state.inspectedDay?.detail ?? "尚未取得当前网络记录").font(.system(size: 12)).monospacedDigit()
            Text("— 表示未记录，仅含 App 的有效采样").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func sectionTitle(_ title: String, caption: String) -> some View {
        HStack { Text(title).fontWeight(.semibold); Spacer(); Text(caption).font(.system(size: 12)).foregroundStyle(.secondary) }
    }
}

private struct EntryRows: View {
    let entries: [MenuEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                if entry.isSeparator { Divider() }
                else if let children = entry.children {
                    Text(entry.title).fontWeight(.medium)
                    EntryRows(entries: children).padding(.leading, 8)
                } else { Text(entry.title.trimmingCharacters(in: .whitespaces)).textSelection(.enabled) }
            }
        }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// NSHostingController 与状态对象只创建一次，采样不会替换正在浏览的界面。
final class DashboardPopover {
    let state = DashboardCardState()
    let popover = NSPopover()
    init(version: String, onAction: @escaping (MenuEntry.Action) -> Void) {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: DashboardCard(state: state, version: version, onAction: onAction))
    }
    var isShown: Bool { popover.isShown }
    func update(_ snapshot: DashboardSnapshot) { state.update(snapshot) }
    func toggle(from button: NSStatusBarButton) {
        if isShown { popover.performClose(nil); return }
        let available = button.window?.screen?.visibleFrame.height ?? 800
        state.panelHeight = min(state.snapshot.phase == .hidden ? 560 : 740, max(320, available - 70))
        popover.contentSize = NSSize(width: 390, height: state.panelHeight)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func close() { popover.performClose(nil) }
}
