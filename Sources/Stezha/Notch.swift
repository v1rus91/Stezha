import SwiftUI
import AppKit
import Observation

@Observable @MainActor
final class NotchModel {
    var expanded = false
    var notchWidth: CGFloat = 200
    var notchHeight: CGFloat = 32
    var hasNotch = true

    static let expandedSize = CGSize(width: 640, height: 330)
    static let wing: CGFloat = 92          // width added on each side of the notch in the collapsed pill
}

/// Keeps AppKit from pushing the window below the menu bar (which re-triggers layout).
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Borderless panel glued to the top of the screen, around the MacBook notch.
@MainActor
final class NotchController {
    private let store: AlertStore
    private let threats: ThreatStore
    private let model = NotchModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private var autoCollapse: Task<Void, Never>?
    var openMain: () -> Void = {}

    init(store: AlertStore, threats: ThreatStore) {
        self.store = store
        self.threats = threats
    }

    func start() {
        guard UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true else { return }
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.ignoresMouseEvents = true
        let host = NSHostingView(rootView: NotchView(model: model, open: { [weak self] in self?.openMain() }).environment(store).environment(threats))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        layout()
        syncVisibility()

        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { e in handler(e); return e }) { monitors.append(l) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        store.homeChanged = { [weak self] status in
            self?.syncVisibility()
            guard UserDefaults.standard.object(forKey: "notchAutoExpand") as? Bool ?? true else { return }
            self?.flash()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let panel, let s = screen else { return }
        let f = s.frame
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchWidth = f.width - l.width - r.width
            model.notchHeight = s.safeAreaInsets.top
        } else {
            model.hasNotch = false
            model.notchWidth = 180
            model.notchHeight = NSStatusBar.system.thickness
        }
        let size = NotchModel.expandedSize
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// Hot zone = the notch plus its wings; once open, the whole island.
    private func mouseMoved() {
        guard let s = screen else { return }
        let p = NSEvent.mouseLocation
        let f = s.frame
        let w = model.notchWidth + NotchModel.wing * 2
        let hot = NSRect(x: f.midX - w / 2, y: f.maxY - model.notchHeight - 2, width: w, height: model.notchHeight + 2)
        let size = NotchModel.expandedSize
        let open = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height).insetBy(dx: -16, dy: -16)

        if !model.expanded, hot.contains(p) {
            collapseTask?.cancel()
            setExpanded(true)
        } else if model.expanded, !open.contains(p) {
            guard collapseTask == nil else { return }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
                self?.collapseTask = nil
            }
        } else if model.expanded {
            collapseTask?.cancel()
            collapseTask = nil
            autoCollapse?.cancel()
        }
    }

    private var hideTask: Task<Void, Never>?

    private func setExpanded(_ on: Bool) {
        hideTask?.cancel()
        if on { panel?.orderFrontRegardless() }
        withAnimation(.spring(response: 0.42, dampingFraction: on ? 0.78 : 0.9)) { model.expanded = on }
        panel?.ignoresMouseEvents = !on
        if !on {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.syncVisibility()
            }
        }
    }

    /// A collapsed island with nothing to show is taken off screen entirely:
    /// an always-on transparent panel over the menu bar keeps Core Animation redrawing.
    func syncVisibility() {
        guard let panel, !model.expanded else { return }
        let mode = UserDefaults.standard.string(forKey: "notchPill") ?? "never"
        let show = mode == "always" || (mode == "alert" && store.homeStatus != .calm)
        if show { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// Briefly opens the island when the user's status changes.
    private func flash() {
        setExpanded(true)
        autoCollapse?.cancel()
        autoCollapse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            self?.setExpanded(false)
        }
    }
}

// MARK: - View

struct NotchView: View {
    let model: NotchModel
    let open: () -> Void
    @Environment(AlertStore.self) private var store
    @Environment(ThreatStore.self) private var threats
    @AppStorage("notchPill") private var pillMode = "never"   // always | alert | never

    private var status: HomeStatus { store.homeStatus }
    private var statusColor: Color { status == .alert ? Palette.alert : (status == .partial && !store.hasPlace) ? Palette.partial : Palette.calm }
    private var showPill: Bool { pillMode == "always" || (pillMode == "alert" && status != .calm) }

