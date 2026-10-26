import Cocoa
import SwiftUI

final class DashboardCardState: ObservableObject {
    @Published var fixedHeight: CGFloat?
    @Published var layoutHasDevice = false
    var chartRect: CGRect = .zero
    var dayRects: [String: CGRect] = [:]
    @Published private(set) var snapshot = DashboardSnapshot()
    @Published var selectedDay: String?

    func update(_ next: DashboardSnapshot) {
        if let selected = selectedDay, !next.days.contains(where: { $0.id == selected }) { selectedDay = nil }
        dayRects = dayRects.filter { key, _ in next.days.contains { $0.id == key } }
        if next != snapshot { snapshot = next }
    }
    var inspectedDay: DashboardSnapshot.Day? {
        snapshot.days.first { $0.id == selectedDay } ?? snapshot.days.first { $0.isToday }
    }
    var hoveredDay: DashboardSnapshot.Day? { snapshot.days.first { $0.id == selectedDay } }
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
    private var data: DashboardSnapshot { state.snapshot }
    private var remainingColor: Color {
        guard let remaining = data.remainingPercent else { return .primary }
        return remaining <= 10 ? .red : remaining <= 20 ? .orange : .primary
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Traffic Monitor").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(version).font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if !data.warnings.isEmpty {
                    Text(data.warnings.joined(separator: "；"))
                        .font(.system(size: 12)).lineLimit(2)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
                rates
                if state.layoutHasDevice && data.phase != .hidden {
                    Divider().padding(.horizontal, 18)
                    quota
                }
                Divider().padding(.horizontal, 18)
                chart
            }
        }
        .font(.system(size: 13)).foregroundColor(Color(nsColor: .labelColor))
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: state.fixedHeight, alignment: .top)
        .clipped()

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
            HStack(alignment: .top) {
                Label("当前网络", systemImage: "network")
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(data.networkAddress).fontWeight(.medium).lineLimit(1)
                        .help("\(data.networkName)\n\(data.networkAddress)")
                    Text("网关 \(data.gateway.isEmpty ? "未获取" : data.gateway)")
                        .font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                }
            }
            Text("本网络累计　\(data.localTotal)").font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            if !data.localAvailable {
                Text("等待有效的本机速率采样").font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func rate(_ rate: DashboardSnapshot.Rate, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rate.value).font(.system(size: 23, weight: .semibold)).monospacedDigit()
                Text(rate.unit).font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 7) {
            if data.supportsTraffic {
                sectionTitle("SIM 卡月度套餐", caption: "估算")
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("剩余").font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(data.remainingGB.map { String(format: "%.2f", $0) } ?? "—")
                                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                                .foregroundColor(remainingColor)
                            Text("GB").font(.system(size: 13))
                        }
                    }
                    Spacer()
                    Text(data.reset).font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor)).padding(.bottom, 3)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(data.usedBytes.map { "本月已用 \(Fmt.bytes($0)) / \(Fmt.trim(data.quotaGB)) GB" }
                        ?? "套餐 \(Fmt.trim(data.quotaGB)) GB（手动设置）")
                    Spacer(minLength: 5)
                    Text(data.usedPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                        .monospacedDigit()
                        .accessibilityLabel(data.usedPercent.map { "已用占比 \(String(format: "%.2f", $0))%" } ?? "已用占比暂不可用")
                }.font(.system(size: 12))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 4).fill(DashboardPalette.teal)
                            .frame(width: proxy.size.width * (data.usedFraction ?? 0))
                    }
                }.frame(height: 8)
                    .accessibilityLabel(data.usedPercent.map { "月度套餐已用 \(String(format: "%.2f", $0))%" } ?? "套餐已用占比暂不可用")
            } else { sectionTitle(data.deviceName, caption: "路由器") }
            if !data.signal.isEmpty || !data.stationCount.isEmpty {
                HStack { Text(data.signal); Spacer(); Text(data.stationCount) }.font(.system(size: 12))
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("本机月度用量", caption: data.monthTitle)
            HStack(spacing: 8) {
                monthAmount("本月总量", bytes: data.monthTotal)
                monthAmount(data.routerTrafficLabel, bytes: data.monthRouterTotal, color: DashboardPalette.teal)
                monthAmount("其他网络", bytes: data.monthOtherTotal)
            }
            VStack(spacing: 4) {
                ForEach(0..<2) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<16) { column in
                            let index = row * 16 + column
                            if index < data.days.count {
                                dayCell(data.days[index]).id(data.days[index].id)
                            } else { Color.clear.frame(width: 16.5, height: 16.5) }
                        }
                    }
                }
            }.padding(.vertical, 3).background(ChartTrackingRegion(state: state))
                .overlay(alignment: .topLeading) {
                    if let day = state.hoveredDay {
                        Text(day.detail).font(.system(size: 11)).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 260, alignment: .leading).padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            .offset(x: 24, y: -58).allowsHitTesting(false)
                    }
                }.zIndex(1)
            HStack(spacing: 12) {
                legend("有 \(data.routerTrafficLabel) 用量", filled: true, color: DashboardPalette.teal)
                legend("无 \(data.routerTrafficLabel) 用量", filled: true, color: Color.primary.opacity(0.12))
                legend("未记录", filled: false, color: Color.secondary.opacity(0.4))
            }.font(.system(size: 10)).foregroundColor(Color(nsColor: .secondaryLabelColor))
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func monthAmount(_ title: String, bytes: UInt64?, color: Color = Color(nsColor: .labelColor)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            Text(bytes.map(Fmt.bytes) ?? "—").font(.system(size: 14, weight: .semibold))
                .monospacedDigit().foregroundColor(color).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayCell(_ day: DashboardSnapshot.Day) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(day.hasRouterTraffic ? DashboardPalette.teal : day.total != nil ? Color.primary.opacity(0.09) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                day.total == nil ? Color.secondary.opacity(day.isFuture ? 0.12 : 0.35) : .clear,
                lineWidth: 1))
            .shadow(color: DashboardPalette.teal.opacity(state.hoveredDay?.id == day.id ? 0.5 : day.isToday ? 0.3 : 0),
                    radius: state.hoveredDay?.id == day.id ? 4 : 3)
            .frame(width: 16.5, height: 16.5)
            .background(ChartTrackingRegion(state: state, dayID: day.id))
            .help(day.detail).accessibilityLabel(day.detail)
    }

    private func legend(_ title: String, filled: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(filled ? color : .clear)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(filled ? .clear : color, lineWidth: 1))
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    private func sectionTitle(_ title: String, caption: String) -> some View {
        HStack { Text(title).fontWeight(.semibold); Spacer(); Text(caption).font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor)) }
    }
}

