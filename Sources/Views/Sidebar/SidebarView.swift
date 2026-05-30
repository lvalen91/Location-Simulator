import SwiftUI
import MapKit

/// Maps.app-style sidebar. Top: route search + results + devices + navigation.
/// Bottom: a "Places" section whose rows open a floating detail panel listing
/// items in each category (Pinned, Saved Routes, Recent).
struct SidebarView: View {
    @Bindable var appState: AppState

    var body: some View {
        List {
            // MARK: - Route Search (always at top)
            RouteSearchPanel(appState: appState)

            // MARK: - Navigation Status (appears above Routes when active)
            if appState.spoofing.navigation.isNavigating {
                Section("Navigation") {
                    NavigationStatusView(appState: appState)
                }
            }

            // MARK: - Route Results
            if !appState.calculatedRoutes.isEmpty {
                RouteResultsPanel(appState: appState)
            }

            // MARK: - Places (Apple Maps-style category rows; Devices lives here too)
            Section("Places") {
                ForEach(PlacesCategory.allCases) { category in
                    PlacesCategoryRow(category: category, appState: appState)
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
                let paused = nav.isPaused
                Button(action: { appState.spoofing.toggleNavigation() }) {
                    Label(paused ? "Resume" : "Pause",
                          systemImage: paused ? "play.fill" : "pause.fill")
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

// MARK: - Places Category Row

private struct PlacesCategoryRow: View {
    let category: PlacesCategory
    @Bindable var appState: AppState

    private var count: Int {
        switch category {
        case .pinned: return appState.pinnedLocations.count
        case .savedRoutes: return appState.savedRoutes.count
        case .recent: return appState.recentRoutes.count
        case .devices: return appState.devices.count
        }
    }

    var body: some View {
        let isSelected = appState.selectedPlacesCategory == category
        HStack {
            Image(systemName: category.systemImage)
                .foregroundStyle(isSelected ? .white : .blue)
                .frame(width: 22)
            Text(category.title)
                .foregroundStyle(isSelected ? .white : .primary)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary.opacity(0.6))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .onTapGesture {
            appState.selectedPlacesCategory = isSelected ? nil : category
        }
    }
}
