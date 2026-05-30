import SwiftUI
import MapKit

/// Displays calculated route options in the sidebar, Maps.app style.
/// Handles both single-leg (multiple alternates) and multi-leg (single combined) results.
struct RouteResultsPanel: View {
    @Bindable var appState: AppState

    var body: some View {
        Section("Routes") {
            ForEach(Array(appState.calculatedRoutes.enumerated()), id: \.element.id) { item in
                RouteCard(
                    result: item.element,
                    index: item.offset,
                    isSelected: appState.selectedRouteIndex == item.offset,
                    onSelect: { appState.selectedRouteIndex = item.offset },
                    onGo: { appState.startNavigation(routeIndex: item.offset) }
                )
            }

            HStack(spacing: 12) {
                if appState.waypoints.last?.coordinate != nil {
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
    let result: RouteResult
    let index: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onGo: () -> Void

    private var distanceText: String {
        let km = result.totalDistance / 1000
        return km < 1
            ? String(format: "%.0f m", result.totalDistance)
            : String(format: "%.1f km", km)
    }

    private var durationText: String {
        let minutes = result.totalTime / 60
        if minutes < 60 { return String(format: "%.0f min", minutes) }
        let hours = Int(minutes) / 60
        let mins = Int(minutes) % 60
        return "\(hours) hr \(mins) min"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Route \(index + 1)")
                        .font(.headline)
                        .foregroundStyle(isSelected ? .blue : .primary)
                    if result.isMultiLeg {
                        Text("\(result.legs.count) legs")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }

                HStack(spacing: 12) {
                    Label(distanceText, systemImage: "arrow.triangle.turn.up.right.diamond")
                    Label(durationText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if result.isMultiLeg {
                    ForEach(Array(result.legs.enumerated()), id: \.offset) { legIdx, leg in
                        Text("Leg \(legIdx + 1): \(String(format: "%.1f km", leg.distance / 1000)), \(String(format: "%.0f min", leg.expectedTravelTime / 60))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else if let route = result.legs.first, !route.name.isEmpty {
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
