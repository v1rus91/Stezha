import SwiftUI
import AppKit
import UserNotifications
import Observation

enum AlertKind: String, Codable {
    case airRaid = "air_raid", artillery = "artillery_shelling", urbanFights = "urban_fights"
    case chemical, nuclear, other

    var title: String {
        switch self {
        case .airRaid: T("Повітряна тривога", "Air raid alert")
        case .artillery: T("Загроза артобстрілу", "Artillery threat")
        case .urbanFights: T("Вуличні бої", "Urban fights")
        case .chemical: T("Хімічна загроза", "Chemical threat")
        case .nuclear: T("Радіаційна загроза", "Nuclear threat")
        case .other: T("Тривога", "Alert")
        }
    }
    var symbol: String {
        switch self {
        case .airRaid: "light.beacon.max.fill"
        case .artillery: "burst.fill"
        case .urbanFights: "exclamationmark.shield.fill"
        case .chemical: "aqi.high"
        case .nuclear: "atom"
        case .other: "exclamationmark.triangle.fill"
        }
    }
}

/// One alert inside an oblast that doesn't cover the whole oblast (raion, hromada, city).
struct LocalAlert: Identifiable, Equatable {
    let title: String
    let kind: AlertKind
    let since: Date?
    var id: String { title + kind.rawValue }
}

struct RegionAlert: Equatable {
    var full = false              // the whole oblast is under air raid alert
    var since: Date?              // when the oblast-wide alert started
    var locals: [LocalAlert] = []

    /// Only air raid alerts colour the map; long-running shelling threats would keep border oblasts lit for years.
    var raids: [LocalAlert] { locals.filter { $0.kind == .airRaid } }
    var active: Bool { full || !raids.isEmpty }
    var earliest: Date? { full ? since : raids.compactMap(\.since).min() }
    static let calm = RegionAlert()
}

/// What the user's own place is experiencing.
enum HomeStatus: Equatable {
    case calm, partial, alert
}

struct HistoryAlert: Identifiable, Hashable {
    let id: Int
    let title: String
    let start: Date
    let end: Date?
}

struct Sample: Codable { let t: Date; let n: Int }

@Observable @MainActor
final class AlertStore {
    var states: [String: RegionAlert] = [:]
    var lastUpdate: Date?
    var error: String?
    var loaded = false
    var history: [HistoryAlert] = []          // home oblast, last month (alerts.in.ua only)
    var samples: [Sample] = []                // number of regions in alert over time
    var homeChanged: ((HomeStatus) -> Void)?

    var home: String = UserDefaults.standard.string(forKey: "home") ?? Regions.defaultHome {
        didSet {
            UserDefaults.standard.set(home, forKey: "home")
            homeRaion = ""
            homeLocality = ""
            history = []
            Task { await loadHistory(force: true) }
        }
    }
    var homeRaion: String = UserDefaults.standard.string(forKey: "homeRaion") ?? "" {
        didSet { UserDefaults.standard.set(homeRaion, forKey: "homeRaion") }
    }
    var homeLocality: String = UserDefaults.standard.string(forKey: "homeLocality") ?? "" {
        didSet { UserDefaults.standard.set(homeLocality, forKey: "homeLocality") }
    }

    enum LocationState { case off, searching, found, denied, failed, outside }
    var locationState: LocationState = .off

    func applyLocation(oblast: String, raion: String, locality: String) {
        if home != oblast { home = oblast }
        if !raion.isEmpty || homeRaion.isEmpty { homeRaion = raion }
        homeLocality = locality
    }

    /// Does a raion/hromada/city alert cover the user's own place?
    func coversHome(_ title: String) -> Bool {
        if !homeRaion.isEmpty, title == homeRaion { return true }
        if homeLocality.count >= 4 {
            let stem = String(homeLocality.prefix(max(4, homeLocality.count - 2)))
            if title.contains(stem), !title.hasSuffix("область") { return true }
        }
        return false
    }

    var hasPlace: Bool { !homeRaion.isEmpty || !homeLocality.isEmpty }
    var placeName: String { homeRaion.isEmpty ? (homeLocality.isEmpty ? homeRegion.name : homeLocality) : homeRaion }

    var ownToken: String { UserDefaults.standard.string(forKey: "apiToken")?.trimmingCharacters(in: .whitespaces) ?? "" }
    var usingBuiltinKey: Bool { ownToken.isEmpty }
    var token: String { usingBuiltinKey ? Secrets.alertsKey : ownToken }
    /// A shared built-in key gets rate limited; after a 429 fall back to the keyless source for a while.
    private var throttledUntil: Date?
    var hasToken: Bool { !token.isEmpty && !(throttledUntil.map { $0 > .now } ?? false) }
    var source: String { hasToken ? "alerts.in.ua" : "ubilling.net.ua" }
    private var pollInterval: Double { !hasToken ? 30 : usingBuiltinKey ? 45 : 20 }
    private var historyInterval: Double { usingBuiltinKey ? 1800 : 600 }

