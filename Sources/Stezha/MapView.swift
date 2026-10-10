import SwiftUI

/// Oblast outlines (lon/lat), bundled as Resources/oblasts.json.
enum Geo {
    static let shapes: [String: [CGPoint]] = {
        guard let url = Bundle.main.url(forResource: "oblasts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [[Double]]] else { return [:] }
        return raw.mapValues { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
    }()
    static let kyiv = CGPoint(x: 30.52, y: 50.45)

    static let bounds: CGRect = {
        let pts = shapes.values.flatMap { $0 }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }()
    /// Longitude is squeezed by cos(latitude) so the country keeps its real proportions.
    static let kx = cos(48.5 * .pi / 180)
    static var aspect: CGFloat { bounds.width * kx / bounds.height }
}

struct Projection {
    let size: CGSize
    private let scale: CGFloat
    private let ox: CGFloat
    private let oy: CGFloat

    init(size: CGSize, inset: CGFloat = 4) {
        self.size = size
        let b = Geo.bounds
        let w = b.width * Geo.kx, h = b.height
        scale = min((size.width - inset * 2) / w, (size.height - inset * 2) / h)
        ox = (size.width - w * scale) / 2
        oy = (size.height - h * scale) / 2
    }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ox + (p.x - Geo.bounds.minX) * Geo.kx * scale,
                y: oy + (Geo.bounds.maxY - p.y) * scale)
    }

    func path(_ name: String) -> Path {
        var path = Path()
        guard let pts = Geo.shapes[name], let first = pts.first else { return path }
        path.move(to: point(first))
        for p in pts.dropFirst() { path.addLine(to: point(p)) }
        path.closeSubpath()
        return path
    }

    var kyivRadius: CGFloat { max(4, scale * 0.16) }
}

/// Projected oblast outlines, built once per map size instead of on every render.
@MainActor
enum PathCache {
    private static var cache: [String: [String: Path]] = [:]
    static func paths(_ proj: Projection) -> [String: Path] {
        let key = "\(Int(proj.size.width))x\(Int(proj.size.height))"
        if let p = cache[key] { return p }
        if cache.count > 8 { cache.removeAll() }
        let p = Dictionary(uniqueKeysWithValues: Geo.shapes.keys.map { ($0, proj.path($0)) })
        cache[key] = p
        return p
    }
}

