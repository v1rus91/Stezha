import SwiftUI
import CoreLocation
import Observation

/// Live air threats (drones, missiles, KABs…) from NEPTUN (neptun.in.ua). Not an official alert system.
enum ThreatType: String, CaseIterable {
    case missile, ballistic, kab, uav, fpv, recon, mig31k, unknown

    init(api: String) { self = ThreatType(rawValue: api) ?? .unknown }

    var title: String {
        switch self {
        case .uav: T("Шахеди / БпЛА", "Shaheds / UAVs")
        case .fpv: T("FPV-дрони", "FPV drones")
        case .recon: T("Розвідувальні БпЛА", "Recon UAVs")
        case .missile: T("Ракети", "Missiles")
        case .ballistic: T("Балістика", "Ballistic")
        case .kab: T("КАБи", "Guided bombs")
        case .mig31k: T("МіГ-31К", "MiG-31K")
        case .unknown: T("Інше", "Other")
        }
    }
    /// Short plural for "23 шахеди" style counts.
    var short: String {
        switch self {
        case .uav: T("шахеди", "Shaheds")
        case .fpv: "FPV"
        case .recon: T("розвідники", "recon")
        case .missile: T("ракети", "missiles")
        case .ballistic: T("балістика", "ballistic")
        case .kab: T("КАБи", "KABs")
        case .mig31k: T("МіГ-31К", "MiG-31K")
        case .unknown: T("інше", "other")
        }
    }
    var symbol: String {
        switch self {
        case .uav: "airplane"
        case .fpv: "scope"
        case .recon: "binoculars.fill"
        case .missile: "flame.fill"
        case .ballistic: "arrow.up.forward"
        case .kab: "shippingbox.fill"
        case .mig31k: "airplane.departure"
        case .unknown: "questionmark"
        }
    }
    var color: Color {
        switch self {
        case .uav: Color(red: 0.71, green: 0.36, blue: 1.0)
        case .fpv: Color(red: 0.2, green: 0.85, blue: 0.72)
        case .recon: Color(red: 0.35, green: 0.78, blue: 0.98)
        case .missile: Color(red: 1.0, green: 0.18, blue: 0.47)
        case .ballistic: Color(red: 0.9, green: 0.0, blue: 0.24)
        case .kab: Color(red: 0.64, green: 0.52, blue: 0.37)
        case .mig31k, .unknown: Color(white: 0.6)
        }
    }
}

struct Threat: Identifiable, Equatable {
    let id: String
    let type: ThreatType
    let title: String
    let region: String
    let locality: String
    let coord: CGPoint            // lon/lat, same space as the map outlines
    let heading: Double?
    let count: Int
    let areaOnly: Bool            // the point is just the region centroid: never draw or measure it
    let advisory: Bool            // an observation (e.g. MiG-31K takeoff), not a shelter signal
    let updatedAt: Date?

    var place: String { [locality, region.replacingOccurrences(of: " область", with: " обл.")].filter { !$0.isEmpty }.joined(separator: ", ") }

    func distance(to loc: CLLocation) -> Double? {
        areaOnly ? nil : CLLocation(latitude: coord.y, longitude: coord.x).distance(from: loc)
    }
}

@Observable @MainActor
final class ThreatStore {
    var threats: [Threat] = []
    var lastUpdate: Date?
    var error: String?

    static let site = URL(string: "https://neptun.in.ua")!
    var enabled: Bool { UserDefaults.standard.object(forKey: "threatsEnabled") as? Bool ?? true }

    /// The API asks for at most one request per 5 s.
    private let pollInterval: Double = 10
    private let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Points that may be drawn on the map.
    var mapped: [Threat] { threats.filter { !$0.areaOnly } }
    /// Real threats (not advisories), with group sizes.
    var total: Int { threats.filter { !$0.advisory }.reduce(0) { $0 + $1.count } }

    func counts(_ list: [Threat]? = nil) -> [(ThreatType, Int)] {
        var c: [ThreatType: Int] = [:]
        for t in list ?? threats { c[t.type, default: 0] += t.count }
        return ThreatType.allCases.compactMap { k in c[k].map { (k, $0) } }
    }

    func inRegion(_ oblast: String) -> [Threat] { threats.filter { $0.region == oblast && !$0.advisory } }

    func nearest(to loc: CLLocation?) -> (Threat, Double)? {
        guard let loc else { return nil }
        return threats.filter { !$0.advisory }.compactMap { t in t.distance(to: loc).map { (t, $0) } }.min { $0.1 < $1.1 }
    }

    /// Nearest first when the location is known, otherwise the home oblast first, then freshest.
    func sorted(home: String, loc: CLLocation?) -> [Threat] {
        threats.sorted { a, b in
            if let loc {
                let da = a.distance(to: loc) ?? .infinity, db = b.distance(to: loc) ?? .infinity
                if da != db { return da < db }
            }
            if (a.region == home) != (b.region == home) { return a.region == home }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }
    }

