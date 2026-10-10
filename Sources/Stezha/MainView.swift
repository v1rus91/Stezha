import SwiftUI
import Charts
import AppKit

struct MainView: View {
    @Environment(AlertStore.self) private var store
    @Environment(ThreatStore.self) private var threats
    /// SwiftUI keeps a closed window's view alive; render nothing then so animations stop.
    @State private var visible = false

    private var status: HomeStatus { store.homeStatus }
    private var tint: Color { status == .alert ? Palette.alert : (status == .partial && !store.hasPlace) ? Palette.partial : Palette.calm }

    var body: some View {
        ZStack {
            if visible { content }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            guard let w = n.object as? NSWindow, w.identifier?.rawValue.hasPrefix("main") ?? false else { return }
            visible = w.occlusionState.contains(.visible)
        }
    }

    private var content: some View {
        ZStack {
            Backdrop(tint: tint)
            ScrollView {
                // One container renders all glass cards in a single pass, which keeps scrolling smooth.
                GlassEffectContainer(spacing: 0) {
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 18) {
                        hero
                        statsCard.frame(width: 300)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        mapCard
                        activeCard.frame(width: 300)
                    }
                    if threats.enabled { threatsCard }
                    HStack(alignment: .top, spacing: 18) {
                        timelineCard
                        countryCard.frame(width: 300)
                    }
                    historyCard
                    footer
                }
                }
                .padding(28)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.poll(); await store.loadHistory(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(T("Оновити", "Refresh"))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }.help(T("Налаштування", "Settings"))
            }
        }
        .navigationTitle(T("Стежа", "Stezha"))
    }

    // MARK: hero

    private var hero: some View {
        GlassCard(padding: 26, radius: 28, tint: tint) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 96, height: 96)
                    if status == .alert { PulseDot(color: tint.opacity(0.35), size: 96) }
                    Image(systemName: tint == Palette.calm ? "checkmark.shield.fill" : "light.beacon.max.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(tint.gradient)
                        .symbolEffect(.pulse, options: .repeating, isActive: status == .alert)
                }
                VStack(alignment: .leading, spacing: 6) {
                    placePicker
                    Text(status == .alert ? T("Тривога у вашому районі", "Air raid alert in your area")
                         : status == .partial ? (store.hasPlace ? T("У вашому районі спокійно", "Your area is clear") : T("Тривога в частині області", "Alert in part of the oblast"))
                         : T("Тривоги немає", "No alert"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    if let since = store.homeSince, status == .alert {
                        TimelineView(.periodic(from: .tickStart, by: 1)) { _ in
                            Text(Fmt.timer(Date.now.timeIntervalSince(since)))
                                .font(.system(size: 44, weight: .heavy, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                        }
                        Text(T("Оголошено о ", "Started at ") + Fmt.dayTime(since)).foregroundStyle(.secondary)
                    } else if let last = store.homeHistory.first(where: { $0.end != nil }), let end = last.end {
                        Text(T("Остання тривога завершилась ", "Last alert ended ") + Fmt.relative(end)
                             + " · " + T("тривала ", "lasted ") + Fmt.duration(end.timeIntervalSince(last.start)))
                            .foregroundStyle(.secondary)
                    }
                    if let (t, d) = threats.nearest(to: store.location), d < 100_000 {
                        Label(T("Найближча загроза: ", "Nearest threat: ") + t.title + " · " + Dist.km(d) + (t.heading.map { " " + Dist.arrow($0) } ?? ""),
                              systemImage: t.type.symbol)
                            .font(.callout.weight(.semibold)).foregroundStyle(t.type.color)
                    }
                    if status != .alert, !store.otherRaids.isEmpty {
                        let list = store.otherRaids.map(\.title)
                        Label(T("Тривога в області: ", "Alert elsewhere in the oblast: ") + list.prefix(3).joined(separator: ", ") + (list.count > 3 ? " …" : ""),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Palette.partial).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var placePicker: some View {
        @Bindable var store = store
        return Menu {
            Picker(T("Область", "Oblast"), selection: $store.home) {
                ForEach(Regions.all) { Text($0.name).tag($0.uk) }
            }
            if !store.knownRaions.isEmpty {
                Picker(T("Район", "Raion"), selection: $store.homeRaion) {
                    Text(T("Уся область", "Whole oblast")).tag("")
                    ForEach(store.knownRaions, id: \.self) { Text($0).tag($0) }
                }
            }
        } label: {
            Label([store.homeLocality, store.homeRaion, store.homeRegion.short].filter { !$0.isEmpty }.joined(separator: ", "),
                  systemImage: store.locationState == .found ? "location.fill" : "mappin.and.ellipse")
                .font(.headline)
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }

    // MARK: stats

    private var statsCard: some View {
        let day = store.stats(since: Calendar.current.startOfDay(for: .now))
        let week = store.stats(since: .now.addingTimeInterval(-7 * 86400))
        let month = store.stats(since: .now.addingTimeInterval(-30 * 86400))
        return GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: T("Статистика", "Statistics"), symbol: "chart.bar.xaxis", tint: Palette.blue)
                if store.hasToken {
                    statRow(T("Сьогодні", "Today"), "\(day.count)", Fmt.duration(day.total))
                    statRow(T("7 днів", "7 days"), "\(week.count)", Fmt.duration(week.total))
                    statRow(T("30 днів", "30 days"), "\(month.count)", Fmt.duration(month.total))
                    Divider()
                    HStack {
                        Text(T("Найдовша за місяць", "Longest this month")).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.duration(month.longest)).fontWeight(.semibold)
                    }
                    .font(.callout)
                    HStack {
                        Text(T("Середня", "Average")).foregroundStyle(.secondary)
                        Spacer()
                        Text(month.count > 0 ? Fmt.duration(month.total / Double(month.count)) : "—").fontWeight(.semibold)
                    }
                    .font(.callout)
                } else {
                    noToken
                }
            }
        }
    }

    private func statRow(_ label: String, _ count: String, _ total: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(count).font(.title3.bold().monospacedDigit())
            Text(T("трив.", "alerts")).font(.caption).foregroundStyle(.secondary)
            Text(total).font(.callout.monospacedDigit()).frame(width: 92, alignment: .trailing)
        }
    }

    private var noToken: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Історія та статистика доступні з ключем alerts.in.ua.", "History and stats need an alerts.in.ua API key."))
                .font(.callout).foregroundStyle(.secondary)
            SettingsLink { Text(T("Додати ключ", "Add key")) }.buttonStyle(.glass)
        }
    }

    // MARK: map

    private var mapCard: some View {
        GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(title: T("Карта тривог", "Alert map"), symbol: "map.fill", tint: Palette.alert)
                    Spacer()
                    MapLegend()
                }
                UkraineMap(states: store.states, home: store.home, threats: threats.mapped)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 340)
                if !threats.threats.isEmpty {
                    HStack {
                        ThreatChips(counts: threats.counts())
                        Spacer()
                        NeptunCredit()
                    }
                }
            }
        }
    }

    private var activeCard: some View {
        GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: T("Зараз", "Right now"), symbol: "dot.radiowaves.left.and.right", tint: Palette.alert)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.activeCount)").font(.system(size: 40, weight: .heavy, design: .rounded)).contentTransition(.numericText())
                    Text(T("з \(Regions.all.count) регіонів", "of \(Regions.all.count) regions")).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("\(store.fullCount) " + T("повністю", "full"), systemImage: "circle.fill").foregroundStyle(Palette.alert)
                    Label("\(store.activeCount - store.fullCount) " + T("частково", "partial"), systemImage: "circle.fill").foregroundStyle(Palette.partial)
                }
                .font(.caption).labelStyle(SmallDotLabel())
                Divider()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.activeRegions, id: \.0.id) { r, s in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Circle().fill(s.full ? Palette.alert : Palette.partial).frame(width: 8, height: 8)
                                    Text(r.short).fontWeight(r.uk == store.home ? .bold : .regular)
                                    Spacer()
                                    if let d = s.earliest {
                                        TimelineView(.periodic(from: .tickStart, by: 30)) { _ in
                                            Text(Fmt.duration(Date.now.timeIntervalSince(d))).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                }
                                if !s.full, !s.raids.isEmpty {
                                    Text(s.raids.map(\.title).prefix(3).joined(separator: ", ") + (s.raids.count > 3 ? " +\(s.raids.count - 3)" : ""))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        .padding(.leading, 16)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
        }
    }

    // MARK: threats

    private var threatsCard: some View {
        let list = threats.sorted(home: store.home, loc: store.location)
        return GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(title: T("Загрози в повітрі", "Air threats"), symbol: "scope", tint: ThreatType.missile.color)
                    if threats.total > 0 {
                        Text("\(threats.total)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ThreatChips(counts: threats.counts(), size: 13)
                }
                if list.isEmpty {
                    Text(threats.error ?? (threats.lastUpdate == nil ? T("Завантаження…", "Loading…") : T("Зараз активних цілей немає", "No active targets right now")))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 8) {
                        ForEach(list.prefix(16)) { t in threatRow(t) }
                    }
                    if list.count > 16 {
                        Text(T("…ще \(list.count - 16)", "…\(list.count - 16) more")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(T("Не офіційне оповіщення: дані моніторингових каналів, можливі неточності. Орієнтуйтесь на сирени.",
                           "Not an official warning: monitoring-channel data, may be inaccurate. Follow the sirens."))
                    Spacer()
                    NeptunCredit()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func threatRow(_ t: Threat) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(t.type.color.opacity(t.advisory ? 0.12 : 0.22)).frame(width: 30, height: 30)
                Image(systemName: t.type.symbol).foregroundStyle(t.type.color.opacity(t.advisory ? 0.6 : 1))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).fontWeight(t.region == store.home ? .semibold : .regular).lineLimit(1)
                Text(t.areaOnly ? T("по області · ", "region-wide · ") + t.region : t.place)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let loc = store.location, let d = t.distance(to: loc) {
                    Text(Dist.km(d)).font(.callout.monospacedDigit())
                        .foregroundStyle(d < 50_000 && !t.advisory ? Palette.alert : .primary)
                }
                HStack(spacing: 4) {
                    if let h = t.heading, !t.areaOnly { Text(Dist.arrow(h)) }
                    if let u = t.updatedAt { Text(Fmt.time(u)) }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: charts

    private var timelineCard: some View {
        let from = Date.now.addingTimeInterval(-24 * 3600)
        let items = store.history.filter { ($0.end ?? .now) > from }
        return GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: T("Останні 24 години · ", "Last 24 hours · ") + store.homeRegion.short, symbol: "clock.fill", tint: Palette.partial)
                if !store.hasToken {
                    noToken
                } else if items.isEmpty {
                    Text(T("За добу тривог не було 🎉", "No alerts in the last 24 hours 🎉")).foregroundStyle(.secondary).frame(height: 160)
                } else {
                    Chart(items) { h in
                        RectangleMark(xStart: .value("s", max(h.start, from)), xEnd: .value("e", h.end ?? .now),
                                      y: .value("r", short(h.title)), height: .ratio(0.6))
                            .foregroundStyle(h.title == store.homeRaion || h.title == store.home ? Palette.alert : Palette.partial)
                            .cornerRadius(4)
                    }
                    .chartXScale(domain: from...Date.now)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                            AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                        }
                    }
                    .frame(height: max(140, CGFloat(Set(items.map(\.title)).count) * 26 + 40))
                }
            }
        }
    }

    private func short(_ t: String) -> String {
        t.replacingOccurrences(of: " район", with: "").replacingOccurrences(of: " територіальна громада", with: " ТГ")
    }

    private var countryCard: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let pts = store.samples.filter { $0.t >= today }
        return GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: T("Україна сьогодні", "Ukraine today"), symbol: "chart.xyaxis.line", tint: Palette.blue)
                if pts.count < 2 {
                    Text(T("Збираю дані… графік з'явиться за кілька хвилин.", "Collecting data… the chart appears in a few minutes."))
                        .font(.callout).foregroundStyle(.secondary).frame(height: 140, alignment: .top)
                } else {
                    Chart(pts, id: \.t) { p in
                        AreaMark(x: .value("t", p.t), y: .value("n", p.n))
                            .foregroundStyle(LinearGradient(colors: [Palette.alert.opacity(0.45), Palette.alert.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.stepEnd)
                        LineMark(x: .value("t", p.t), y: .value("n", p.n))
                            .foregroundStyle(Palette.alert)
                            .interpolationMethod(.stepEnd)
                    }
                    .chartYScale(domain: 0...Regions.all.count)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 4)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                    .frame(height: 150)
                    Text(T("Кількість регіонів у тривозі", "Regions on alert")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: history

    private var historyCard: some View {
        GlassCard(radius: 28) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: T("Журнал тривог · ", "Alert log · ") + store.homeRegion.short, symbol: "list.bullet.rectangle.fill", tint: .secondary)
                if !store.hasToken {
                    noToken
                } else {
                    let rows = Array(store.homeHistory.prefix(14))
                    if rows.isEmpty {
                        Text(T("Немає записів за місяць", "No records this month")).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 8) {
                        ForEach(rows) { h in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(h.end == nil ? Palette.alert : Palette.partial.opacity(0.7)).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(h.title).lineLimit(1)
                                    Text(Fmt.dayTime(h.start) + " – " + (h.end.map(Fmt.time) ?? T("триває", "ongoing")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.duration((h.end ?? .now).timeIntervalSince(h.start)))
                                    .font(.callout.monospacedDigit()).foregroundStyle(h.end == nil ? Palette.alert : .primary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: store.error == nil ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                .foregroundStyle(store.error == nil ? Palette.calm : Palette.partial)
            if let e = store.error {
                Text(e)
            } else if let u = store.lastUpdate {
                TimelineView(.periodic(from: .tickStart, by: 5)) { _ in
                    Text(T("Джерело: ", "Source: ") + store.source + " · " + T("оновлено ", "updated ") + Fmt.relative(u))
                }
            } else {
                Text(T("Завантаження…", "Loading…"))
            }
            Spacer()
            Text(T("Не замінює офіційні сирени та застосунок «Повітряна тривога»", "Not a replacement for official sirens and alert apps"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

struct SmallDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}
