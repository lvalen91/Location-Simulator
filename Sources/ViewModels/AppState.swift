import Foundation
import CoreLocation
import MapKit
import SwiftUI

// MARK: - RouteWaypoint

/// In-memory (non-persisted) state for a single stop in the route editor.
struct RouteWaypoint: Identifiable {
    var id: UUID
    var text: String          // raw text in the search field
    var name: String          // resolved display name
    var coordinate: CLLocationCoordinate2D?

    init(id: UUID = UUID(), text: String = "", name: String = "", coordinate: CLLocationCoordinate2D? = nil) {
        self.id = id
        self.text = text
        self.name = name
        self.coordinate = coordinate
    }

    static func currentLocation() -> RouteWaypoint {
        RouteWaypoint(text: "", name: "Current Location", coordinate: nil)
    }
}

// MARK: - RouteResult

/// One calculated route option, potentially spanning multiple legs (stops).
struct RouteResult: Identifiable {
    let id: UUID = UUID()
    let legs: [MKRoute]

    var totalDistance: Double { legs.reduce(0) { $0 + $1.distance } }
    var totalTime: TimeInterval { legs.reduce(0) { $0 + $1.expectedTravelTime } }
    var isMultiLeg: Bool { legs.count > 1 }

    /// All coordinates concatenated from every leg's polyline.
    var polylineCoordinates: [CLLocationCoordinate2D] {
        legs.flatMap { $0.polyline.coordinates }
    }
}

// MARK: - PlacesCategory

enum PlacesCategory: String, CaseIterable, Identifiable, Hashable {
    case pinned
    case savedRoutes
    case recent
    case devices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .savedRoutes: return "Saved Routes"
        case .recent: return "Recents"
        case .devices: return "Devices"
        }
    }

    var systemImage: String {
        switch self {
        case .pinned: return "pin.fill"
        case .savedRoutes: return "star.fill"
        case .recent: return "clock.fill"
        case .devices: return "iphone"
        }
    }
}

// MARK: - LocationDelegate

@MainActor
private final class LocationDelegate: NSObject, @preconcurrency CLLocationManagerDelegate {
    weak var appState: AppState?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // A fresh grant arrives here; ask for an actual one-shot fix rather
            // than reading the (usually nil) cached `manager.location`.
            manager.requestLocation()
        case .denied, .restricted:
            appState?.statusMessage = "Location access denied — enable in System Settings → Privacy"
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        appState?.teleportTo(coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appState?.statusMessage = "Unable to determine current location"
    }
}

// MARK: - AppState

