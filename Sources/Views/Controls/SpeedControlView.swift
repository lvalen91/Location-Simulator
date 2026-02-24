import SwiftUI

/// Floating speed control that appears at the bottom of the map,
/// similar to Maps.app's navigation controls.
struct SpeedControlView: View {
    @Bindable var appState: AppState

    private var speedBinding: Binding<Double> {
        Binding(
            get: { appState.spoofing.speedKmh },
            set: { appState.spoofing.speedKmh = $0 }
        )
    }

    private var maxSpeed: Double {
        switch appState.spoofing.transportMode {
        case .walking: return 15
        case .cycling: return 50
        case .driving: return 200
        }
    }

    private var stepSize: Double {
        switch appState.spoofing.transportMode {
        case .walking: return 1
        case .cycling: return 5
        case .driving: return 10
        }
    }

    private var fraction: Double {
        (appState.spoofing.speedKmh - 1) / (maxSpeed - 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.spoofing.transportMode.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: {
                appState.spoofing.speedKmh = max(1, appState.spoofing.speedKmh - stepSize)
            }) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            // Custom progress bar instead of Slider
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let pct = min(max(value.location.x / geo.size.width, 0), 1)
                            appState.spoofing.speedKmh = (1 + pct * (maxSpeed - 1)).rounded()
                        }
                )
            }
            .frame(width: 140, height: 20)

            Button(action: {
                appState.spoofing.speedKmh = min(maxSpeed, appState.spoofing.speedKmh + stepSize)
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Text(String(format: "%.0f km/h", appState.spoofing.speedKmh))
                .monospacedDigit()
                .font(.system(.callout, design: .rounded, weight: .medium))
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// Compact speed display for the toolbar — uses minus/plus buttons instead of a slider
/// to avoid the ugly white track on Liquid Glass toolbars.
struct ToolbarSpeedControl: View {
    @Bindable var appState: AppState

    private var maxSpeed: Double {
        switch appState.spoofing.transportMode {
        case .walking: return 15
        case .cycling: return 50
        case .driving: return 200
        }
    }

    private var stepSize: Double {
        switch appState.spoofing.transportMode {
        case .walking: return 1
        case .cycling: return 5
        case .driving: return 10
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                appState.spoofing.speedKmh = max(1, appState.spoofing.speedKmh - stepSize)
            }) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)

            Text(String(format: "%.0f", appState.spoofing.speedKmh))
                .monospacedDigit()
                .font(.system(.body, design: .rounded, weight: .medium))
                .frame(minWidth: 36, alignment: .center)

            Button(action: {
                appState.spoofing.speedKmh = min(maxSpeed, appState.spoofing.speedKmh + stepSize)
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)

            Text("km/h")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
    }
}
