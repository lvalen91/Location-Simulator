import Foundation
import CoreLocation
import os

private let logger = Logger(subsystem: "com.locationsimulator", category: "Spoofing")

/// High-level location spoofing service combining the pymobiledevice3 bridge
/// with the navigation engine. This is the single source of truth for the
/// current spoofed location, navigation state, and device connection.
@Observable
final class LocationSpoofingService {
    // MARK: - Published State

    /// Current spoofed location on the device.
    private(set) var currentLocation: CLLocationCoordinate2D?
    /// Whether we have an active connection to a device.
    private(set) var isConnected: Bool = false
    /// Error message for display.
    var errorMessage: String?
    /// UDID of the connected device.
    private(set) var connectedDeviceUDID: String?

    /// Navigation engine (observable for UI binding).
    let navigation = NavigationEngine()

    /// Current speed in km/h.
    var speedKmh: Double = 60 {
        didSet { navigation.speedKmh = speedKmh }
    }

    /// Current transport mode.
    var transportMode: TransportMode = .driving {
        didSet { speedKmh = transportMode.defaultSpeedKmh }
    }

    private let bridge = Pymobiledevice3Bridge.shared

    // MARK: - Connection

    /// Connect to a device by UDID. Starts tunneld if needed.
    func connect(udid: String) {
        guard !isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.bridge.startTunnel(forDeviceUDID: udid)
                DispatchQueue.main.async {
                    self?.isConnected = true
                    self?.connectedDeviceUDID = udid
                    self?.errorMessage = nil
                    logger.info("Connected to \(udid)")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
                    logger.error("Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Disconnect from the current device.
    func disconnect() {
        navigation.stop()
        if let udid = connectedDeviceUDID {
            _ = bridge.clearSimulatedLocation()
            bridge.stopTunnel(forDeviceUDID: udid)
        }
        currentLocation = nil
        isConnected = false
        connectedDeviceUDID = nil
    }

    // MARK: - Location

    /// Teleport to a coordinate immediately.
    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard isConnected else { return }
        navigation.stop()
        let success = bridge.simulateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if success {
            currentLocation = coordinate
        } else {
            errorMessage = "Failed to set location"
        }
    }

    /// Clear the simulated location (restore real GPS).
    func clearLocation() {
        guard isConnected else { return }
        navigation.stop()
        let success = bridge.clearSimulatedLocation()
        if success {
            currentLocation = nil
        }
    }

    // MARK: - Navigation

    /// Start navigating along a route's coordinates.
    func startNavigation(route: [CLLocationCoordinate2D]) {
        guard isConnected, route.count >= 2 else { return }

        // Teleport to start if we don't have a current location
        if currentLocation == nil {
            if let start = route.first {
                _ = bridge.simulateLocation(latitude: start.latitude, longitude: start.longitude)
                currentLocation = start
            }
        }

        navigation.start(route: route, speedKmh: speedKmh) { [weak self] position in
            guard let self = self else { return }
            let success = self.bridge.simulateLocation(latitude: position.latitude, longitude: position.longitude)
            if success {
                self.currentLocation = position
            }
        }
    }

    /// Stop the current navigation.
    func stopNavigation() {
        navigation.stop()
    }

    /// Pause/resume navigation.
    func toggleNavigation() {
        if navigation.isNavigating {
            if navigation.progress > 0 {
                navigation.pause()
            }
        } else {
            navigation.resume()
        }
    }
}
