import SwiftUI
import MapKit

/// Floating secondary panel that lists the items in the currently-selected
/// Places category. Modeled on Apple Maps' "Recently Added" / "Saved" panels:
/// title bar with a close button, then a scrollable list of pill-style rows.
struct PlacesDetailPanel: View {
    @Bindable var appState: AppState
    let category: PlacesCategory

    @State private var renamingID: UUID?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            contentList
        }
        .padding(12)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 4)
    }

    // MARK: - Header (matches Apple Maps: bold title, plain X button, no icon)

    private var header: some View {
        HStack(spacing: 8) {
            Text(category.title)
                .font(.title2.bold())
            Spacer()
            Button {
                appState.selectedPlacesCategory = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentList: some View {
        switch category {
        case .pinned:
            pinnedList
        case .savedRoutes:
            savedRoutesList
        case .recent:
            recentList
        case .devices:
            devicesList
        }
    }

    /// Dismiss the popup once the user has triggered an action that loads
    /// state into the main view (route, teleport, device connect).
    private func dismiss() {
        appState.selectedPlacesCategory = nil
    }

    // MARK: - Pinned

    private var pinnedList: some View {
        Group {
            if appState.pinnedLocations.isEmpty {
                emptyState(message: "No pinned locations",
                           hint: "Right-click the map → Pin")
            } else {
                scrollableRows {
                    ForEach(appState.pinnedLocations) { pin in
                        PinnedRow(pin: pin, appState: appState,
                                  renamingID: $renamingID, renameText: $renameText)
                    }
                    clearButton(title: "Clear Pins") {
                        appState.clearPinnedLocations()
                    }
                }
            }
        }
    }

    // MARK: - Saved Routes

    private var savedRoutesList: some View {
        Group {
            if appState.savedRoutes.isEmpty {
                emptyState(message: "No saved routes",
                           hint: "Calculate a route, then tap Save Route")
            } else {
                scrollableRows {
                    ForEach(appState.savedRoutes) { route in
                        SavedRoutePanelRow(route: route, appState: appState,
                                           renamingID: $renamingID, renameText: $renameText)
                    }
                }
            }
        }
    }

    // MARK: - Devices

    private var devicesList: some View {
        Group {
            if appState.devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if appState.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        emptyState(message: "No devices found",
                                   hint: "Connect an iPhone via USB or pair over Wi-Fi.")
                    }
                    refreshButton
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(appState.devices) { device in
                        DeviceRow(device: device, appState: appState, onTap: dismiss)
                    }
                    refreshButton
                }
            }
        }
    }

    private var refreshButton: some View {
        Button(action: { appState.scanForDevices() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .disabled(appState.isScanning)
        .padding(.top, 4)
    }

    // MARK: - Recent

    private var recentList: some View {
        Group {
            if appState.recentRoutes.isEmpty {
                emptyState(message: "No recent routes",
                           hint: "Start a navigation and it'll appear here")
            } else {
                scrollableRows {
                    ForEach(appState.recentRoutes) { route in
                        RecentRoutePanelRow(route: route, appState: appState)
                    }
                    clearButton(title: "Clear Recents") {
                        appState.clearRecentRoutes()
                    }
                }
            }
        }
    }

    // MARK: - Shared helpers

    /// Hugs content vertically up to ~480 pt; scrolls beyond that. Matches
    /// Apple Maps' panel which shrinks to fit a short list but scrolls when
    /// there are many entries.
    @ViewBuilder
    private func scrollableRows<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
        .frame(maxHeight: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyState(message: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func clearButton(title: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: "trash")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .padding(.top, 8)
    }
}

// MARK: - Pinned Row

private struct PinnedRow: View {
    let pin: PinnedLocation
    @Bindable var appState: AppState
    @Binding var renamingID: UUID?
    @Binding var renameText: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 28, height: 28)
                Image(systemName: "mappin")
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }

            VStack(alignment: .leading, spacing: 1) {
                if renamingID == pin.id {
                    TextField("Pin name", text: $renameText, onCommit: {
                        appState.renamePinnedLocation(id: pin.id, newName: renameText)
                        renamingID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                } else {
                    Text(pin.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    Text(String(format: "%.5f, %.5f",
                                pin.coordinate.latitude, pin.coordinate.longitude))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                Button("Teleport Here") { appState.teleportToPin(pin) }
                Button("Rename...") {
                    renameText = pin.name.isEmpty ? pin.displayName : pin.name
                    renamingID = pin.id
                }
                Divider()
                Button("Delete", role: .destructive) {
                    appState.deletePinnedLocation(id: pin.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.teleportToPin(pin)
            appState.selectedPlacesCategory = nil
        }
    }
}

// MARK: - Saved Route Row (panel variant)

private struct SavedRoutePanelRow: View {
    let route: SavedRoute
    @Bindable var appState: AppState
    @Binding var renamingID: UUID?
    @Binding var renameText: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 28, height: 28)
                Image(systemName: "star.fill")
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }

            VStack(alignment: .leading, spacing: 1) {
                if renamingID == route.id {
                    TextField("Route name", text: $renameText, onCommit: {
                        appState.renameSavedRoute(id: route.id, newName: renameText)
                        renamingID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                } else {
                    Text(route.displayName)
                        .font(.callout)
                        .lineLimit(1)
                    Text(route.routePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: route.transportMode.systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
            Menu {
                Button("Start Navigation") { appState.startNavigationFromSaved(route) }
                Button("Rename...") {
                    renameText = route.name.isEmpty ? route.displayName : route.name
                    renamingID = route.id
                }
                Divider()
                Button("Delete", role: .destructive) {
                    appState.deleteSavedRoute(id: route.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.startNavigationFromSaved(route)
            appState.selectedPlacesCategory = nil
        }
    }
}

// MARK: - Recent Route Row (panel variant)

private struct RecentRoutePanelRow: View {
    let route: RecentRoute
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 28, height: 28)
                Image(systemName: "clock.fill")
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(route.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text(route.usedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: route.transportMode.systemImage)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            appState.startNavigationFromRecent(route)
            appState.selectedPlacesCategory = nil
        }
    }
}

// MARK: - Device Row (panel variant)

private struct DeviceRow: View {
    let device: DeviceInfo
    @Bindable var appState: AppState
    /// Called after a successful connect/disconnect action so the popup
    /// can auto-close.
    let onTap: () -> Void

    var body: some View {
        let isSelected = device == appState.selectedDevice
        let isConnected = isSelected && appState.spoofing.isConnected
        let isConnecting = isSelected && !appState.spoofing.isConnected
        let isWiFi = device.connectionType == "Wi-Fi"
        let iconName = isWiFi ? "wifi" : "cable.connector"
        let tint: Color = isConnected ? .green : .blue

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .foregroundStyle(.white)
                    .font(.caption.bold())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(isConnected
                     ? "Connected (\(device.connectionType))"
                     : isConnecting
                       ? "Connecting…"
                       : "Tap to connect (\(device.connectionType))")
                    .font(.caption2)
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isConnecting {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if isConnected {
                appState.disconnectSelectedDevice()
            } else {
                appState.connectDevice(device)
            }
            onTap()
        }
    }
}
