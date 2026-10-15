import Cocoa
import SwiftUI

final class DashboardCardState: ObservableObject {
    @Published var fixedHeight: CGFloat?
    @Published var layoutHasDevice = false
    var chartRect: CGRect = .zero
    @Published private(set) var snapshot = DashboardSnapshot()
    @Published var selectedDay: String?

    func update(_ next: DashboardSnapshot) {
        if next.networkKey != snapshot.networkKey {
            selectedDay = nil
        }
        if let selected = selectedDay, !next.days.contains(where: { $0.id == selected }) { selectedDay = nil }
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
            HStack {
                Label("当前网络", systemImage: "network")
                Spacer()
                Text(data.networkName).fontWeight(.medium).lineLimit(1).help(data.networkName)
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
            sectionTitle("SIM 卡月度套餐", caption: "估算")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("剩余").font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor))
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(data.remainingGB.map { String(format: "%.2f", $0) } ?? "—")
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("GB").font(.system(size: 13))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(data.remainingPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                        .font(.system(size: 16, weight: .medium)).monospacedDigit()
                    Text("剩余占比").font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
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
                Text(data.reset).foregroundColor(Color(nsColor: .secondaryLabelColor))
            }.font(.system(size: 12))
            if !data.quotaNotice.isEmpty {
                Text(data.quotaNotice).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if !data.period.isEmpty {
                Text(data.period).font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            Text("余量以运营商查询结果为准").font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
            if !data.signal.isEmpty {
                HStack { Text(data.signal); Spacer(); Text(data.stationCount) }.font(.system(size: 12))
            }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var chart: some View {
        let scale = DailyChartScale(days: data.days)
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("近七天本机用量", caption: "当前网络 · \(scale.unit)")
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading) {
                    Text(scale.label(scale.ceiling)); Spacer(); Text(scale.label(scale.ceiling / 2)); Spacer(); Text("0")
                }.font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor)).frame(width: 30, height: 75)
                ForEach(data.days) { day in
                    VStack(spacing: 5) {
                        ZStack(alignment: .bottom) {
                            Color.clear
                            if let total = day.total, total > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(DashboardPalette.teal)
                                    .opacity(state.inspectedDay?.id == day.id ? 1 : 0.55)
                                    .frame(width: 23, height: 75 * scale.fraction(total))
                            } else {
                                Text(day.total == nil ? "—" : "0").font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
                            }
                        }.frame(height: 75)
                        Text(day.shortLabel).font(.system(size: 11, weight: state.inspectedDay?.id == day.id ? .semibold : .regular))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }.frame(maxWidth: .infinity).help(day.detail).accessibilityLabel(day.detail)
                }
            }.padding(.top, 3)
                .background(ChartTrackingRegion(state: state))
            Text(state.inspectedDay?.detail ?? "尚未取得当前网络记录").font(.system(size: 12)).monospacedDigit()
            Text("— 表示未记录，仅含 App 的有效采样").font(.system(size: 11)).foregroundColor(Color(nsColor: .secondaryLabelColor))
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func sectionTitle(_ title: String, caption: String) -> some View {
        HStack { Text(title).fontWeight(.semibold); Spacer(); Text(caption).font(.system(size: 12)).foregroundColor(Color(nsColor: .secondaryLabelColor)) }
    }
}

private struct ChartTrackingRegion: NSViewRepresentable {
    let state: DashboardCardState
    func makeNSView(context: Context) -> ChartRegionNSView { ChartRegionNSView(state: state) }
    func updateNSView(_ view: ChartRegionNSView, context: Context) { view.reportFrame() }
}

private final class ChartRegionNSView: NSView {
    weak var state: DashboardCardState?
    init(state: DashboardCardState) { self.state = state; super.init(frame: .zero) }
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
                state?.chartRect = convert(bounds, to: card); return
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
        let plot = state.chartRect
        let left = plot.minX + 35
        guard plot.contains(point), point.x >= left, plot.width > 35, !state.snapshot.days.isEmpty else {
            state.selectedDay = nil; return
        }
        let index = min(state.snapshot.days.count - 1, Int((point.x - left) / (plot.width - 35) * Double(state.snapshot.days.count)))
        state.selectedDay = state.snapshot.days[index].id
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
