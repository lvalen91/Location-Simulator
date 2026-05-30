import SwiftUI
import AppKit

@main
struct LocationSimulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isDuplicateInstance = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        if let existing = others.first {
            isDuplicateInstance = true
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        Pymobiledevice3Bridge.shared.stopAllTunnels()
        killAllTunneld()
    }

    private func killAllTunneld() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "pymobiledevice3 remote tunneld"]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        try? pkill.run()
        pkill.waitUntilExit()

        // pkill returns 1 if the process is owned by root (started via sudo);
        // escalate via osascript so the SIGTERM actually lands.
        Thread.sleep(forTimeInterval: 0.2)
        if tunneldStillRunning() {
            let script = "do shell script \"/usr/bin/pkill -f 'pymobiledevice3 remote tunneld'\" with administrator privileges"
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", script]
            osa.standardOutput = FileHandle.nullDevice
            osa.standardError = FileHandle.nullDevice
            try? osa.run()
            osa.waitUntilExit()
        }
    }

    private func tunneldStillRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "pymobiledevice3 remote tunneld"]
        proc.standardOutput = Pipe()
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