struct UkraineMap: View {
    let states: [String: RegionAlert]
    var home: String
    var compact = false
    var interactive = true
    var threats: [Threat] = []
    @State private var hover: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var pulse = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let proj = Projection(size: geo.size)
            let paths = PathCache.paths(proj)
            let full = paths.filter { states[$0.key]?.full == true }.map(\.value)
            ZStack(alignment: .topLeading) {
                // Glow under active oblasts: rasterised once, only its opacity changes.
                // It pulses only on the small transient maps (notch, popover): a forever animation
                // in the main window re-renders every frame and makes scrolling stutter.
                if !full.isEmpty {
                    ZStack { ForEach(full.indices, id: \.self) { full[$0].fill(Palette.alert) } }
                        .blur(radius: compact ? 6 : 10)
                        .drawingGroup()
                        .opacity(compact ? (pulse ? 0.55 : 0.2) : 0.4)
                }
                MapBase(states: states, home: home, compact: compact, size: geo.size, dark: scheme == .dark)
                    .equatable()
                if let h = hover, let p = paths[h] {
                    p.fill(.white.opacity(0.14)).allowsHitTesting(false)
                }
                if !threats.isEmpty { ThreatLayer(threats: threats, proj: proj, compact: compact) }
                if interactive, let h = hover { tooltip(h).position(x: min(max(hoverPoint.x, 110), geo.size.width - 110), y: max(hoverPoint.y - 54, 40)) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let pt):
                    hoverPoint = pt
                    let k = proj.point(Geo.kyiv)
                    let found = hypot(pt.x - k.x, pt.y - k.y) <= proj.kyivRadius + 2 ? "м. Київ" : paths.first { $0.value.contains(pt) }?.key
                    if found != hover { hover = found }
                case .ended: hover = nil
                }
            }
        }
        .aspectRatio(Geo.aspect, contentMode: .fit)
        .onAppear {
            guard compact else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever()) { pulse = true }
        }
    }

    private func tooltip(_ name: String) -> some View {
        let s = states[name] ?? .calm
        let r = Regions.named(name)
        return VStack(alignment: .leading, spacing: 4) {
            Text(r?.name ?? name).font(.headline)
            if s.full {
                Label(T("Тривога по всій області", "Oblast-wide alert"), systemImage: "light.beacon.max.fill").foregroundStyle(Palette.alert)
                if let d = s.since { Text(T("триває ", "for ") + Fmt.duration(Date.now.timeIntervalSince(d))).foregroundStyle(.secondary) }
            } else if !s.locals.isEmpty {
                ForEach(s.locals.prefix(4)) { l in
                    Label(l.title, systemImage: l.kind.symbol).foregroundStyle(Palette.partial).lineLimit(1)
                }
                if s.locals.count > 4 { Text(T("…ще \(s.locals.count - 4)", "…\(s.locals.count - 4) more")).foregroundStyle(.secondary) }
            } else {
                Label(T("Спокійно", "All clear"), systemImage: "checkmark.shield.fill").foregroundStyle(Palette.calm)
            }
            let n = threats.filter { $0.region == name }.reduce(0) { $0 + $1.count }
            if n > 0 {
                Label(T("Загроз у повітрі: \(n)", "Air threats: \(n)"), systemImage: "scope").foregroundStyle(ThreatType.missile.color)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

/// The static part of the map (fills, borders, Kyiv, home outline, labels) in a single Canvas.
/// Equatable, so hover and parent updates don't redraw it unless the alert data changes.
private struct MapBase: View, Equatable {
    let states: [String: RegionAlert]
    let home: String
    let compact: Bool
    let size: CGSize
    let dark: Bool

    var body: some View {
        Canvas { ctx, size in
            let proj = Projection(size: size)
            let paths = PathCache.paths(proj)
            let calm: Color = dark ? .white.opacity(0.09) : .black.opacity(0.07)
            let border: Color = dark ? .white.opacity(0.28) : .white.opacity(0.9)
            for (name, p) in paths {
                let s = states[name] ?? .calm
                let b = p.boundingRect
                let top = CGPoint(x: b.midX, y: b.minY), bottom = CGPoint(x: b.midX, y: b.maxY)
                if s.full {
                    ctx.fill(p, with: .linearGradient(Gradient(colors: [Palette.alert, Palette.alert.mix(with: .black, by: 0.25)]), startPoint: top, endPoint: bottom))
                } else if s.active {
                    ctx.fill(p, with: .linearGradient(Gradient(colors: [Palette.partial, Palette.partial.mix(with: .black, by: 0.2)]), startPoint: top, endPoint: bottom))
                } else {
                    ctx.fill(p, with: .color(calm))
                }
                ctx.stroke(p, with: .color(border), lineWidth: compact ? 0.6 : 0.9)
            }
            // Kyiv city sits inside Kyiv Oblast
            let k = proj.point(Geo.kyiv), r = proj.kyivRadius
            let ks = states["м. Київ"]
            let kyivFill: Color = (ks?.full ?? false) ? Palette.alert : (ks?.active ?? false) ? Palette.partial : (dark ? Color(white: 0.3) : Color(white: 0.85))
            let kc = Path(ellipseIn: CGRect(x: k.x - r, y: k.y - r, width: r * 2, height: r * 2))
            ctx.fill(kc, with: .color(kyivFill))
            ctx.stroke(kc, with: .color(border), lineWidth: 1)
            // Home outline
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: Palette.home.opacity(0.6), radius: 4))
                if let hp = paths[home] {
                    l.stroke(hp, with: .color(Palette.home), style: StrokeStyle(lineWidth: compact ? 1.6 : 2.4, lineJoin: .round))
                }
                if home == "м. Київ" {
                    l.stroke(Path(ellipseIn: CGRect(x: k.x - r - 2, y: k.y - r - 2, width: r * 2 + 4, height: r * 2 + 4)), with: .color(Palette.home), lineWidth: 2)
                }
            }
            guard !compact else { return }
            ctx.drawLayer { l in
                l.addFilter(.shadow(color: .black.opacity(0.4), radius: 1))
                for reg in Regions.all where reg.uk != "м. Київ" {
                    guard let pts = Geo.shapes[reg.uk] else { continue }
                    let active = states[reg.uk]?.active ?? false
                    let t = l.resolve(Text(reg.short).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(active ? Color.white : Color.secondary))
                    l.draw(t, at: proj.point(Self.centroid(pts)), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let f = p.x * q.y - q.x * p.y
            a += f; cx += (p.x + q.x) * f; cy += (p.y + q.y) * f
        }
        guard a != 0 else { return pts[0] }
        return CGPoint(x: cx / (3 * a), y: cy / (3 * a))
    }
}

struct MapLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(Palette.alert, T("Тривога", "Alert"))
            item(Palette.partial, T("Частина області", "Part of oblast"))
            item(.gray.opacity(0.4), T("Спокійно", "Clear"))
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).stroke(Palette.home, lineWidth: 2).frame(width: 12, height: 9)
                Text(T("Ваша область", "Your oblast"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 9)
            Text(t)
        }
    }
}
