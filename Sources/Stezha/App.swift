import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AlertStore()
    let threats = ThreatStore()
    lazy var notch = NotchController(store: store, threats: threats)
    private var statusItem: StatusItemController?
    lazy var location = LocationService(store: store)
    var openMain: () -> Void = {}
    var openSettings: () -> Void = {}

    func applicationDidFinishLaunching(_ n: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .timeSensitive]) { _, _ in }
        notch.openMain = { [weak self] in self?.openMain() }
        notch.start()
        statusItem = StatusItemController(store: store, delegate: self)
        location.start()
        Task { await store.run() }
        Task { await threats.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func restartNotch() {
        notch.stop()
        notch.start()
    }
}

@main
struct StezhaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("lang") private var lang = "system"

    var body: some Scene {
        Window(T("Стежа", "Stezha"), id: "main") {
            MainView()
                .environment(delegate.store)
                .environment(delegate.threats)
                .frame(minWidth: 980, minHeight: 700)
                .id(lang)
                .background(OpenWindowBridge(delegate: delegate))
        }
        .defaultSize(width: 1120, height: 860)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(delegate: delegate)
                .environment(delegate.store)
                .environment(delegate.threats)
                .id(lang)
        }
    }
}

/// Lets AppKit code (the notch) open the SwiftUI window.
private struct OpenWindowBridge: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.onAppear {
            delegate.openMain = {
                openWindow(id: "main")
                NSApp.activate()
            }
            delegate.openSettings = {
                openSettings()
                NSApp.activate()
            }
        }
    }
}

// MARK: - Menu bar

/// Native status item: SwiftUI's MenuBarExtra label kept re-laying itself out in a loop.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: AlertStore
    private weak var delegate: AppDelegate?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var timer: Timer?
    private var shown: (HomeStatus, String)?

    init(store: AlertStore, delegate: AppDelegate) {
        self.store = store
        self.delegate = delegate
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    @objc private func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        // Built on demand and dropped on close, so the animated map never renders off-screen.
        guard let delegate else { return }
        let host = NSHostingController(rootView: MenuBarMenu(
            open: { [weak self] in self?.popover.performClose(nil); delegate.openMain() },
            settings: { [weak self] in self?.popover.performClose(nil); delegate.openSettings() }
        ).environment(store).environment(delegate.threats))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.popover.contentViewController = nil }
    }

    private func update() {
        let s = store.homeStatus
        let showTimer = UserDefaults.standard.bool(forKey: "menuTimer")
        let title = (showTimer && s == .alert ? store.homeSince.map { " " + Fmt.timer(Date.now.timeIntervalSince($0)) } : nil) ?? ""
        if let shown, shown == (s, title) { return }
        shown = (s, title)
        item.button?.image = Self.icons[s]
        item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        ])
    }

    private static let icons: [HomeStatus: NSImage] = [.calm: make(.calm), .partial: make(.partial), .alert: make(.alert)]

    private static func make(_ s: HomeStatus) -> NSImage {
        let name = s == .calm ? "shield.lefthalf.filled" : "light.beacon.max.fill"
        let color: NSColor = s == .alert ? .systemRed : s == .partial ? .systemOrange : .labelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Стежа")?.withSymbolConfiguration(cfg) ?? NSImage()
        img.isTemplate = s == .calm
        return img
    }
}

struct MenuBarMenu: View {
    let open: () -> Void
    let settings: () -> Void
    @Environment(AlertStore.self) private var store
    @Environment(ThreatStore.self) private var threats

