import SwiftUI
import MapKit

/// Maps.app-style multi-stop route search panel.
/// Shows N waypoint rows (origin + optional stops + destination), each with
/// its own autocomplete. "+ Add Stop" inserts before the destination.
struct RouteSearchPanel: View {
    @Bindable var appState: AppState

    var body: some View {
        Section {
            VStack(spacing: 4) {
                // Waypoint rows — stable identity by UUID so each row keeps
                // its own @State SearchCompleterManager across insertions.
                ForEach(Array(appState.waypoints.enumerated()), id: \.element.id) { item in
                    WaypointRow(appState: appState, index: item.offset)
                }

                // Add Stop — inserts an empty stop before the destination.
                if appState.waypoints.count < 10 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { appState.addStop() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.system(size: 15))
                            Text("Add Stop")
                                .font(.callout)
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 18)
                    .padding(.vertical, 2)
                }

                // Action bar
                HStack {
                    Button(action: { appState.swapFromTo() }) {
                        Label("Reverse", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Reverse route order")

                    Spacer()

                    let hasContent = appState.waypoints.contains { !$0.text.isEmpty || !$0.name.isEmpty }
                    if hasContent {
                        Button(action: { appState.clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Clear search")
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Route")
        }
    }
}

// MARK: - WaypointRow

/// A single stop field with autocomplete. Owns its SearchCompleterManager via
/// @State so the instance survives array mutations on sibling stops.
private struct WaypointRow: View {
    @Bindable var appState: AppState
    let index: Int

    @State private var completer = SearchCompleterManager()
    @State private var showSuggestions = false
    @FocusState private var isFocused: Bool

    private var isValid: Bool { index < appState.waypoints.count }
    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == appState.waypoints.count - 1 }
    private var isMiddle: Bool { !isFirst && !isLast }

    private var dotColor: Color {
        if isFirst { return .green }
        if isLast  { return .red }
        return .orange
    }

    private var placeholder: String {
        if isFirst { return "Current Location" }
        if isLast  { return "Search destination" }
        return "Search stop \(index)"
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                guard index < appState.waypoints.count else { return "" }
                return appState.waypoints[index].text
            },
            set: { newVal in
                guard index < appState.waypoints.count else { return }
                appState.waypoints[index].text = newVal
                // Clearing the field also resets the resolved coordinate.
                if newVal.isEmpty {
                    appState.waypoints[index].coordinate = nil
                    appState.waypoints[index].name = ""
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 2)

                TextField(placeholder, text: textBinding)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isFocused)
                    .onChange(of: appState.waypoints.indices.contains(index) ? appState.waypoints[index].text : "") { _, newValue in
                        guard appState.waypoints.indices.contains(index) else { return }
                        completer.search(newValue)
                        showSuggestions = !newValue.isEmpty
                    }

                // Delete button — only for middle stops when ≥ 3 waypoints.
                if isMiddle {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { appState.removeStop(at: index) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Autocomplete dropdown
            if showSuggestions && isFocused && !completer.suggestions.isEmpty {
                SuggestionsList(suggestions: completer.suggestions) { suggestion in
                    completer.resolve(suggestion) { coord, name in
                        guard let coord, index < appState.waypoints.count else { return }
                        appState.waypoints[index].coordinate = coord
                        appState.waypoints[index].text = name ?? suggestion.title
                        appState.waypoints[index].name = name ?? suggestion.title
                        showSuggestions = false
                        isFocused = false
                        appState.tryCalculateRoutes()
                    }
                }
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                // Small delay so a tap on a suggestion row registers first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !isFocused { showSuggestions = false }
                }
            }
        }
    }
}

// MARK: - SuggestionsList

private struct SuggestionsList: View {
    let suggestions: [MKLocalSearchCompletion]
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                Button(action: { onSelect(suggestion) }) {
                    HStack {
                        Image(systemName: "mappin.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                                .font(.callout)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                if suggestion != suggestions.prefix(5).last {
                    Divider()
                }
            }
        }
        .background(.background.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
