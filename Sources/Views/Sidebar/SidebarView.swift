import SwiftUI
import MapKit

/// Maps.app-style sidebar with route search, devices, saved routes, and recents.
struct SidebarView: View {
    @Bindable var appState: AppState
    @State private var renamingRouteID: UUID?
    @State private var renameText = ""

    var body: some View {
        List {
            // MARK: - Route Search
            RouteSearchPanel(appState: appState)

            // MARK: - Route Results
            if !appState.calculatedRoutes.isEmpty {
                RouteResultsPanel(appState: appState)
            }

            // MARK: - Devices
            Section("USB Devices") {
                if appState.devices.isEmpty {
                    if appState.isScanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Scanning USB...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No USB devices found")
                                .foregroundStyle(.secondary)
                            Text("Connect an iPhone via USB cable")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                ForEach(appState.devices) { device in
                    let isSelected = device == appState.selectedDevice
                    let isConnected = isSelected && appState.spoofing.isConnected
                    let isConnecting = isSelected && !appState.spoofing.isConnected

                    HStack {
                        Image(systemName: "cable.connector")
                            .foregroundStyle(isConnected ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(device.name)
                                .lineLimit(1)
                            Text(isConnected ? "Connected" : isConnecting ? "Connecting..." : "Tap to connect")
                                .font(.caption2)
                                .foregroundStyle(isConnected ? .green : .secondary)
                        }
                        Spacer()
                        if isConnected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if isConnecting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isConnected {
                            appState.disconnectSelectedDevice()
                        } else {
                            appState.connectDevice(device)
                        }
                    }
                }

                Button(action: { appState.scanForDevices() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(appState.isScanning)
            }

            // MARK: - Navigation Status
            if appState.spoofing.navigation.isNavigating {
                Section("Navigation") {
                    NavigationStatusView(appState: appState)
                }
            }

            // MARK: - Saved Routes
            Section("Saved Routes") {
                if appState.savedRoutes.isEmpty {
                    Text("No saved routes")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.savedRoutes) { route in
                        SavedRouteRow(route: route, appState: appState,
                                      renamingRouteID: $renamingRouteID, renameText: $renameText)
                    }
                }
            }

            // MARK: - Recent Routes
            Section("Recent") {
                if appState.recentRoutes.isEmpty {
                    Text("No recent routes")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.recentRoutes) { route in
                        RecentRouteRow(route: route, appState: appState)
                    }
                }
                if !appState.recentRoutes.isEmpty {
                    Button("Clear Recents", role: .destructive) {
                        appState.clearRecentRoutes()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 260, idealWidth: 300)
        .onAppear {
            appState.scanForDevices()
        }
    }
}

// MARK: - Navigation Status

private struct NavigationStatusView: View {
    @Bindable var appState: AppState

    var body: some View {
        let nav = appState.spoofing.navigation
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: nav.progress)
                .tint(.blue)

            HStack {
                Text(String(format: "%.1f km/h", appState.spoofing.speedKmh))
                    .font(.caption)
                    .monospacedDigit()
                Spacer()
                Text(String(format: "%.0f%%", nav.progress * 100))
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            HStack {
                Button(action: { appState.spoofing.toggleNavigation() }) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive, action: { appState.stopNavigation() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Saved Route Row

private struct SavedRouteRow: View {
    let route: SavedRoute
    @Bindable var appState: AppState
    @Binding var renamingRouteID: UUID?
    @Binding var renameText: String

    var body: some View {
        HStack {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            if renamingRouteID == route.id {
                TextField("Route name", text: $renameText, onCommit: {
                    appState.renameSavedRoute(id: route.id, newName: renameText)
                    renamingRouteID = nil
                })
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            } else {
                VStack(alignment: .leading) {
                    Text(route.displayName)
                        .lineLimit(1)
                    Text(route.fromName + " → " + route.toName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: route.transportMode.systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.startNavigationFromSaved(route)
        }
        .contextMenu {
            Button("Start Navigation") { appState.startNavigationFromSaved(route) }
            Button("Rename...") {
                renameText = route.name.isEmpty ? route.displayName : route.name
                renamingRouteID = route.id
            }
            Divider()
            Button("Delete", role: .destructive) { appState.deleteSavedRoute(id: route.id) }
        }
    }
}

// MARK: - Recent Route Row

private struct RecentRouteRow: View {
    let route: RecentRoute
    @Bindable var appState: AppState

    var body: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(route.displayName)
                    .lineLimit(1)
                Text(route.usedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: route.transportMode.systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.startNavigationFromRecent(route)
        }
    }
}
