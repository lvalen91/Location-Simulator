import SwiftUI
import MapKit

/// Displays calculated route options in the sidebar, Maps.app style.
/// Each route shows distance, duration, and can be selected to start navigation.
struct RouteResultsPanel: View {
    @Bindable var appState: AppState

    var body: some View {
        Section("Routes") {
            ForEach(Array(appState.calculatedRoutes.enumerated()), id: \.offset) { index, route in
                RouteCard(
                    route: route,
                    index: index,
                    isSelected: appState.selectedRouteIndex == index,
                    onSelect: {
                        appState.selectedRouteIndex = index
                    },
                    onGo: {
                        appState.startNavigation(routeIndex: index)
                    }
                )
            }

            // Action row
            HStack(spacing: 12) {
                if appState.toCoordinate != nil {
                    Button(action: { appState.saveCurrentRoute() }) {
                        Label("Save Route", systemImage: "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .font(.callout)
                }

                Spacer()

                Button(action: { appState.clearSearch() }) {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.callout)
            }
        }
    }
}

// MARK: - Route Card

private struct RouteCard: View {
    let route: MKRoute
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onGo: () -> Void

    private var distanceText: String {
        let km = route.distance / 1000
        if km < 1 {
            return String(format: "%.0f m", route.distance)
        }
        return String(format: "%.1f km", km)
    }

    private var durationText: String {
        let minutes = route.expectedTravelTime / 60
        if minutes < 60 {
            return String(format: "%.0f min", minutes)
        }
        let hours = Int(minutes) / 60
        let mins = Int(minutes) % 60
        return "\(hours) hr \(mins) min"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Route \(index + 1)")
                    .font(.headline)
                    .foregroundStyle(isSelected ? .blue : .primary)

                HStack(spacing: 12) {
                    Label(distanceText, systemImage: "arrow.triangle.turn.up.right.diamond")
                    Label(durationText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !route.name.isEmpty {
                    Text(route.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button("Go") { onGo() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        )
    }
}
