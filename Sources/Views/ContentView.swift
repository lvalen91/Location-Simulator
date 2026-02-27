import SwiftUI
import MapKit

/// Main content view using NavigationSplitView — Maps.app layout.
/// Sidebar contains route search, devices, saved/recent routes.
/// Detail area is a full-bleed MKMapView with floating controls.
struct ContentView: View {
    @Bindable var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appState: appState)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            ZStack(alignment: .bottom) {
                // Full-bleed map
                MapViewRepresentable(appState: appState)
                    .ignoresSafeArea()

                // Status message overlay
                if let status = appState.statusMessage {
                    VStack {
                        HStack {
                            Spacer()
                            Text(status)
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                            Spacer()
                        }
                        .padding(.top, 12)
                        Spacer()
                    }
                }

                // Error message
                if let error = appState.spoofing.errorMessage {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error)
                                .font(.callout)
                            Button("Dismiss") {
                                appState.spoofing.errorMessage = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 80)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Picker("Map", selection: Binding(
                    get: { appState.mapType },
                    set: { appState.mapType = $0 }
                )) {
                    Label("Standard", systemImage: "map").tag(MKMapType.standard)
                    Label("Satellite", systemImage: "globe.americas").tag(MKMapType.satellite)
                    Label("Hybrid", systemImage: "square.stack.3d.up").tag(MKMapType.hybrid)
                }
                .pickerStyle(.menu)
                .help("Change map style")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: { appState.spoofing.clearLocation() }) {
                    Label("Clear Location", systemImage: "location.slash")
                }
                .disabled(!appState.spoofing.isConnected)
                .help("Stop spoofing and restore real GPS")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: { appState.acquireCurrentLocation() }) {
                    Label("My Location", systemImage: "location.fill")
                }
                .help("Teleport to this Mac's current GPS location")
            }

            ToolbarItem(placement: .automatic) {
                Button(action: { appState.scanForDevices() }) {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Scan for USB-connected iOS devices")
            }

            ToolbarItem(placement: .automatic) {
                ToolbarSpeedControl(appState: appState)
                    .help("Simulated movement speed")
            }
        }
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        if appState.spoofing.navigation.isNavigating {
            return "Navigating — \(String(format: "%.0f%%", appState.spoofing.navigation.progress * 100))"
        }
        if let device = appState.selectedDevice, appState.spoofing.isConnected {
            return "Location Simulator — \(device.name)"
        }
        return "Location Simulator"
    }

}