    private var lastHomeStatus: HomeStatus?
    private var historyLoadedAt: Date?
    private let decoderISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: derived

    var homeRegion: Region { Regions.named(home) ?? Regions.all[0] }
    var homeState: RegionAlert { states[home] ?? .calm }

    var homeStatus: HomeStatus {
        let s = homeState
        if s.full { return .alert }
        if hasPlace, s.locals.contains(where: { coversHome($0.title) && $0.kind == .airRaid }) { return .alert }
        if !hasPlace, s.locals.contains(where: { $0.kind == .airRaid }) { return .partial }
        return s.locals.contains(where: { $0.kind == .airRaid }) ? .partial : .calm
    }

    /// When the air raid alert that matters to the user started.
    var homeSince: Date? {
        let s = homeState
        if s.full { return s.since }
        let raids = s.locals.filter { $0.kind == .airRaid }
        if hasPlace, let l = raids.first(where: { coversHome($0.title) }) { return l.since }
        return raids.compactMap(\.since).min()
    }

    /// Air raid alerts elsewhere in the home oblast.
    var otherRaids: [LocalAlert] { homeState.locals.filter { $0.kind == .airRaid && !coversHome($0.title) } }

    var activeRegions: [(Region, RegionAlert)] {
        Regions.all.compactMap { r in states[r.uk].flatMap { $0.active ? (r, $0) : nil } }
            .sorted { ($0.1.full ? 0 : 1, $0.1.earliest ?? .now) < ($1.1.full ? 0 : 1, $1.1.earliest ?? .now) }
    }
    var fullCount: Int { states.values.filter(\.full).count }
    var activeCount: Int { states.values.filter(\.active).count }

    /// Raions of the home oblast seen in history or live data, for the picker.
    var knownRaions: [String] {
        Set(history.map(\.title) + homeState.locals.map(\.title))
            .filter { $0.hasSuffix("район") || $0.hasSuffix("raion") }
            .sorted()
    }

    // MARK: polling

