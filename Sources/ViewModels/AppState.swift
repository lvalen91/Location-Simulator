import Foundation
import CoreLocation
import MapKit

/// Handles CLLocationManager delegate callbacks and forwards to AppState.
private class LocationDelegate: NSObject, CLLocationManagerDelegate {
    weak var appState: AppState?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let appState, manager.authorizationStatus == .authorizedAlways else { return }
        if let loc = manager.location?.coordinate {
            appState.teleportTo(loc)
        }
    }
}

/// Top-level observable application state. Owns all managers and services.
@Observable
final class AppState {
    // MARK: - Services
    let spoofing = LocationSpoofingService()
    private let locationManager = CLLocationManager()
    private let locationDelegate = LocationDelegate()

    // MARK: - Devices
    var devices: [DeviceInfo] = []
    var selectedDevice: DeviceInfo?
    var isScanning = false

    // MARK: - Routes
    var savedRoutes: [SavedRoute] = []
    var recentRoutes: [RecentRoute] = []
    var calculatedRoutes: [MKRoute] = []
    var selectedRouteIndex: Int?

    // MARK: - Search State
    var fromText: String = ""
    var toText: String = ""
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var fromName: String = "Current Location"
    var toName: String = ""

    // MARK: - Map State
    var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    var mapType: MKMapType = .standard

    // MARK: - UI State
    var showingSidebar = true
    var statusMessage: String?

    /// Display speed in imperial (mph) when true, metric (km/h) when false.
    var useImperial: Bool = UserDefaults.standard.bool(forKey: "useImperial") {
        didSet { UserDefaults.standard.set(useImperial, forKey: "useImperial") }
    }


    private static let savedRoutesKey = "savedRoutes"
    private static let recentRoutesKey = "recentRoutes"
    private static let maxRecent = 20

    init() {
        locationDelegate.appState = self
        locationManager.delegate = locationDelegate
        loadSavedRoutes()
        loadRecentRoutes()
    }

    // MARK: - Mac Location

