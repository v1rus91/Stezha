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

struct UkraineMap: View {
    let states: [String: RegionAlert]
    var home: String
    var compact = false
    var interactive = true
    @State private var hover: String?
    @State private var hoverPoint: CGPoint = .zero
    @State private var pulse = false
    @Environment(\.colorScheme) private var scheme

    private var calmFill: Color { scheme == .dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    private var border: Color { scheme == .dark ? .white.opacity(0.28) : .white.opacity(0.9) }

    private func fill(_ name: String) -> AnyShapeStyle {
        let s = states[name] ?? .calm
        if s.full {
            return AnyShapeStyle(LinearGradient(colors: [Palette.alert, Palette.alert.mix(with: .black, by: 0.25)], startPoint: .top, endPoint: .bottom))
        }
        if s.active {
            return AnyShapeStyle(LinearGradient(colors: [Palette.partial, Palette.partial.mix(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(calmFill)
    }

    var body: some View {
        GeometryReader { geo in
            let proj = Projection(size: geo.size)
            let names = Array(Geo.shapes.keys)
            ZStack(alignment: .topLeading) {
                // Glow under active oblasts: rasterised once, only its opacity animates.
                ZStack {
                    ForEach(names.filter { states[$0]?.full == true }, id: \.self) { n in
                        proj.path(n).fill(Palette.alert)
                    }
                }
                .blur(radius: compact ? 6 : 10)
                .drawingGroup()
                .opacity(pulse ? 0.55 : 0.2)
                ForEach(names, id: \.self) { n in
                    let p = proj.path(n)
                    p.fill(fill(n))
                        .overlay(p.stroke(border, lineWidth: compact ? 0.6 : 0.9))
                        .brightness(hover == n ? 0.12 : 0)
                }
                // Kyiv city sits inside Kyiv Oblast
                let k = proj.point(Geo.kyiv), r = proj.kyivRadius
                let kyivFill: Color = (states["м. Київ"]?.full ?? false) ? Palette.alert : (states["м. Київ"]?.active ?? false) ? Palette.partial : (scheme == .dark ? Color(white: 0.3) : Color(white: 0.85))
                Circle().fill(kyivFill)
                    .overlay(Circle().stroke(border, lineWidth: 1))
                    .frame(width: r * 2, height: r * 2)
                    .position(k)
                // Home outline
                proj.path(home).stroke(Palette.home, style: StrokeStyle(lineWidth: compact ? 1.6 : 2.4, lineJoin: .round))
                    .shadow(color: Palette.home.opacity(0.6), radius: 4)
                if home == "м. Київ" {
                    Circle().stroke(Palette.home, lineWidth: 2).frame(width: r * 2 + 4, height: r * 2 + 4).position(k)
                }

                if !compact {
                    labels(proj)
                }
                if interactive, let h = hover { tooltip(h).position(x: min(max(hoverPoint.x, 110), geo.size.width - 110), y: max(hoverPoint.y - 54, 40)) }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let pt):
                    hoverPoint = pt
                    let k = proj.point(Geo.kyiv)
                    if hypot(pt.x - k.x, pt.y - k.y) <= proj.kyivRadius + 2 { hover = "м. Київ"; return }
                    hover = names.first { proj.path($0).contains(pt) }
                case .ended: hover = nil
                }
            }
        }
        .aspectRatio(Geo.aspect, contentMode: .fit)
        .onAppear { withAnimation(.easeInOut(duration: 2.2).repeatForever()) { pulse = true } }
    }

    private func labels(_ proj: Projection) -> some View {
        ForEach(Regions.all.filter { $0.uk != "м. Київ" }) { r in
            if let pts = Geo.shapes[r.uk] {
                let c = centroid(pts)
                Text(r.short)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle((states[r.uk]?.active ?? false) ? .white : .secondary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .position(proj.point(c))
                    .allowsHitTesting(false)
            }
        }
    }

    private func centroid(_ pts: [CGPoint]) -> CGPoint {
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in pts.indices {
            let p = pts[i], q = pts[(i + 1) % pts.count]
            let f = p.x * q.y - q.x * p.y
            a += f; cx += (p.x + q.x) * f; cy += (p.y + q.y) * f
        }
        guard a != 0 else { return pts[0] }
        return CGPoint(x: cx / (3 * a), y: cy / (3 * a))
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
        }
        .font(.caption)
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
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
