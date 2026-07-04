import Foundation
import CoreLocation
import os

private let logger = Log(category: "Spoofing")

/// High-level location spoofing service combining the pymobiledevice3 bridge
/// with the navigation engine. This is the single source of truth for the
/// current spoofed location, navigation state, and device connection.
@MainActor
@Observable
final class LocationSpoofingService {
    // MARK: - Published State

    /// Current spoofed location on the device.
    private(set) var currentLocation: CLLocationCoordinate2D?
    /// Whether we have an active connection to a device.
    private(set) var isConnected: Bool = false
    /// True while a connection attempt is in flight (guards against repeat
    /// connect requests stacking duplicate daemon launches).
    private(set) var isConnecting: Bool = false
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

    /// Connect to a device by UDID. Starts tunneld if needed. No-op if already
    /// connected or a connection attempt is already in flight.
    func connect(udid: String) {
        guard !isConnected, !isConnecting else { return }
        isConnecting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridge.startTunnel(forDeviceUDID: udid)
                await MainActor.run {
                    self.isConnected = true
                    self.connectedDeviceUDID = udid
                    self.errorMessage = nil
                    self.isConnecting = false
                    logger.info("Connected to \(String(udid.prefix(8)), privacy: .public)")
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isConnecting = false
                    logger.error("Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Disconnect from the current device.
    func disconnect() {
        navigation.stop()
        if let udid = connectedDeviceUDID {
            Task { [bridge] in
                _ = await bridge.clearSimulatedLocation()
                await bridge.stopTunnel(forDeviceUDID: udid)
            }
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
        Task { [weak self] in
            guard let self else { return }
            let success = await self.bridge.simulateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            await MainActor.run {
                if success {
                    self.currentLocation = coordinate
                    logger.info("Teleport \(coordinate.latitude), \(coordinate.longitude)")
                } else {
                    self.errorMessage = "Failed to set location"
                    logger.error("Teleport failed at \(coordinate.latitude), \(coordinate.longitude)")
                }
            }
        }
    }

    /// Clear the simulated location (restore real GPS).
    func clearLocation() {
        guard isConnected else { return }
        navigation.stop()
        Task { [weak self] in
            guard let self else { return }
            let success = await self.bridge.clearSimulatedLocation()
            if success {
                await MainActor.run {
                    self.currentLocation = nil
                    logger.info("Cleared simulated location")
                }
            }
        }
    }

    // MARK: - Navigation

    /// Start navigating along a route's coordinates.
    func startNavigation(route: [CLLocationCoordinate2D]) {
        guard isConnected, route.count >= 2 else { return }
        logger.info("Navigation started: \(route.count) points at \(String(format: "%.0f", speedKmh)) km/h")

        // Teleport to start if we don't have a current location
        if currentLocation == nil {
            if let start = route.first {
                currentLocation = start
                Task { [bridge] in _ = await bridge.simulateLocation(latitude: start.latitude, longitude: start.longitude) }
            }
        }

        navigation.start(route: route, speedKmh: speedKmh) { [weak self] position in
            // Called on the main run loop (NavigationEngine's timer). Update the
            // observable position here and push to the device off the main thread.
            // Ticks are ~1s apart — far longer than a SET round-trip — so each
            // tick's Task clears the bridge's I/O gate before the next fires.
            guard let self = self else { return }
            self.currentLocation = position
            Task { [bridge = self.bridge] in
                _ = await bridge.simulateLocation(latitude: position.latitude, longitude: position.longitude)
            }
        }
    }

    /// Stop the current navigation.
    func stopNavigation() {
        if navigation.isNavigating { logger.info("Navigation stopped") }
        navigation.stop()
    }

    /// Pause/resume navigation. No-op if navigation isn't running.
    func toggleNavigation() {
        guard navigation.isNavigating else { return }
        if navigation.isPaused {
            navigation.resume()
        } else {
            navigation.pause()
        }
    }
}