    func acquireCurrentLocation() {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways:
            if let loc = locationManager.location?.coordinate {
                teleportTo(loc)
            } else {
                statusMessage = "Unable to determine current location"
            }
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            statusMessage = "Location access denied — enable in System Settings → Privacy"
        default:
            if let loc = locationManager.location?.coordinate {
                teleportTo(loc)
            } else {
                statusMessage = "Unable to determine current location"
            }
        }
    }

    // MARK: - Device Management

    func scanForDevices() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Pymobiledevice3Bridge.shared.discoverDevices()
            DispatchQueue.main.async {
                let previous = self?.devices ?? []
                self?.devices = found
                self?.isScanning = false

                // Remove selected device if it disappeared
                if let sel = self?.selectedDevice, !found.contains(where: { $0.id == sel.id }) {
                    self?.spoofing.disconnect()
                    self?.selectedDevice = nil
                }

                // Notify user of newly detected devices
                let newDevices = found.filter { d in !previous.contains(where: { $0.id == d.id }) }
                if !newDevices.isEmpty {
                    self?.statusMessage = "\(newDevices.count) USB device\(newDevices.count > 1 ? "s" : "") detected"
                    // Auto-clear status after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self?.statusMessage?.contains("detected") == true {
                            self?.statusMessage = nil
                        }
                    }
                }
            }
        }
    }

    /// Connect to a device. Must be explicitly triggered by user tap.
    func connectDevice(_ device: DeviceInfo) {
        if selectedDevice != nil { spoofing.disconnect() }
        selectedDevice = device
        spoofing.connect(udid: device.id)
    }

    /// Disconnect without clearing device from list.
    func disconnectSelectedDevice() {
        spoofing.disconnect()
        selectedDevice = nil
    }

    func disconnectDevice() {
        disconnectSelectedDevice()
    }

    // MARK: - Route Calculation

    func calculateRoutes() {
        // Use current spoofed location as origin if From is empty
        let origin: CLLocationCoordinate2D?
        if let from = fromCoordinate {
            origin = from
        } else if let current = spoofing.currentLocation {
            origin = current
            fromName = "Current Location"
        } else {
            origin = nil
        }

        guard let from = origin, let to = toCoordinate else {
            statusMessage = "Set both origin and destination"
            return
        }

        statusMessage = "Calculating routes..."
        from.calculateAllRoutes(to: to, transportType: spoofing.transportMode.mkTransportType,
                               ) { [weak self] routes in
            self?.calculatedRoutes = routes
            self?.selectedRouteIndex = routes.isEmpty ? nil : 0
            self?.statusMessage = routes.isEmpty ? "No routes found" : nil
        }
    }

    func clearRoutes() {
        calculatedRoutes = []
        selectedRouteIndex = nil
    }

    // MARK: - Navigation

    func startNavigation(routeIndex: Int) {
        guard routeIndex < calculatedRoutes.count else { return }
        let route = calculatedRoutes[routeIndex]
        let coords = route.polyline.coordinates

        // Build full route: origin → route → destination
        var fullRoute: [CLLocationCoordinate2D] = []
        if let from = fromCoordinate ?? spoofing.currentLocation,
           let first = coords.first, from.distance(to: first) > 10 {
            fullRoute.append(from)
        }
        fullRoute.append(contentsOf: coords)

        // Add to recent routes
        addRecentRoute()

        spoofing.startNavigation(route: fullRoute)
        statusMessage = "Navigating..."
    }

    func startNavigationFromSaved(_ saved: SavedRoute) {
        fromText = saved.fromName
        toText = saved.toName
        fromCoordinate = saved.fromCoordinate.clCoordinate
        toCoordinate = saved.toCoordinate.clCoordinate
        fromName = saved.fromName
        toName = saved.toName
        spoofing.transportMode = saved.transportMode
        spoofing.speedKmh = saved.transportMode.defaultSpeedKmh
        calculateRoutes()
    }

    func startNavigationFromRecent(_ recent: RecentRoute) {
        fromText = recent.fromName
        toText = recent.toName
        fromCoordinate = recent.fromCoordinate.clCoordinate
        toCoordinate = recent.toCoordinate.clCoordinate
        fromName = recent.fromName
        toName = recent.toName
        spoofing.transportMode = recent.transportMode
        calculateRoutes()
    }

    func stopNavigation() {
        spoofing.stopNavigation()
        statusMessage = nil
    }

    // MARK: - Teleport

    func teleportTo(_ coordinate: CLLocationCoordinate2D) {
        spoofing.teleport(to: coordinate)
        mapRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    // MARK: - Right-click context actions

    func setRouteFrom(_ coordinate: CLLocationCoordinate2D) {
        fromCoordinate = coordinate
        coordinate.reverseGeocode { [weak self] name in
            self?.fromText = name
            self?.fromName = name
            if self?.toCoordinate != nil { self?.calculateRoutes() }
        }
    }

    func setRouteTo(_ coordinate: CLLocationCoordinate2D) {
        toCoordinate = coordinate
        coordinate.reverseGeocode { [weak self] name in
            self?.toText = name
            self?.toName = name
            if self?.fromCoordinate != nil || self?.spoofing.currentLocation != nil {
                self?.calculateRoutes()
            }
        }
    }

    func swapFromTo() {
        swap(&fromText, &toText)
        swap(&fromCoordinate, &toCoordinate)
        swap(&fromName, &toName)
        if fromCoordinate != nil || spoofing.currentLocation != nil, toCoordinate != nil {
            calculateRoutes()
        }
    }

    func clearSearch() {
        fromText = ""
        toText = ""
        fromCoordinate = nil
        toCoordinate = nil
        fromName = "Current Location"
        toName = ""
        clearRoutes()
    }

    // MARK: - Saved Routes

    func saveCurrentRoute(name: String = "") {
        guard let to = toCoordinate else { return }
        let from = fromCoordinate ?? spoofing.currentLocation ?? CLLocationCoordinate2D()
        let route = SavedRoute(name: name, fromName: fromName, from: from,
                               toName: toName, to: to, transportMode: spoofing.transportMode)
        savedRoutes.insert(route, at: 0)
        persistSavedRoutes()
    }

    func renameSavedRoute(id: UUID, newName: String) {
        guard let idx = savedRoutes.firstIndex(where: { $0.id == id }) else { return }
        savedRoutes[idx].name = newName
        persistSavedRoutes()
    }

    func deleteSavedRoute(id: UUID) {
        savedRoutes.removeAll { $0.id == id }
        persistSavedRoutes()
    }

    private func persistSavedRoutes() {
        if let data = try? JSONEncoder().encode(savedRoutes) {
            UserDefaults.standard.set(data, forKey: Self.savedRoutesKey)
        }
    }

    private func loadSavedRoutes() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedRoutesKey),
              let routes = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return }
        savedRoutes = routes
    }

    // MARK: - Recent Routes

    private func addRecentRoute() {
        guard let to = toCoordinate else { return }
        let from = fromCoordinate ?? spoofing.currentLocation ?? CLLocationCoordinate2D()
        let recent = RecentRoute(fromName: fromName, from: from,
                                 toName: toName, to: to, transportMode: spoofing.transportMode)
        recentRoutes.insert(recent, at: 0)
        if recentRoutes.count > Self.maxRecent { recentRoutes.removeLast() }
        persistRecentRoutes()
    }

    func clearRecentRoutes() {
        recentRoutes.removeAll()
        persistRecentRoutes()
    }

    private func persistRecentRoutes() {
        if let data = try? JSONEncoder().encode(recentRoutes) {
            UserDefaults.standard.set(data, forKey: Self.recentRoutesKey)
        }
    }

    private func loadRecentRoutes() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentRoutesKey),
              let routes = try? JSONDecoder().decode([RecentRoute].self, from: data) else { return }
        recentRoutes = routes
    }
}