    private var shapeSize: CGSize {
        if model.expanded { return NotchModel.expandedSize }
        let w = model.notchWidth + (showPill ? NotchModel.wing * 2 : 0)
        return CGSize(width: model.hasNotch || showPill ? w : 0, height: model.notchHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(radius: model.expanded ? 28 : 12)
                    .fill(.black)
                    .overlay(alignment: .bottom) {
                        // Status glow along the bottom edge
                        if status != .calm || model.expanded {
                            NotchShape(radius: model.expanded ? 28 : 12)
                                .stroke(statusColor.opacity(model.expanded ? 0.35 : 0.6), lineWidth: 1)
                                .blur(radius: 0.5)
                        }
                    }
                    .shadow(color: status == .alert ? Palette.alert.opacity(0.45) : .black.opacity(model.expanded ? 0.4 : 0), radius: model.expanded ? 18 : 8, y: 4)

                if model.expanded {
                    expanded
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else if showPill {
                    pill.transition(.opacity)
                }
            }
            .frame(width: shapeSize.width, height: shapeSize.height)
            Spacer(minLength: 0)
        }
        .frame(width: NotchModel.expandedSize.width, height: NotchModel.expandedSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // Collapsed: [● Тривога]  notch  [12:34]
    private var pill: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                PulseDot(color: statusColor, size: 7)
                Text(status == .alert ? T("Тривога", "Alert") : status == .partial ? T("Район", "Raion") : T("Спокійно", "Clear"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: NotchModel.wing, alignment: .center)
            Spacer(minLength: model.notchWidth)
            Group {
                if let since = store.homeSince, status != .calm {
                    TimelineView(.periodic(from: .tickStart, by: 1)) { _ in
                        Text(Fmt.timer(Date.now.timeIntervalSince(since)))
                    }
                } else {
                    Text("\(store.activeCount)/\(Regions.all.count)")
                }
            }
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: NotchModel.wing, alignment: .center)
        }
        .frame(height: model.notchHeight)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            // Header row sits beside the camera housing
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "light.beacon.max.fill").foregroundStyle(statusColor)
                    Text(T("Стежа", "Stezha")).font(.system(size: 13, weight: .bold))
                }
                Spacer()
                if let u = store.lastUpdate {
                    TimelineView(.periodic(from: .tickStart, by: 5)) { _ in
                        Text(T("оновлено ", "updated ") + Fmt.relative(u)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 26)
            .frame(height: model.notchHeight)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .trailing, spacing: 2) {
                    UkraineMap(states: store.states, home: store.home, compact: true, threats: threats.mapped)
                    if !threats.threats.isEmpty { NeptunCredit() }
                }
                .frame(width: 330)
                info
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.placeName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Text(status == .alert ? T("Тривога у вашому районі", "Alert in your area") : status == .partial ? (store.hasPlace ? T("У вашому районі спокійно", "Your area is clear") : T("Тривога в області", "Alert in the oblast")) : T("Тривоги немає", "No alert"))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let since = store.homeSince, status == .alert {
                    TimelineView(.periodic(from: .tickStart, by: 1)) { _ in
                        Text(Fmt.timer(Date.now.timeIntervalSince(since)))
                            .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    Text(T("з ", "since ") + Fmt.dayTime(since)).font(.caption).foregroundStyle(.white.opacity(0.55))
                } else if let last = store.homeHistory.first(where: { $0.end != nil }), let end = last.end {
                    Text(T("Відбій ", "Cleared ") + Fmt.relative(end)).font(.callout).foregroundStyle(.white.opacity(0.65))
                }
                if status != .alert, !store.otherRaids.isEmpty {
                    Label(T("Тривога в області: ", "Elsewhere in oblast: ") + store.otherRaids.map(\.title).prefix(2).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Palette.partial).lineLimit(2)
                }
            }

            HStack(spacing: 6) {
                Text("\(store.activeCount)").font(.system(size: 15, weight: .bold).monospacedDigit())
                Text(T("з \(Regions.all.count) регіонів у тривозі", "of \(Regions.all.count) regions on alert"))
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.top, 2)

            if !threats.threats.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ThreatChips(counts: threats.counts(), size: 12)
                    if let (t, d) = threats.nearest(to: store.location) {
                        Text(T("найближча: ", "nearest: ") + t.type.title.lowercased() + " · " + Dist.km(d))
                            .font(.system(size: 11)).foregroundStyle(d < 50_000 ? Palette.alert : .white.opacity(0.6)).lineLimit(1)
                    } else if case let near = threats.inRegion(store.home), !near.isEmpty {
                        Text(T("у вашій області: ", "in your oblast: ") + "\(near.reduce(0) { $0 + $1.count })")
                            .font(.system(size: 11)).foregroundStyle(Palette.partial).lineLimit(1)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.activeRegions.prefix(threats.threats.isEmpty ? 5 : 3), id: \.0.id) { r, s in
                    HStack(spacing: 6) {
                        Circle().fill(s.full ? Palette.alert : Palette.partial).frame(width: 6, height: 6)
                        Text(r.short).lineLimit(1)
                        Spacer()
                        if let d = s.earliest {
                            Text(Fmt.duration(Date.now.timeIntervalSince(d))).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 11))
                }
            }

            Spacer(minLength: 0)
            Button(action: open) {
                Label(T("Відкрити", "Open"), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(statusColor)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Flat top (flush with the screen edge), rounded bottom corners, small concave "ears" at the top like the real notch.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let ear: CGFloat = 6
        let r = min(radius, rect.height / 2, rect.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - ear, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + ear), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ear))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + ear, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
