import Foundation
import CoreLocation

/// Timer-driven engine that moves along a route at a configured speed,
/// emitting position updates suitable for GPS spoofing.
@Observable
final class NavigationEngine {
    /// The route waypoints being navigated.
    private(set) var route: [CLLocationCoordinate2D] = []
    /// Current interpolated position along the route.
    private(set) var currentPosition: CLLocationCoordinate2D?
    /// Index of the segment currently being traversed.
    private(set) var currentSegmentIndex: Int = 0
    /// Distance (meters) traveled along the current segment.
    private(set) var distanceAlongSegment: Double = 0
    /// Whether the engine is actively navigating.
    private(set) var isNavigating: Bool = false
    /// Total distance of the route in meters.
    private(set) var totalDistance: Double = 0
    /// Distance already traveled in meters.
    private(set) var distanceTraveled: Double = 0
    /// Whether to reverse the route when the end is reached.
    var autoReverse: Bool = false

    /// Speed in meters per second.
    var speedMps: Double = 16.67 // ~60 km/h

    /// Speed in km/h (convenience).
    var speedKmh: Double {
        get { speedMps * 3.6 }
        set { speedMps = newValue / 3.6 }
    }

    /// Remaining coordinates not yet visited (for overlay rendering).
    var remainingRoute: [CLLocationCoordinate2D] {
        guard isNavigating, currentSegmentIndex < route.count else { return [] }
        var result: [CLLocationCoordinate2D] = []
        if let pos = currentPosition { result.append(pos) }
        if currentSegmentIndex + 1 < route.count {
            result.append(contentsOf: route[(currentSegmentIndex + 1)...])
        }
        return result
    }

    /// Completed portion of the route.
    var completedRoute: [CLLocationCoordinate2D] {
        guard isNavigating else { return [] }
        var result = Array(route.prefix(currentSegmentIndex + 1))
        if let pos = currentPosition { result.append(pos) }
        return result
    }

    /// Progress fraction 0...1.
    var progress: Double {
        guard totalDistance > 0 else { return 0 }
        return min(distanceTraveled / totalDistance, 1.0)
    }

    private var timer: Timer?
    private var lastTick: Date?
    private var onPositionUpdate: ((CLLocationCoordinate2D) -> Void)?

    // MARK: - Control

    /// Start navigating along a route.
    func start(route: [CLLocationCoordinate2D], speedKmh: Double,
               onUpdate: @escaping (CLLocationCoordinate2D) -> Void) {
        guard route.count >= 2 else { return }
        stop()
        self.route = route
        self.speedMps = speedKmh / 3.6
        self.currentSegmentIndex = 0
        self.distanceAlongSegment = 0
        self.distanceTraveled = 0
        self.currentPosition = route.first
        self.onPositionUpdate = onUpdate
        self.isNavigating = true

        // Calculate total distance
        totalDistance = 0
        for i in 0..<(route.count - 1) {
            totalDistance += route[i].distance(to: route[i + 1])
        }

        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Pause navigation (keeps state).
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Resume a paused navigation.
    func resume() {
        guard isNavigating, timer == nil else { return }
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Stop navigation completely.
    func stop() {
        timer?.invalidate()
        timer = nil
        isNavigating = false
        route = []
        currentPosition = nil
        currentSegmentIndex = 0
        distanceAlongSegment = 0
        distanceTraveled = 0
        totalDistance = 0
    }

    // MARK: - Timer Tick

    private func tick() {
        guard isNavigating, currentSegmentIndex < route.count - 1 else {
            if autoReverse && route.count >= 2 {
                route.reverse()
                currentSegmentIndex = 0
                distanceAlongSegment = 0
                distanceTraveled = 0
                lastTick = Date()
            } else {
                stop()
            }
            return
        }

        let now = Date()
        let dt = now.timeIntervalSince(lastTick ?? now)
        lastTick = now

        var remaining = speedMps * dt
        distanceTraveled += remaining

        while remaining > 0 && currentSegmentIndex < route.count - 1 {
            let from = route[currentSegmentIndex]
            let to = route[currentSegmentIndex + 1]
            let segmentLength = from.distance(to: to)
            let leftInSegment = segmentLength - distanceAlongSegment

            if remaining >= leftInSegment {
                remaining -= leftInSegment
                currentSegmentIndex += 1
                distanceAlongSegment = 0
            } else {
                distanceAlongSegment += remaining
                remaining = 0
            }
        }

        // Interpolate position within current segment
        if currentSegmentIndex < route.count - 1 {
            let from = route[currentSegmentIndex]
            let to = route[currentSegmentIndex + 1]
            let segmentLength = from.distance(to: to)
            let fraction = segmentLength > 0 ? distanceAlongSegment / segmentLength : 0
            let lat = from.latitude + (to.latitude - from.latitude) * fraction
            let lon = from.longitude + (to.longitude - from.longitude) * fraction
            currentPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            currentPosition = route.last
        }

        if let pos = currentPosition {
            onPositionUpdate?(pos)
        }
    }
}
