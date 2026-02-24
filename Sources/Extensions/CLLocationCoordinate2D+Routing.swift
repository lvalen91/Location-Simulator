import Foundation
import CoreLocation
import MapKit

extension FloatingPoint {
    var degreesToRadians: Self { self * .pi / 180 }
    var radiansToDegrees: Self { self * 180 / .pi }
}

extension CLLocationCoordinate2D {
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
    func calculateRoute(to destination: CLLocationCoordinate2D,
                        transportType: MKDirectionsTransportType,
                        completion: @escaping ([CLLocationCoordinate2D]) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: self))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        MKDirections(request: request).calculate { response, _ in
            DispatchQueue.main.async {
                if let route = response?.routes.first {
                    completion(route.polyline.coordinates)
                } else {
                    completion([])
                }
            }
        }
    }

    /// Calculate all available routes to a destination.
    func calculateAllRoutes(to destination: CLLocationCoordinate2D,
                            transportType: MKDirectionsTransportType,
                            completion: @escaping ([MKRoute]) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: self))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = transportType
        request.requestsAlternateRoutes = true

        MKDirections(request: request).calculate { response, _ in
            DispatchQueue.main.async {
                completion(response?.routes ?? [])
            }
        }
    }

    /// Reverse geocode this coordinate to a place name.
    func reverseGeocode(completion: @escaping (String) -> Void) {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
            guard let place = placemarks?.first else {
                completion(String(format: "%.4f, %.4f", self.latitude, self.longitude))
                return
            }
            var parts: [String] = []
            if let thoroughfare = place.thoroughfare { parts.append(thoroughfare) }
            if let city = place.locality { parts.append(city) }
            if parts.isEmpty, let country = place.country { parts.append(country) }
            completion(parts.isEmpty ? String(format: "%.4f, %.4f", self.latitude, self.longitude) : parts.joined(separator: ", "))
        }
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