    func run() async {
        loadSamples()
        await loadHistory(force: true)
        while !Task.isCancelled {
            await poll()
            if let h = historyLoadedAt, Date.now.timeIntervalSince(h) > historyInterval { await loadHistory(force: true) }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    func poll() async {
        do {
            let new = hasToken ? try await fetchAlertsInUa() : try await fetchUbilling()
            withAnimation(.smooth) { states = new }
            lastUpdate = .now
            error = nil
            loaded = true
            recordSample()
            checkHome()
        } catch {
            if (error as NSError).code == 429, hasToken {
                throttledUntil = .now.addingTimeInterval(300)
                await poll()
                return
            }
            self.error = error.localizedDescription
        }
    }

    private func checkHome() {
        let s = homeStatus
        defer { lastHomeStatus = s }
        guard let prev = lastHomeStatus, prev != s else { return }
        notify(from: prev, to: s)
        homeChanged?(s)
    }

    // MARK: sources

    private func fetchAlertsInUa() async throws -> [String: RegionAlert] {
        var req = URLRequest(url: URL(string: "https://api.alerts.in.ua/v1/alerts/active.json")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)
        struct Root: Decodable { let alerts: [A] }
        struct A: Decodable {
            let location_title: String
            let location_type: String
            let location_oblast: String?
            let started_at: String?
            let alert_type: String
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        var out: [String: RegionAlert] = [:]
        for a in root.alerts {
            let oblast = a.location_oblast ?? a.location_title
            guard Regions.named(oblast) != nil else { continue }
            let since = a.started_at.flatMap { decoderISO.date(from: $0) }
            let kind = AlertKind(rawValue: a.alert_type) ?? .other
            var r = out[oblast] ?? RegionAlert()
            if a.location_title == oblast, kind == .airRaid {
                r.full = true
                r.since = since
            } else {
                r.locals.append(LocalAlert(title: a.location_title, kind: kind, since: since))
            }
            out[oblast] = r
        }
        for k in out.keys { out[k]!.locals.sort { ($0.since ?? .now) < ($1.since ?? .now) } }
        return out
    }

    private func fetchUbilling() async throws -> [String: RegionAlert] {
        let (data, resp) = try await URLSession.shared.data(from: URL(string: "https://ubilling.net.ua/aerialalerts/")!)
        try check(resp)
        struct Root: Decodable { let states: [String: S] }
        struct S: Decodable { let alertnow: Bool; let changed: String? }
        let root = try JSONDecoder().decode(Root.self, from: data)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Europe/Kyiv")
        var out: [String: RegionAlert] = [:]
        for (name, s) in root.states where s.alertnow {
            // This source has no Crimea entry; Sevastopol stands in for it.
            let key = name == "Севастополь" ? "Автономна Республіка Крим" : name
            guard Regions.named(key) != nil else { continue }
            var since = s.changed.flatMap { f.date(from: $0) }
            if let d = since, Calendar.current.component(.year, from: d) < 2022 { since = nil }
            out[key] = RegionAlert(full: true, since: since ?? states[key]?.since ?? (loaded ? .now : nil))
        }
        return out
    }

    private func check(_ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        switch h.statusCode {
        case 200...299: return
        case 401: throw NSError(domain: "Stezha", code: 401, userInfo: [NSLocalizedDescriptionKey: T("Невірний API-ключ", "Invalid API key")])
        case 429: throw NSError(domain: "Stezha", code: 429, userInfo: [NSLocalizedDescriptionKey: T("Забагато запитів, повторю пізніше", "Rate limited, retrying later")])
        default: throw NSError(domain: "Stezha", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode)"])
        }
    }

    // MARK: history

    func loadHistory(force: Bool = false) async {
        guard hasToken else { history = []; return }
        if !force, let h = historyLoadedAt, Date.now.timeIntervalSince(h) < historyInterval { return }
        let uid = homeRegion.uid
        var req = URLRequest(url: URL(string: "https://api.alerts.in.ua/v1/regions/\(uid)/alerts/month_ago.json")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (try? check(resp)) != nil else { return }
        struct Root: Decodable { let alerts: [A] }
        struct A: Decodable { let id: Int; let location_title: String; let started_at: String; let finished_at: String?; let alert_type: String }
        guard let root = try? JSONDecoder().decode(Root.self, from: data) else { return }
        historyLoadedAt = .now
        let list = root.alerts.filter { $0.alert_type == "air_raid" }.compactMap { a -> HistoryAlert? in
            guard let s = decoderISO.date(from: a.started_at) else { return nil }
            return HistoryAlert(id: a.id, title: a.location_title, start: s, end: a.finished_at.flatMap { decoderISO.date(from: $0) })
        }
        withAnimation(.smooth) { history = list.sorted { $0.start > $1.start } }
    }

    /// History filtered to the home raion (or the whole oblast).
    var homeHistory: [HistoryAlert] {
        hasPlace ? history.filter { coversHome($0.title) || $0.title == home } : history
    }

    /// Merged alert intervals for the home place (overlapping raion alerts count once).
    func intervals(since start: Date) -> [(Date, Date)] {
        let items = homeHistory.map { ($0.start, $0.end ?? .now) }.filter { $0.1 > start }.sorted { $0.0 < $1.0 }
        var out: [(Date, Date)] = []
        for (s, e) in items {
            if let last = out.last, s <= last.1 { out[out.count - 1].1 = max(last.1, e) } else { out.append((max(s, start), e)) }
        }
        return out
    }

    struct DayStats { let count: Int; let total: TimeInterval; let longest: TimeInterval }

    func stats(since start: Date) -> DayStats {
        let iv = intervals(since: start)
        let d = iv.map { $0.1.timeIntervalSince($0.0) }
        return DayStats(count: iv.count, total: d.reduce(0, +), longest: d.max() ?? 0)
    }

    // MARK: samples (persisted)

    private var samplesURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Stezha")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "samples.json")
    }

    private func loadSamples() {
        if let d = try? Data(contentsOf: samplesURL), let s = try? JSONDecoder().decode([Sample].self, from: d) { samples = s }
    }

    private func recordSample() {
        if let last = samples.last, Date.now.timeIntervalSince(last.t) < 300, last.n == activeCount { return }
        samples.append(Sample(t: .now, n: activeCount))
        samples.removeAll { Date.now.timeIntervalSince($0.t) > 8 * 86400 }
        if let d = try? JSONEncoder().encode(samples) { try? d.write(to: samplesURL) }
    }

    // MARK: notifications

    private func notify(from: HomeStatus, to: HomeStatus) {
        let d = UserDefaults.standard
        let place = placeName
        let c = UNMutableNotificationContent()
        switch to {
        case .alert:
            guard d.object(forKey: "notifyStart") as? Bool ?? true else { return }
            c.title = "🔴 " + T("Повітряна тривога", "Air raid alert")
            c.body = place + T(". Негайно прямуйте до укриття!", ". Proceed to the nearest shelter!")
        case .partial:
            guard d.object(forKey: "notifyPartial") as? Bool ?? true else { return }
            let where_ = homeState.locals.map(\.title).prefix(3).joined(separator: ", ")
            c.title = "🟠 " + T("Тривога в частині області", "Alert in part of the oblast")
            c.body = where_.isEmpty ? homeRegion.name : where_
        case .calm:
            guard d.object(forKey: "notifyEnd") as? Bool ?? true else { return }
            c.title = "🟢 " + T("Відбій тривоги", "All clear")
            c.body = place
        }
        if d.object(forKey: "sound") as? Bool ?? true {
            c.sound = .default
            if to == .alert { NSSound(named: "Sosumi")?.play() }
        }
        c.interruptionLevel = to == .alert ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
