import Foundation
import CoreLocation

/// A coordinate that can be encoded/decoded for persistence.
struct CodableCoordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A single waypoint (origin, intermediate stop, or destination) in a saved route.
struct RouteStop: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var coordinate: CodableCoordinate?

    init(name: String, coordinate: CLLocationCoordinate2D? = nil) {
        self.id = UUID()
        self.name = name
        self.coordinate = coordinate.map { CodableCoordinate($0) }
    }

    init(name: String, coordinate: CodableCoordinate?) {
        self.id = UUID()
        self.name = name
        self.coordinate = coordinate
    }
}

/// A saved route with name, N waypoints, and transport mode.
struct SavedRoute: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var stops: [RouteStop]
    var transportMode: TransportMode
    var createdAt: Date

    // Computed convenience accessors kept for PlacesDetailPanel compatibility.
    var fromName: String { stops.first?.name ?? "" }
    var toName: String { stops.last?.name ?? "" }
    var fromCoordinate: CodableCoordinate? { stops.first?.coordinate }
    var toCoordinate: CodableCoordinate? { stops.last?.coordinate }

    var displayName: String {
        if !name.isEmpty { return name }
        return routePath
    }

    var routePath: String {
        guard let first = stops.first, let last = stops.last, stops.count >= 2 else { return "Route" }
        if stops.count == 2 { return "\(first.name) → \(last.name)" }
        let n = stops.count - 2
        return "\(first.name) → \(last.name) (\(n) stop\(n > 1 ? "s" : ""))"
    }

    init(name: String = "", stops: [RouteStop], transportMode: TransportMode) {
        self.id = UUID()
        self.name = name
        self.stops = stops
        self.transportMode = transportMode
        self.createdAt = Date()
    }

    // MARK: - Codable (backward compatible with old 2-stop format)

    private enum CodingKeys: String, CodingKey {
        case id, name, stops, transportMode, createdAt
        case fromName, fromCoordinate, toName, toCoordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        transportMode = try c.decode(TransportMode.self, forKey: .transportMode)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        if let decoded = try c.decodeIfPresent([RouteStop].self, forKey: .stops) {
            stops = decoded
        } else {
            let fn = try c.decodeIfPresent(String.self, forKey: .fromName) ?? ""
            let fc = try c.decodeIfPresent(CodableCoordinate.self, forKey: .fromCoordinate)
            let tn = try c.decodeIfPresent(String.self, forKey: .toName) ?? ""
            let tc = try c.decodeIfPresent(CodableCoordinate.self, forKey: .toCoordinate)
            stops = [RouteStop(name: fn, coordinate: fc), RouteStop(name: tn, coordinate: tc)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(stops, forKey: .stops)
        try c.encode(transportMode, forKey: .transportMode)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// A recent route entry (lightweight, auto-managed).
struct RecentRoute: Identifiable, Codable, Hashable {
    var id: UUID
    var stops: [RouteStop]
    var transportMode: TransportMode
    var usedAt: Date

    var fromName: String { stops.first?.name ?? "" }
    var toName: String { stops.last?.name ?? "" }

    var displayName: String {
        guard let first = stops.first, let last = stops.last, stops.count >= 2 else { return "Route" }
        if stops.count == 2 { return "\(first.name) → \(last.name)" }
        let n = stops.count - 2
        return "\(first.name) → \(last.name) (\(n) stop\(n > 1 ? "s" : ""))"
    }

    init(stops: [RouteStop], transportMode: TransportMode) {
        self.id = UUID()
        self.stops = stops
        self.transportMode = transportMode
        self.usedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, stops, transportMode, usedAt
        case fromName, fromCoordinate, toName, toCoordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        transportMode = try c.decode(TransportMode.self, forKey: .transportMode)
        usedAt = try c.decodeIfPresent(Date.self, forKey: .usedAt) ?? Date()
        if let decoded = try c.decodeIfPresent([RouteStop].self, forKey: .stops) {
            stops = decoded
        } else {
            let fn = try c.decodeIfPresent(String.self, forKey: .fromName) ?? ""
            let fc = try c.decodeIfPresent(CodableCoordinate.self, forKey: .fromCoordinate)
            let tn = try c.decodeIfPresent(String.self, forKey: .toName) ?? ""
            let tc = try c.decodeIfPresent(CodableCoordinate.self, forKey: .toCoordinate)
            stops = [RouteStop(name: fn, coordinate: fc), RouteStop(name: tn, coordinate: tc)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(stops, forKey: .stops)
        try c.encode(transportMode, forKey: .transportMode)
        try c.encode(usedAt, forKey: .usedAt)
    }
}

/// Discovered iOS device (USB or Wi-Fi paired).
struct DeviceInfo: Identifiable, Hashable {
    let id: String          // UDID
    var name: String
    var connectionType: String  // "USB" or "Wi-Fi"
}

/// A pinned map location — single point the user can teleport back to.
struct PinnedLocation: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var coordinate: CodableCoordinate
    var createdAt: Date

    var displayName: String {
        if !name.isEmpty { return name }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    init(name: String = "", coordinate: CLLocationCoordinate2D) {
        self.id = UUID()
        self.name = name
        self.coordinate = CodableCoordinate(coordinate)
        self.createdAt = Date()
    }
}
