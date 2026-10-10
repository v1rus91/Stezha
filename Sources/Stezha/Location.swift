import Foundation
import CoreLocation

/// Finds the user's oblast / raion / city from the Mac's location and feeds it into the store.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let store: AlertStore
    private var lastFix: Date?

    init(store: AlertStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 2000
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: "autoLocation") as? Bool ?? true }

    func start() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: store.locationState = .denied
        default:
            store.locationState = .searching
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        store.locationState = .off
        store.location = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.start() }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // "Location unknown" is transient: Core Location keeps trying and reports a fix later.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in
            if self.store.locationState == .searching { self.store.locationState = .failed }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.store.location = loc
            await self.resolve(loc)
        }
    }

    private func resolve(_ loc: CLLocation) async {
        if let l = lastFix, Date.now.timeIntervalSince(l) < 600 { return }
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "uk_UA"))
        // Only a successful lookup starts the 10-minute pause, so a failed one is retried on the next fix.
        guard let p = marks?.first else { store.locationState = .failed; return }
        lastFix = .now
        guard let oblast = Self.match(oblast: p.administrativeArea, locality: p.locality) else {
            store.locationState = .outside
            return
        }
        store.applyLocation(oblast: oblast,
                            raion: Self.raion(p.subAdministrativeArea),
                            locality: p.locality ?? "")
        store.locationState = .found
    }

    /// Geocoder names vary ("Черкаська область", "Черкаська обл.", "Cherkasy Oblast", "Київ").
    static func match(oblast: String?, locality: String?) -> String? {
        if let l = locality, l == "Київ" || l == "Kyiv" { return "м. Київ" }
        guard let a = oblast?.lowercased() else { return nil }
        for r in Regions.all {
            let ukStem = String(r.uk.lowercased().prefix(6))
            let enStem = String(r.en.lowercased().prefix(5))
            if a.hasPrefix(ukStem) || a.hasPrefix(enStem) { return r.uk }
        }
        if a.contains("крим") || a.contains("crimea") { return "Автономна Республіка Крим" }
        return nil
    }

    static func raion(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.hasSuffix("район") { return s }
        if s.hasSuffix("р-н") { return s.replacingOccurrences(of: "р-н", with: "район") }
        return ""
    }
}
