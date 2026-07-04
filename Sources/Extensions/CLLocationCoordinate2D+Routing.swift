import Foundation
import CoreLocation
import MapKit

extension FloatingPoint {
    var degreesToRadians: Self { self * .pi / 180 }
    var radiansToDegrees: Self { self * 180 / .pi }
}

extension CLLocationCoordinate2D {
    /// A bare `MKMapItem` for this coordinate (no address), suitable as a
    /// directions source/destination. Uses the macOS 26+ `init(location:address:)`.
    var mapItem: MKMapItem {
        MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
    }

    /// Distance in meters to another coordinate.
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let there = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return here.distance(from: there)
    }

    /// Bearing in degrees from this coordinate to another.
    func bearing(to other: CLLocationCoordinate2D) -> CLLocationDegrees {
        let lat1 = latitude.degreesToRadians
        let lon1 = longitude.degreesToRadians
        let lat2 = other.latitude.degreesToRadians
        let lon2 = other.longitude.degreesToRadians
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let heading = atan2(y, x).radiansToDegrees
        return heading >= 0 ? heading : heading + 360
    }

    /// Calculate a single best route to a destination.
    @MainActor
    func calculateRoute(to destination: CLLocationCoordinate2D,
                        transportType: MKDirectionsTransportType) async -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = self.mapItem
        request.destination = destination.mapItem
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        guard let response = try? await MKDirections(request: request).calculate(),
              let route = response.routes.first else { return [] }
        return route.polyline.coordinates
    }

    /// Calculate all available routes to a destination.
    @MainActor
    func calculateAllRoutes(to destination: CLLocationCoordinate2D,
                            transportType: MKDirectionsTransportType) async -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = self.mapItem
        request.destination = destination.mapItem
        request.transportType = transportType
        request.requestsAlternateRoutes = true
        return (try? await MKDirections(request: request).calculate())?.routes ?? []
    }

    /// Reverse geocode this coordinate to a concise, human-readable place name
    /// using the modern `MKReverseGeocodingRequest` (macOS 26+). Falls back to
    /// formatted coordinates if geocoding yields nothing.
    @MainActor
    func reverseGeocode() async -> String {
        let fallback = String(format: "%.4f, %.4f", latitude, longitude)
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return fallback }
        guard let item = (try? await request.mapItems)?.first else { return fallback }

        if let short = item.address?.shortAddress, !short.isEmpty { return short }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty { return city }
        if let name = item.name, !name.isEmpty { return name }
        return fallback
    }
}

extension MKPolyline {
    /// Extract all coordinates from this polyline.
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
