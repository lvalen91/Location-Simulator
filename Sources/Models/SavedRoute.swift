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
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A saved route with name, endpoints, and transport mode.
struct SavedRoute: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var fromName: String
    var fromCoordinate: CodableCoordinate
    var toName: String
    var toCoordinate: CodableCoordinate
    var transportMode: TransportMode
    var createdAt: Date

    /// Display name showing origin and destination.
    var displayName: String {
        if !name.isEmpty { return name }
        return "\(fromName) → \(toName)"
    }

    init(name: String = "", fromName: String, from: CLLocationCoordinate2D,
         toName: String, to: CLLocationCoordinate2D, transportMode: TransportMode) {
        self.id = UUID()
        self.name = name
        self.fromName = fromName
        self.fromCoordinate = CodableCoordinate(from)
        self.toName = toName
        self.toCoordinate = CodableCoordinate(to)
        self.transportMode = transportMode
        self.createdAt = Date()
    }
}

/// A recent route entry (lightweight, auto-managed).
struct RecentRoute: Identifiable, Codable, Hashable {
    var id: UUID
    var fromName: String
    var fromCoordinate: CodableCoordinate
    var toName: String
    var toCoordinate: CodableCoordinate
    var transportMode: TransportMode
    var usedAt: Date

    var displayName: String {
        "\(fromName) → \(toName)"
    }

    init(fromName: String, from: CLLocationCoordinate2D,
         toName: String, to: CLLocationCoordinate2D, transportMode: TransportMode) {
        self.id = UUID()
        self.fromName = fromName
        self.fromCoordinate = CodableCoordinate(from)
        self.toName = toName
        self.toCoordinate = CodableCoordinate(to)
        self.transportMode = transportMode
        self.usedAt = Date()
    }
}

/// Discovered iOS device connected via USB.
struct DeviceInfo: Identifiable, Hashable {
    let id: String          // UDID
    var name: String
    var connectionType: String  // "USB"
}