@MainActor
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
    var calculatedRoutes: [RouteResult] = []
    var selectedRouteIndex: Int?

    // MARK: - Waypoints (origin + optional stops + destination)
    var waypoints: [RouteWaypoint] = [.currentLocation(), RouteWaypoint()]

    // MARK: - Pinned Locations
    var pinnedLocations: [PinnedLocation] = []

    // MARK: - Places Sidebar
    var selectedPlacesCategory: PlacesCategory?

    // MARK: - Dependency State
    var pymobiledevice3Installed = true   // refreshed on every scan
    var homebrewAvailable = false
    var isInstallingDependency = false
    var dependencyInstallLog = ""

    // MARK: - Map State
    var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    var mapType: MKMapType = .standard

    // MARK: - UI State
    var showingSidebar = true
    var statusMessage: String?

    var useImperial: Bool = UserDefaults.standard.bool(forKey: "useImperial") {
        didSet { UserDefaults.standard.set(useImperial, forKey: "useImperial") }
    }

    private static let savedRoutesKey = "savedRoutes"
    private static let recentRoutesKey = "recentRoutes"
    private static let pinnedLocationsKey = "pinnedLocations"
    private static let maxRecent = 20

    init() {
        locationDelegate.appState = self
        locationManager.delegate = locationDelegate
        loadSavedRoutes()
        loadRecentRoutes()
        loadPinnedLocations()
    }

    // MARK: - Mac Location

    func acquireCurrentLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // The grant callback (locationManagerDidChangeAuthorization) fires
            // requestLocation() once the user responds.
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            statusMessage = "Location access denied — enable in System Settings → Privacy"
        @unknown default:
            locationManager.requestLocation()
        }
    }

    // MARK: - Device Management

    func scanForDevices() {
        isScanning = true
        Task { [weak self] in
            let bridge = Pymobiledevice3Bridge.shared
            // Re-resolve so a just-installed pymobiledevice3 is picked up.
            let available = await bridge.refreshAvailability()
            let brew = bridge.homebrewPath() != nil
            let found = available ? await bridge.discoverDevices() : []
            await MainActor.run {
                guard let self else { return }
                self.pymobiledevice3Installed = available
                self.homebrewAvailable = brew
                let previous = self.devices
                self.devices = found
                self.isScanning = false

                if let sel = self.selectedDevice, !found.contains(where: { $0.id == sel.id }) {
                    self.spoofing.disconnect()
                    self.selectedDevice = nil
                }

                let newDevices = found.filter { d in !previous.contains(where: { $0.id == d.id }) }
                if !newDevices.isEmpty {
                    self.statusMessage = "\(newDevices.count) device\(newDevices.count > 1 ? "s" : "") detected"
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        if self?.statusMessage?.contains("detected") == true { self?.statusMessage = nil }
                    }
                }
            }
        }
    }

    /// Install pymobiledevice3 via Homebrew, streaming progress, then re-scan.
    func installDependency() {
        guard !isInstallingDependency, !pymobiledevice3Installed else { return }
        isInstallingDependency = true
        dependencyInstallLog = "Starting install…\n"
        Task {
            let ok = await Pymobiledevice3Bridge.shared.installViaHomebrew { line in
                Task { @MainActor in self.dependencyInstallLog += line + "\n" }
            }
            self.isInstallingDependency = false
            self.pymobiledevice3Installed = ok
            if ok {
                self.statusMessage = "pymobiledevice3 installed"
                self.scanForDevices()
            } else {
                self.statusMessage = "Install failed — see log"
            }
        }
    }

    func connectDevice(_ device: DeviceInfo) {
        // Ignore taps while a connect is already in flight — prevents stacking
        // duplicate daemon launches from rapid clicks.
        guard !spoofing.isConnecting else { return }
        if let current = selectedDevice, current.id != device.id { spoofing.disconnect() }
        selectedDevice = device
        spoofing.connect(udid: device.id)
    }

    func disconnectSelectedDevice() {
        spoofing.disconnect()
        selectedDevice = nil
    }

    func disconnectDevice() {
        disconnectSelectedDevice()
    }

    // MARK: - Waypoint Management

    /// Add an empty stop before the destination.
    func addStop() {
        guard waypoints.count >= 2, waypoints.count < 10 else { return }
        waypoints.insert(RouteWaypoint(), at: waypoints.count - 1)
        clearRoutes()
    }

    /// Remove a middle stop (index must be > 0 and < count-1).
    func removeStop(at index: Int) {
        guard waypoints.count > 2, index > 0, index < waypoints.count - 1 else { return }
        waypoints.remove(at: index)
        tryCalculateRoutes()
    }

    /// Insert a geocoded stop before the destination (used from map right-click).
    func addStopAt(_ coordinate: CLLocationCoordinate2D) {
        guard waypoints.count >= 2, waypoints.count < 10 else { return }
        let insertIdx = waypoints.count - 1
        let stopID = UUID()
        let coords = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        waypoints.insert(RouteWaypoint(id: stopID, text: coords, name: coords, coordinate: coordinate), at: insertIdx)
        Task { [weak self] in
            let name = await coordinate.reverseGeocode()
            guard let self, let i = self.waypoints.firstIndex(where: { $0.id == stopID }) else { return }
            self.waypoints[i].text = name
            self.waypoints[i].name = name
        }
        tryCalculateRoutes()
    }

    // MARK: - Route Calculation

    /// Calculate routes if all waypoints are resolved.
    func tryCalculateRoutes() {
        guard canCalculateRoutes else { return }
        calculateRoutes()
    }

    private var canCalculateRoutes: Bool {
        guard waypoints.count >= 2 else { return false }
        guard let last = waypoints.last, last.coordinate != nil else { return false }
        let firstOk = waypoints.first?.coordinate != nil || spoofing.currentLocation != nil
        guard firstOk else { return false }
        return waypoints.dropFirst().dropLast().allSatisfy { $0.coordinate != nil }
    }

    func calculateRoutes() {
        var coords: [CLLocationCoordinate2D] = []
        for (i, wp) in waypoints.enumerated() {
            if let c = wp.coordinate {
                coords.append(c)
            } else if i == 0, let c = spoofing.currentLocation {
                coords.append(c)
            } else {
                statusMessage = "Set all stops before calculating"
                return
            }
        }
        guard coords.count >= 2 else {
            statusMessage = "Set origin and destination"
            return
        }

        statusMessage = "Calculating routes…"

        if coords.count == 2 {
            let origin = coords[0], destination = coords[1]
            let transportType = spoofing.transportMode.mkTransportType
            Task { [weak self] in
                guard let self else { return }
                let routes = await origin.calculateAllRoutes(to: destination, transportType: transportType)
                self.calculatedRoutes = routes.map { RouteResult(legs: [$0]) }
                self.selectedRouteIndex = routes.isEmpty ? nil : 0
                self.statusMessage = routes.isEmpty ? "No routes found" : nil
            }
        } else {
            let transportType = spoofing.transportMode.mkTransportType
            Task { [weak self] in
                guard let self else { return }
                let legs = await self.calculateChainedLegs(coords: coords, transportType: transportType)
                if let legs {
                    self.calculatedRoutes = [RouteResult(legs: legs)]
                    self.selectedRouteIndex = 0
                    self.statusMessage = nil
                } else {
                    self.calculatedRoutes = []
                    self.selectedRouteIndex = nil
                    self.statusMessage = "No route found"
                }
            }
        }
    }

    private func calculateChainedLegs(coords: [CLLocationCoordinate2D],
                                       transportType: MKDirectionsTransportType) async -> [MKRoute]? {
        var legs: [MKRoute] = []
        for index in 0..<(coords.count - 1) {
            let request = MKDirections.Request()
            request.source = coords[index].mapItem
            request.destination = coords[index + 1].mapItem
            request.transportType = transportType
            request.requestsAlternateRoutes = false
            guard let response = try? await MKDirections(request: request).calculate(),
                  let route = response.routes.first else {
                return nil
            }
            legs.append(route)
        }
        return legs
    }

    func clearRoutes() {
        calculatedRoutes = []
        selectedRouteIndex = nil
    }

    // MARK: - Navigation

    func startNavigation(routeIndex: Int) {
        guard routeIndex < calculatedRoutes.count else { return }
        let result = calculatedRoutes[routeIndex]
        let coords = result.polylineCoordinates

        var fullRoute: [CLLocationCoordinate2D] = []
        let origin = waypoints.first?.coordinate ?? spoofing.currentLocation
        if let from = origin, let first = coords.first, from.distance(to: first) > 10 {
            fullRoute.append(from)
        }
        fullRoute.append(contentsOf: coords)

        addRecentRoute()
        spoofing.startNavigation(route: fullRoute)
        statusMessage = "Navigating…"
    }

    func startNavigationFromSaved(_ saved: SavedRoute) {
        waypoints = saved.stops.map {
            RouteWaypoint(text: $0.name, name: $0.name, coordinate: $0.coordinate?.clCoordinate)
        }
        if waypoints.count < 2 { waypoints = [.currentLocation(), RouteWaypoint()] }
        spoofing.transportMode = saved.transportMode
        spoofing.speedKmh = saved.transportMode.defaultSpeedKmh
        calculateRoutes()
    }

    func startNavigationFromRecent(_ recent: RecentRoute) {
        waypoints = recent.stops.map {
            RouteWaypoint(text: $0.name, name: $0.name, coordinate: $0.coordinate?.clCoordinate)
        }
        if waypoints.count < 2 { waypoints = [.currentLocation(), RouteWaypoint()] }
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
        guard !waypoints.isEmpty else { return }
        waypoints[0].coordinate = coordinate
        let wpID = waypoints[0].id
        Task { [weak self] in
            let name = await coordinate.reverseGeocode()
            guard let self, let i = self.waypoints.firstIndex(where: { $0.id == wpID }) else { return }
            self.waypoints[i].text = name
            self.waypoints[i].name = name
            self.tryCalculateRoutes()
        }
    }

    func setRouteTo(_ coordinate: CLLocationCoordinate2D) {
        guard !waypoints.isEmpty else { return }
        let idx = waypoints.count - 1
        waypoints[idx].coordinate = coordinate
        let wpID = waypoints[idx].id
        Task { [weak self] in
            let name = await coordinate.reverseGeocode()
            guard let self, let i = self.waypoints.firstIndex(where: { $0.id == wpID }) else { return }
            self.waypoints[i].text = name
            self.waypoints[i].name = name
            self.tryCalculateRoutes()
        }
    }

    func swapFromTo() {
        // Pin current location before reversing so it becomes a real coordinate.
        if waypoints.first?.coordinate == nil, let cur = spoofing.currentLocation {
            waypoints[0].coordinate = cur
            waypoints[0].name = "Current Location"
            waypoints[0].text = "Current Location"
        }
        waypoints.reverse()
        clearRoutes()
        tryCalculateRoutes()
    }

    func clearSearch() {
        waypoints = [.currentLocation(), RouteWaypoint()]
        clearRoutes()
    }

    // MARK: - Saved Routes

    func saveCurrentRoute(name: String = "") {
        guard waypoints.last?.coordinate != nil else { return }
        var stops: [RouteStop] = []
        for (i, wp) in waypoints.enumerated() {
            var coord = wp.coordinate
            if i == 0, coord == nil { coord = spoofing.currentLocation }
            guard let c = coord else { return }
            stops.append(RouteStop(name: wp.name.isEmpty ? wp.text : wp.name, coordinate: c))
        }
        guard stops.count >= 2 else { return }
        savedRoutes.insert(SavedRoute(name: name, stops: stops, transportMode: spoofing.transportMode), at: 0)
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
        var stops: [RouteStop] = []
        for (i, wp) in waypoints.enumerated() {
            var coord = wp.coordinate
            if i == 0, coord == nil { coord = spoofing.currentLocation }
            guard let c = coord else { return }
            stops.append(RouteStop(name: wp.name.isEmpty ? wp.text : wp.name, coordinate: c))
        }
        guard stops.count >= 2 else { return }
        let recent = RecentRoute(stops: stops, transportMode: spoofing.transportMode)
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

    // MARK: - Pinned Locations

    func pinLocation(_ coordinate: CLLocationCoordinate2D, name: String = "") {
        let pin = PinnedLocation(name: name, coordinate: coordinate)
        pinnedLocations.insert(pin, at: 0)
        persistPinnedLocations()

        if name.isEmpty {
            let pinID = pin.id
            Task { [weak self] in
                let resolved = await coordinate.reverseGeocode()
                guard let self,
                      let idx = self.pinnedLocations.firstIndex(where: { $0.id == pinID }),
                      self.pinnedLocations[idx].name.isEmpty
                else { return }
                self.pinnedLocations[idx].name = resolved
                self.persistPinnedLocations()
            }
        }
    }

    func renamePinnedLocation(id: UUID, newName: String) {
        guard let idx = pinnedLocations.firstIndex(where: { $0.id == id }) else { return }
        pinnedLocations[idx].name = newName
        persistPinnedLocations()
    }

    func deletePinnedLocation(id: UUID) {
        pinnedLocations.removeAll { $0.id == id }
        persistPinnedLocations()
    }

    func clearPinnedLocations() {
        pinnedLocations.removeAll()
        persistPinnedLocations()
    }

    func teleportToPin(_ pin: PinnedLocation) {
        teleportTo(pin.coordinate.clCoordinate)
    }

    private func persistPinnedLocations() {
        if let data = try? JSONEncoder().encode(pinnedLocations) {
            UserDefaults.standard.set(data, forKey: Self.pinnedLocationsKey)
        }
    }

    private func loadPinnedLocations() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinnedLocationsKey),
              let pins = try? JSONDecoder().decode([PinnedLocation].self, from: data) else { return }
        pinnedLocations = pins
    }

    // MARK: - Reordering (macOS 26+ reorderable)

    /// Apply a SwiftUI reorder difference (drag-to-reorder) to saved routes.
    func moveSavedRoutes(_ difference: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>) {
        savedRoutes = Self.applyReorder(difference, to: savedRoutes)
        persistSavedRoutes()
    }

    /// Apply a SwiftUI reorder difference (drag-to-reorder) to pinned locations.
    func movePinnedLocations(_ difference: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>) {
        pinnedLocations = Self.applyReorder(difference, to: pinnedLocations)
        persistPinnedLocations()
    }

    /// Reposition the dragged items (identified by `sources`) ahead of the
    /// destination item, or at the end. Shared by the reorderable lists.
    private static func applyReorder<T: Identifiable>(
        _ difference: ReorderDifference<UUID, ReorderableSingleCollectionIdentifier>,
        to items: [T]
    ) -> [T] where T.ID == UUID {
        let moving = items.filter { difference.sources.contains($0.id) }
        guard !moving.isEmpty else { return items }
        var result = items.filter { !difference.sources.contains($0.id) }
        switch difference.destination.position {
        case .before(let id):
            if let idx = result.firstIndex(where: { $0.id == id }) {
                result.insert(contentsOf: moving, at: idx)
            } else {
                result.append(contentsOf: moving)
            }
        case .end:
            result.append(contentsOf: moving)
        }
        return result
    }
}
