import CoreLocation
import Foundation

/// Knows roughly where the user is (neighborhood + city), refreshed in the background, so answers and
/// web searches ("weather", "near me") fit their location without them saying it.
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let lock = NSLock()
    private var _place: String?
    private var _city: String?
    private var lastGeocoded: CLLocation?

    /// e.g. "Mission District, San Francisco, CA, United States"
    var place: String? { lock.lock(); defer { lock.unlock() }; return _place }
    /// e.g. "San Francisco, CA" — used to localize web searches.
    var city: String? { lock.lock(); defer { lock.unlock() }; return _city }

    var isAuthorized: Bool {
        let s = manager.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    func request() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { SystemPermission.location.openSettings() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if isAuthorized { m.startUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        if let last = lastGeocoded, last.distance(from: loc) < 500, place != nil { return }
        lastGeocoded = loc
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, _ in
            guard let self, let p = marks?.first else { return }
            let cityParts = [p.locality, p.administrativeArea].compactMap { $0 }
            let placeParts = [p.subLocality, p.locality, p.administrativeArea, p.country].compactMap { $0 }
            self.lock.lock()
            self._city = cityParts.isEmpty ? nil : cityParts.joined(separator: ", ")
            self._place = placeParts.isEmpty ? nil : placeParts.joined(separator: ", ")
            self.lock.unlock()
            flowLog("location: \(self.place ?? "unknown")")
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        flowLog("location unavailable: \(error.localizedDescription)")
    }

    /// Adds the city to searches that depend on where the user is.
    func localize(_ query: String) -> String {
        guard let city, query.matches(#"\b(near me|nearby|around here|close by|weather|forecast|rain|temperature|open now|tonight|local|here)\b"#),
              !query.lowercased().contains(city.split(separator: ",").first?.lowercased() ?? "~") else { return query }
        return "\(query) \(city)"
    }
}
