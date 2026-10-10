import SwiftUI

// MARK: - Localization (Ukrainian / English)

enum Loc {
    static var en: Bool {
        switch UserDefaults.standard.string(forKey: "lang") ?? "system" {
        case "en": return true
        case "uk": return false
        default:
            let p = Locale.preferredLanguages.first ?? "en"
            return !(p.hasPrefix("uk") || p.hasPrefix("ru"))
        }
    }
    static var locale: Locale { Locale(identifier: en ? "en_US" : "uk_UA") }
}

func T(_ uk: String, _ en: String) -> String { Loc.en ? en : uk }

enum Fmt {
    /// 1:02:03 or 12:03
    static func timer(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
    /// "1 год 5 хв" / "1h 5m", or days for very long alerts.
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = s / 3600 % 24, m = s / 60 % 60
        if d > 0 { return T("\(d) дн \(h) год", "\(d)d \(h)h") }
        if h > 0 { return T("\(h) год \(m) хв", "\(h)h \(m)m") }
        return T("\(max(m, 1)) хв", "\(max(m, 1))m")
    }
    static func time(_ d: Date) -> String {
        d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Loc.locale))
    }
    static func dayTime(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return time(d) }
        return d.formatted(Date.FormatStyle().day().month(.abbreviated).hour().minute().locale(Loc.locale))
    }
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Loc.locale
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: .now)
    }
}

// MARK: - Regions

struct Region: Identifiable, Hashable {
    let uk: String
    let en: String
    let uid: Int
    var id: String { uk }
    var name: String { Loc.en ? en : uk }
    var short: String {
        if uid == 29 { return T("Крим", "Crimea") }
        return Loc.en ? en.replacingOccurrences(of: " Oblast", with: "")
                      : uk.replacingOccurrences(of: " область", with: "")
    }
}

enum Regions {
    static let all: [Region] = [
        Region(uk: "Вінницька область", en: "Vinnytsia Oblast", uid: 4),
        Region(uk: "Волинська область", en: "Volyn Oblast", uid: 8),
        Region(uk: "Дніпропетровська область", en: "Dnipropetrovsk Oblast", uid: 9),
        Region(uk: "Донецька область", en: "Donetsk Oblast", uid: 28),
        Region(uk: "Житомирська область", en: "Zhytomyr Oblast", uid: 10),
        Region(uk: "Закарпатська область", en: "Zakarpattia Oblast", uid: 11),
        Region(uk: "Запорізька область", en: "Zaporizhzhia Oblast", uid: 12),
        Region(uk: "Івано-Франківська область", en: "Ivano-Frankivsk Oblast", uid: 13),
        Region(uk: "Київська область", en: "Kyiv Oblast", uid: 14),
        Region(uk: "Кіровоградська область", en: "Kirovohrad Oblast", uid: 15),
        Region(uk: "Луганська область", en: "Luhansk Oblast", uid: 16),
        Region(uk: "Львівська область", en: "Lviv Oblast", uid: 27),
        Region(uk: "Миколаївська область", en: "Mykolaiv Oblast", uid: 17),
        Region(uk: "Одеська область", en: "Odesa Oblast", uid: 18),
        Region(uk: "Полтавська область", en: "Poltava Oblast", uid: 19),
        Region(uk: "Рівненська область", en: "Rivne Oblast", uid: 5),
        Region(uk: "Сумська область", en: "Sumy Oblast", uid: 20),
        Region(uk: "Тернопільська область", en: "Ternopil Oblast", uid: 21),
        Region(uk: "Харківська область", en: "Kharkiv Oblast", uid: 22),
        Region(uk: "Херсонська область", en: "Kherson Oblast", uid: 23),
        Region(uk: "Хмельницька область", en: "Khmelnytskyi Oblast", uid: 3),
        Region(uk: "Черкаська область", en: "Cherkasy Oblast", uid: 24),
        Region(uk: "Чернівецька область", en: "Chernivtsi Oblast", uid: 26),
        Region(uk: "Чернігівська область", en: "Chernihiv Oblast", uid: 25),
        Region(uk: "Автономна Республіка Крим", en: "Crimea", uid: 29),
        Region(uk: "м. Київ", en: "Kyiv City", uid: 31),
    ]
    static func named(_ uk: String) -> Region? { all.first { $0.uk == uk } }
    static let defaultHome = "Черкаська область"
}

// MARK: - Palette

enum Palette {
    static let alert = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let partial = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let calm = Color(red: 0.2, green: 0.84, blue: 0.48)
    static let home = Color(red: 1.0, green: 0.84, blue: 0.0)
    static let blue = Color(red: 0.0, green: 0.42, blue: 0.95)
}

struct Backdrop: View {
    var tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let a = scheme == .dark ? 0.32 : 0.2
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: [
                tint.opacity(a), .clear, Palette.blue.opacity(a * 0.6),
                .clear, tint.opacity(a * 0.2), .clear,
                Palette.home.opacity(a * 0.35), .clear, tint.opacity(a * 0.6),
            ]
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.8), value: tint)
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = 24
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { .regular.tint($0.opacity(0.14)) } ?? .regular, in: .rect(cornerRadius: radius))
    }
}

struct CardTitle: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// Pulsing dot used for "live" states.
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 10
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.5)).scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 1))
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

extension Date {
    /// Fixed anchor for TimelineView schedules. Using `.now` would restart the schedule on every render.
    static let tickStart = Date(timeIntervalSinceReferenceDate: 0)
}