    var body: some View {
        let s = store.homeStatus
        let tint = s == .alert ? Palette.alert : (s == .partial && !store.hasPlace) ? Palette.partial : Palette.calm
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: s == .calm ? "checkmark.shield.fill" : "light.beacon.max.fill")
                    .font(.title2).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s == .alert ? T("Тривога у вашому районі", "Alert in your area") : s == .partial ? (store.hasPlace ? T("У вашому районі спокійно", "Your area is clear") : T("Тривога в частині області", "Alert in part of the oblast")) : T("Тривоги немає", "No alert"))
                        .font(.headline).foregroundStyle(tint)
                    Text(store.placeName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let since = store.homeSince, s != .calm {
                    TimelineView(.periodic(from: .tickStart, by: 1)) { _ in
                        Text(Fmt.timer(Date.now.timeIntervalSince(since))).font(.title3.bold().monospacedDigit())
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular.tint(tint.opacity(0.15)), in: .rect(cornerRadius: 16))

            UkraineMap(states: store.states, home: store.home, compact: true, interactive: false, threats: threats.mapped)
                .frame(height: 170)

            Text(T("\(store.activeCount) з \(Regions.all.count) регіонів у тривозі", "\(store.activeCount) of \(Regions.all.count) regions on alert"))
                .font(.callout).foregroundStyle(.secondary)
            if threats.enabled, !threats.threats.isEmpty {
                HStack {
                    ThreatChips(counts: threats.counts())
                    Spacer()
                    NeptunCredit()
                }
            }

            Divider()
            HStack {
                Button(T("Відкрити Стежу", "Open Stezha"), action: open)
                Spacer()
                Button(action: settings) { Image(systemName: "gearshape") }
                    .help(T("Налаштування", "Settings"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help(T("Вийти", "Quit"))
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - Settings

extension Binding {
    func onSet(_ f: @escaping () -> Void) -> Binding {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; f() })
    }
}

struct SettingsView: View {
    let delegate: AppDelegate
    @Environment(AlertStore.self) private var store
    @AppStorage("lang") private var lang = "system"
    @AppStorage("apiToken") private var token = ""
    @AppStorage("notchEnabled") private var notchEnabled = true
    @AppStorage("notchPill") private var notchPill = "never"
    @AppStorage("notchAutoExpand") private var autoExpand = true
    @AppStorage("notifyStart") private var notifyStart = true
    @AppStorage("notifyPartial") private var notifyPartial = true
    @AppStorage("notifyEnd") private var notifyEnd = true
    @AppStorage("sound") private var sound = true
    @AppStorage("menuTimer") private var menuTimer = false
    @AppStorage("autoLocation") private var autoLocation = true
    @AppStorage("threatsEnabled") private var threatsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var locationText: String {
        switch store.locationState {
        case .off: T("вимкнено", "off")
        case .searching: T("визначаю…", "locating…")
        case .found: [store.homeLocality, store.homeRaion].filter { !$0.isEmpty }.joined(separator: ", ")
        case .denied: T("немає дозволу — Налаштування → Приватність → Служби локації", "no permission — Settings → Privacy → Location Services")
        case .failed: T("не вдалося визначити", "couldn’t locate")
        case .outside: T("поза Україною", "outside Ukraine")
        }
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section(T("Місце", "Location")) {
                Toggle(T("Визначати за геолокацією", "Detect from location"), isOn: $autoLocation)
                    .onChange(of: autoLocation) { _, on in on ? delegate.location.start() : delegate.location.stop() }
                if autoLocation {
                    LabeledContent(T("Зараз", "Now")) {
                        Text(locationText).foregroundStyle(.secondary)
                    }
                }
                Picker(T("Область", "Oblast"), selection: $store.home) {
                    ForEach(Regions.all) { Text($0.name).tag($0.uk) }
                }
                Picker(T("Район", "Raion"), selection: $store.homeRaion) {
                    Text(T("Уся область", "Whole oblast")).tag("")
                    ForEach(store.knownRaions, id: \.self) { Text($0).tag($0) }
                }
                .disabled(store.knownRaions.isEmpty)
            }
            Section(T("Рядок меню", "Menu bar")) {
                Toggle(T("Показувати таймер тривоги біля значка", "Show alert timer next to the icon"), isOn: $menuTimer)
            }
            Section(T("Острівець у «чубчику»", "Notch island")) {
                Toggle(T("Показувати острівець", "Show the island"), isOn: $notchEnabled)
                    .onChange(of: notchEnabled) { _, on in on ? delegate.notch.start() : delegate.notch.stop() }
                Picker(T("Згорнутий стан", "Collapsed"), selection: $notchPill.onSet { delegate.notch.syncVisibility() }) {
                    Text(T("Нічого (лише при наведенні)", "Nothing (hover only)")).tag("never")
                    Text(T("Під час тривоги", "During alerts")).tag("alert")
                    Text(T("Завжди", "Always")).tag("always")
                }
                Toggle(T("Розгортати при зміні статусу", "Expand when status changes"), isOn: $autoExpand)
                Text(T("Наведіть курсор на «чубчик», щоб побачити карту.", "Hover over the notch to see the map."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Сповіщення", "Notifications")) {
                Toggle(T("Початок тривоги", "Alert started"), isOn: $notifyStart)
                Toggle(T("Тривога в інших районах області", "Alert elsewhere in the oblast"), isOn: $notifyPartial)
                Toggle(T("Відбій", "All clear"), isOn: $notifyEnd)
                Toggle(T("Звук сирени", "Siren sound"), isOn: $sound)
            }
            Section(T("Ракети, шахеди, КАБи", "Missiles, drones, KABs")) {
                Toggle(T("Показувати загрози в повітрі", "Show air threats"), isOn: $threatsEnabled)
                    .onChange(of: threatsEnabled) { _, on in delegate.threats.setEnabled(on) }
                Text(T("Позначки на карті, кількість за типами та найближча ціль. Дані NEPTUN (neptun.in.ua) — агрегатор моніторингових каналів, не офіційна система оповіщення; можливі неточності й затримки.",
                       "Map markers, counts by type and the nearest target. Data by NEPTUN (neptun.in.ua), an aggregator of monitoring channels, not an official warning system; may be inaccurate or delayed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(T("Дані", "Data")) {
                SecureField(T("Власний API-ключ alerts.in.ua (необов'язково)", "Own alerts.in.ua API key (optional)"), text: $token)
                    .onSubmit { Task { await store.poll(); await store.loadHistory(force: true) } }
                HStack {
                    Image(systemName: store.hasToken ? "checkmark.seal.fill" : "info.circle").foregroundStyle(store.hasToken ? Palette.calm : .secondary)
                    Text(!store.ownToken.isEmpty ? T("Ваш ключ: дані по районах та історія", "Your key: raion-level data and history")
                         : store.hasToken ? T("Вбудований ключ: дані по районах та історія", "Built-in key: raion-level data and history")
                         : T("Резервне джерело ubilling.net.ua", "Fallback source ubilling.net.ua"))
                    Spacer()
                    Link(T("Отримати ключ", "Get a key"), destination: URL(string: "https://alerts.in.ua/api-request")!)
                }
                .font(.caption)
            }
            Section(T("Загальні", "General")) {
                Picker(T("Мова", "Language"), selection: $lang) {
                    Text(T("Як у системі", "System")).tag("system")
                    Text("Українська").tag("uk")
                    Text("English").tag("en")
                }
                Toggle(T("Запускати під час входу", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
        }
        .formStyle(.grouped)
        // The form grew taller than the screen; cap it and let it scroll.
        .frame(width: 480, height: min(680, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
    }
}