private struct ChartTrackingRegion: NSViewRepresentable {
    let state: DashboardCardState
    var dayID: String? = nil
    func makeNSView(context: Context) -> ChartRegionNSView { ChartRegionNSView(state: state, dayID: dayID) }
    func updateNSView(_ view: ChartRegionNSView, context: Context) { view.reportFrame() }
}

private final class ChartRegionNSView: NSView {
    weak var state: DashboardCardState?
    let dayID: String?
    init(state: DashboardCardState, dayID: String?) { self.state = state; self.dayID = dayID; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); reportFrame() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); reportFrame() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); reportFrame() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reportFrame() }
    func reportFrame() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var ancestor = superview
        while let view = ancestor {
            if let card = view as? DashboardMenuCardView {
                let rect = convert(bounds, to: card)
                if let id = dayID {
                    // 月份切换时，正在退出的旧视图仍可能收到一次布局回调。
                    guard state?.snapshot.days.contains(where: { $0.id == id }) == true else { return }
                    state?.dayRects[id] = rect
                }
                else { state?.chartRect = rect }
                return
            }
            ancestor = view.superview
        }
    }
}

final class DashboardCardHostingView: NSHostingView<DashboardCard> {
    override var allowsVibrancy: Bool { false }
    override var isOpaque: Bool { false }
}

/// 透明的原生菜单行。高度只在打开前测量，刷新时保持菜单与行对象稳定。
final class DashboardMenuCardView: NSView {
    let state: DashboardCardState
    let hosting: DashboardCardHostingView
    private let version: String
    private var measuredSize = NSSize(width: 360, height: 1)
    private var pointerTracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { measuredSize }

    init(state: DashboardCardState, version: String) {
        self.state = state; self.version = version
        hosting = DashboardCardHostingView(rootView: DashboardCard(state: state, version: version))
        super.init(frame: .zero)
        addSubview(hosting)
        hosting.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func measureForOpening() {
        state.fixedHeight = nil
        state.layoutHasDevice = state.snapshot.phase != .hidden
        // 在菜单未展开时建立当前布局；承载视图和状态对象始终复用。
        hosting.rootView = DashboardCard(state: state, version: version)
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 1)
        hosting.layoutSubtreeIfNeeded()
        measuredSize = NSSize(width: 360, height: ceil(hosting.fittingSize.height))
        state.fixedHeight = measuredSize.height
        frame.size = measuredSize; hosting.frame = bounds
        invalidateIntrinsicContentSize()
    }
    override func layout() { super.layout(); hosting.frame = bounds }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func updateTrackingAreas() {
        if let tracking = pointerTracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); pointerTracking = area
        super.updateTrackingAreas()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseMoved(with event: NSEvent) { inspect(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { inspect(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { state.selectedDay = nil }
    override func mouseDown(with event: NSEvent) { inspect(at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { inspect(at: convert(event.locationInWindow, from: nil)) }
    func inspect(at point: NSPoint) {
        state.selectedDay = state.snapshot.days.first { day in
            state.dayRects[day.id]?.contains(point) == true
        }?.id
    }
}

final class DashboardCardMenuItem: NSMenuItem {
    override var isHighlighted: Bool { false }
}

final class DashboardMenuCard {
    let state = DashboardCardState()
    let view: DashboardMenuCardView
    let item = DashboardCardMenuItem(title: "", action: nil, keyEquivalent: "")
    init(version: String) {
        view = DashboardMenuCardView(state: state, version: version)
        item.view = view; item.isEnabled = true
    }
    func update(_ snapshot: DashboardSnapshot, allowResize: Bool) {
        state.update(snapshot)
        if allowResize { view.measureForOpening() }
    }
}
