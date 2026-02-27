import SwiftUI

/// Floating speed control that appears at the bottom of the map,
/// similar to Maps.app's navigation controls.
struct SpeedControlView: View {
    @Bindable var appState: AppState

    private let maxSpeed: Double = 200
    private let stepSize: Double = 10

    private var fraction: Double {
        (appState.spoofing.speedKmh - 1) / (maxSpeed - 1)
    }

    private var displaySpeed: Double {
        appState.useImperial
            ? appState.spoofing.speedKmh / 1.60934
            : appState.spoofing.speedKmh
    }

    private var unitLabel: String {
        appState.useImperial ? "mph" : "km/h"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "car")
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

            Text(String(format: "%.0f %@", displaySpeed, unitLabel))
                .monospacedDigit()
                .font(.system(.callout, design: .rounded, weight: .medium))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

/// Compact speed display for the toolbar — click the speed value to open
/// a popover with manual entry, bigger +/- buttons, and unit toggle.
struct ToolbarSpeedControl: View {
    @Bindable var appState: AppState
    @State private var showingPopover = false

    private let maxSpeed: Double = 200
    private let stepSize: Double = 10

    private var displaySpeed: Double {
        appState.useImperial
            ? appState.spoofing.speedKmh / 1.60934
            : appState.spoofing.speedKmh
    }

    private var unitLabel: String {
        appState.useImperial ? "mph" : "km/h"
    }

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12))
                Text(String(format: "%.0f", displaySpeed))
                    .monospacedDigit()
                    .font(.system(.body, design: .rounded, weight: .medium))
                Text(unitLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            SpeedPopover(appState: appState, maxSpeed: maxSpeed, stepSize: stepSize)
        }
    }
}

/// Popover content for speed adjustment with manual entry, +/- buttons, and unit toggle.
private struct SpeedPopover: View {
    @Bindable var appState: AppState
    let maxSpeed: Double
    let stepSize: Double

    @State private var textValue: String = ""
    @FocusState private var isTextFieldFocused: Bool

    private var displaySpeed: Double {
        appState.useImperial
            ? appState.spoofing.speedKmh / 1.60934
            : appState.spoofing.speedKmh
    }

    private var unitLabel: String {
        appState.useImperial ? "mph" : "km/h"
    }

    /// Step size converted to display units
    private var displayStep: Double {
        appState.useImperial ? stepSize / 1.60934 : stepSize
    }

    var body: some View {
        VStack(spacing: 12) {
            // Speed display with +/- buttons
            HStack(spacing: 16) {
                Button(action: decrementSpeed) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())

                // Editable speed field
                TextField("", text: $textValue)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .frame(width: 80)
                    .focused($isTextFieldFocused)
                    .onSubmit { commitTextValue() }

                Button(action: incrementSpeed) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }

            // Unit toggle
            Picker("Unit", selection: $appState.useImperial) {
                Text("km/h").tag(false)
                Text("mph").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }
        .padding(16)
        .frame(width: 220)
        .onAppear { syncTextField() }
        .onChange(of: appState.spoofing.speedKmh) { _, _ in syncTextField() }
        .onChange(of: appState.useImperial) { _, _ in syncTextField() }
    }

    private func syncTextField() {
        textValue = String(format: "%.0f", displaySpeed)
    }

    private func commitTextValue() {
        guard let entered = Double(textValue) else {
            syncTextField()
            return
        }
        let kmh = appState.useImperial ? entered * 1.60934 : entered
        appState.spoofing.speedKmh = min(maxSpeed, max(1, kmh)).rounded()
        syncTextField()
    }

    private func decrementSpeed() {
        appState.spoofing.speedKmh = max(1, appState.spoofing.speedKmh - stepSize)
    }

    private func incrementSpeed() {
        appState.spoofing.speedKmh = min(maxSpeed, appState.spoofing.speedKmh + stepSize)
    }
}