    func run() async {
        while !Task.isCancelled {
            if enabled { await poll() }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    func setEnabled(_ on: Bool) {
        if on {
            Task { await poll() }
        } else {
            withAnimation(.smooth) { threats = [] }
            lastUpdate = nil
            error = nil
        }
    }

    func poll() async {
        var req = URLRequest(url: URL(string: "https://neptun.in.ua/api/v1/threats")!)
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) {
                throw NSError(domain: "Stezha", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "NEPTUN: HTTP \(h.statusCode)"])
            }
            let list = try decode(data)
            guard enabled else { return }
            if list != threats { withAnimation(.smooth) { threats = list } }
            lastUpdate = .now
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func decode(_ data: Data) throws -> [Threat] {
        struct Root: Decodable { let threats: [Lossy] }
        struct Lossy: Decodable {
            let t: Raw?
            init(from d: Decoder) throws { t = try? Raw(from: d) }
        }
        struct Raw: Decodable {
            let id: String
            let type: String
            let title: String?
            let region: String?
            let locality: String?
            let lat: Double
            let lon: Double
            let heading: Double?
            let count: Int?
            let status: String?
            let areaOnly: Bool?
            let advisory: Bool?
            let updatedAt: String?
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return root.threats.compactMap(\.t).filter { $0.status == nil || $0.status == "active" }.map { r in
            let type = ThreatType(api: r.type)
            return Threat(
                id: r.id, type: type, title: r.title ?? type.title,
                region: r.region ?? "", locality: r.locality ?? "",
                coord: CGPoint(x: r.lon, y: r.lat), heading: r.heading,
                count: max(1, r.count ?? 1),
                areaOnly: r.areaOnly ?? false,
                advisory: r.advisory ?? (type == .mig31k),
                updatedAt: r.updatedAt.flatMap { iso.date(from: $0) ?? isoFrac.date(from: $0) }
            )
        }
    }
}

// MARK: - Views

/// Threat markers over `UkraineMap`, drawn in one Canvas (no per-marker views, no animation).
struct ThreatLayer: View {
    let threats: [Threat]
    let proj: Projection
    var compact = false

    var body: some View {
        Canvas { ctx, _ in
            let r: CGFloat = compact ? 3.2 : 7
            for t in threats where !t.areaOnly {
                let p = proj.point(t.coord)
                let c = t.type.color.opacity(t.advisory ? 0.55 : 1)
                // Heading: a short line pointing where the target is flying.
                if let h = t.heading, !t.advisory {
                    let a = (h - 90) * .pi / 180
                    let len = r * (compact ? 3.2 : 2.6)
                    var line = Path()
                    line.move(to: p)
                    line.addLine(to: CGPoint(x: p.x + cos(a) * len, y: p.y + sin(a) * len))
                    ctx.stroke(line, with: .color(c.opacity(0.85)), style: StrokeStyle(lineWidth: compact ? 1.2 : 1.8, lineCap: .round))
                }
                let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(c))
                ctx.stroke(dot, with: .color(.white.opacity(0.95)), lineWidth: compact ? 0.8 : 1.2)
                if !compact {
                    var sym = ctx.resolve(Image(systemName: t.type.symbol))
                    sym.shading = .color(.white)
                    let s = r * 1.1
                    ctx.draw(sym, in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
                    if t.count > 1 {
                        let txt = ctx.resolve(Text("\(t.count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                        ctx.draw(txt, at: CGPoint(x: p.x + r + 5, y: p.y - r), anchor: .center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// "✈︎ 23 шахеди  ◎ 5 FPV" summary by type; drops the words when they don't fit.
struct ThreatChips: View {
    let counts: [(ThreatType, Int)]
    var size: CGFloat = 11

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labeled: true)
            row(labeled: false)
        }
        .font(.system(size: size, weight: .semibold))
    }

    private func row(labeled: Bool) -> some View {
        HStack(spacing: labeled ? 10 : 8) {
            ForEach(counts, id: \.0) { type, n in
                HStack(spacing: 3) {
                    Image(systemName: type.symbol).foregroundStyle(type.color)
                    Text("\(n)").monospacedDigit()
                    if labeled { Text(type.short).fontWeight(.regular).opacity(0.75) }
                }
                .fixedSize()
                .help(type.title)
            }
        }
    }

    /// "3 шахеди, 1 FPV"
    static func text(_ counts: [(ThreatType, Int)]) -> String {
        counts.map { "\($0.1) \($0.0.short)" }.joined(separator: ", ")
    }
}

/// Required attribution: a visible link to NEPTUN next to the data.
struct NeptunCredit: View {
    var body: some View {
        Link(destination: ThreatStore.site) {
            Text(T("Загрози: NEPTUN", "Threats: NEPTUN")).underline()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

enum Dist {
    static func km(_ m: Double) -> String {
        m < 10_000 ? String(format: T("%.1f км", "%.1f km"), m / 1000) : T("\(Int(m / 1000)) км", "\(Int(m / 1000)) km")
    }
    /// Arrow glyph for a compass heading.
    static func arrow(_ h: Double) -> String {
        ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"][Int((h.truncatingRemainder(dividingBy: 360) + 382.5) / 45) % 8]
    }
}
