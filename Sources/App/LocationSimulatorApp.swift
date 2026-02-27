import SwiftUI

@main
struct LocationSimulatorApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            // File menu
            CommandGroup(after: .newItem) {
                Button("Scan for Devices") {
                    appState.scanForDevices()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Clear Location") {
                    appState.spoofing.clearLocation()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!appState.spoofing.isConnected)
            }

            // View menu
            CommandGroup(after: .toolbar) {
                Picker("Map Type", selection: Binding(
                    get: { appState.mapType },
                    set: { appState.mapType = $0 }
                )) {
                    Text("Standard").tag(MapType.standard)
                    Text("Satellite").tag(MapType.satellite)
                    Text("Hybrid").tag(MapType.hybrid)
                }
            }

            // Navigate menu
            CommandMenu("Navigate") {
                Button("Start Navigation") {
                    if let idx = appState.selectedRouteIndex {
                        appState.startNavigation(routeIndex: idx)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.calculatedRoutes.isEmpty)

                Button("Stop Navigation") {
                    appState.stopNavigation()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!appState.spoofing.navigation.isNavigating)

                Divider()

                Button("Swap Origin / Destination") {
                    appState.swapFromTo()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Button("Increase Speed") {
                    appState.spoofing.speedKmh = min(200, appState.spoofing.speedKmh + 10)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Speed") {
                    appState.spoofing.speedKmh = max(1, appState.spoofing.speedKmh - 10)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

// Type alias for cleaner menu code
private typealias MapType = MKMapType

import MapKit
extension MKMapType: @retroactive Hashable {}
