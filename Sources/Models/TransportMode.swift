import Foundation
import MapKit

/// Transport mode for route calculation and speed defaults.
enum TransportMode: String, Codable, CaseIterable, Identifiable {
    case walking
    case cycling
    case driving

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .driving: return "Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car"
        }
    }

    /// Default speed in km/h for this transport mode.
    var defaultSpeedKmh: Double {
        switch self {
        case .walking: return 5
        case .cycling: return 15
        case .driving: return 60
        }
    }

    /// MapKit transport type for route calculation.
    var mkTransportType: MKDirectionsTransportType {
        switch self {
        case .walking: return .walking
        case .cycling: return .walking // MapKit doesn't have cycling; use walking
        case .driving: return .automobile
        }
    }
}
