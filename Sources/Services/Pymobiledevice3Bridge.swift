import Foundation
import os

private let kTunnelInfoPath = "/tmp/pymobiledevice3_tunnel.txt"
private let kDaemonStartTimeout: TimeInterval = 120  // first-run DDI download + mount can exceed a minute
private let kTunneldURL = "http://127.0.0.1:49151/"
private let logger = Logger(subsystem: "com.locationsimulator", category: "Bridge")

/// Errors from the pymobiledevice3 bridge. Each case describes a distinct
/// failure mode so the UI can surface actionable guidance instead of a
/// generic "Failed to connect".
enum BridgeError: LocalizedError {
    case notInstalled
    case pythonNotFound
    case daemonScriptMissing
    case tunneldNotRunning
    case tunneldStartFailed
    case tunneldUnreachable(String)
    case tunneldRegistryEmpty
    case noTunnelForDevice(udid: String, availableUDIDs: [String])
    case developerModeDisabled
    case ddiMountFailed(String)
    case daemonStartTimeout
    case daemonExited(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return """
            pymobiledevice3 is not installed.
            Install it with:
              pipx install pymobiledevice3
            (or: pip3 install --user pymobiledevice3)
            """
        case .pythonNotFound:
            return """
            Python 3 was not found.
            Install Python 3 (e.g. via Homebrew: brew install python) and relaunch.
            """
        case .daemonScriptMissing:
            return """
            Internal error: location_daemon.py is missing from the app bundle.
            Reinstall Location Simulator.
            """
        case .tunneldNotRunning:
            return """
            pymobiledevice3 tunneld is not running.
            Start it with:
              sudo pymobiledevice3 remote tunneld
            tunneld must run as root to create the RemoteXPC tunnel that iOS 17+ requires.
            """
        case .tunneldStartFailed:
            return """
            Tried to start tunneld but it did not come up.
            Likely causes:
              • Admin prompt was cancelled
              • Port 49151 is already in use by another process
              • pymobiledevice3 binary path is wrong
            Start tunneld manually in Terminal:
              sudo pymobiledevice3 remote tunneld
            """
        case .tunneldUnreachable(let detail):
            return """
            Could not reach tunneld at \(kTunneldURL).
            Detail: \(detail)
            Try restarting tunneld:
              sudo pkill -f 'pymobiledevice3 remote tunneld'
              sudo pymobiledevice3 remote tunneld
            """
        case .tunneldRegistryEmpty:
            return """
            tunneld is running but has not discovered the device yet.
            Most common fix:
              1. Unplug the iPhone, wait 2 seconds, plug it back in.
              2. On the phone, accept "Trust this computer" if prompted.
              3. Click Refresh.
            If that doesn't work, check the less-common causes:
              • Developer Mode is off (Settings > Privacy & Security > Developer Mode) — required on iOS 17+
              • A VPN or firewall is blocking mDNS/Bonjour traffic
              • tunneld was started before the device was plugged in (restart it)
            """
        case .noTunnelForDevice(let udid, let available):
            let head = String(udid.prefix(8))
            let availStr = available.isEmpty
                ? "(none)"
                : available.map { String($0.prefix(8)) + "…" }.joined(separator: ", ")
            return """
            tunneld is up but has no tunnel for this device yet (\(head)…).
            Tunnels currently in registry: \(availStr)
            Most common fix:
              1. Unplug the iPhone, wait 2 seconds, plug it back in.
              2. Click Refresh.
            tunneld discovery is async and can take 10–20 seconds after a fresh plug-in.
            """
        case .developerModeDisabled:
            return """
            Developer Mode is disabled on the iPhone.
            On the device: Settings > Privacy & Security > Developer Mode > On, then reboot the phone.
            iOS 17+ requires Developer Mode for location simulation.
            """
        case .ddiMountFailed(let detail):
            return """
            Failed to mount the Developer Disk Image on the iPhone.
            Detail: \(detail)
            Make sure the device is unlocked, Developer Mode is on, and the trust prompt has been accepted. On first use the DDI is downloaded (~600 MB); a slow network can cause this to time out.
            """
        case .daemonStartTimeout:
            return """
            Timed out waiting for the location daemon to become ready.
            First-run DDI download can take over a minute on a slow connection. Try again, or check Console.app filtered by 'com.locationsimulator' for the daemon's last output.
            """
        case .daemonExited(let detail):
            return """
            The location daemon exited unexpectedly before reporting READY.
            Detail: \(detail)
            Check Console.app filtered by 'com.locationsimulator' for the full traceback.
            """
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}

/// Singleton bridge to pymobiledevice3 for iOS 17+ location simulation.
///
/// Launches a persistent Python daemon (location_daemon.py) that maintains
/// a DVT connection. Commands (SET/CLEAR/PING/QUIT) are sent via stdin.
final class Pymobiledevice3Bridge {
    static let shared = Pymobiledevice3Bridge()

    private let queue = DispatchQueue(label: "com.locationsimulator.bridge")
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonStdout: FileHandle?
    private var daemonStderr: Pipe?
    private var daemonReady = false
    private var connectedUDIDs: Set<String> = []
    private var tunneldStartAttempted = false

    private var _binaryPath: String?
    private var binaryPathResolved = false
    private let binaryLock = NSLock()

    private var _pythonPath: String?
    private var pythonPathResolved = false
    private let pythonLock = NSLock()

    private init() {}

    // MARK: - Binary Discovery

    func isAvailable() -> Bool { binaryPath != nil }

    var binaryPath: String? {
        binaryLock.lock()
        defer { binaryLock.unlock() }
        if binaryPathResolved { return _binaryPath }
        binaryPathResolved = true
        _binaryPath = resolveBinaryPath()
        return _binaryPath
    }

    private var pythonPath: String? {
        pythonLock.lock()
        defer { pythonLock.unlock() }
        if pythonPathResolved { return _pythonPath }
        pythonPathResolved = true
        _pythonPath = resolvePythonPath()
        return _pythonPath
    }

    private func resolveBinaryPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/pymobiledevice3",
            "\(home)/.local/pipx/venvs/pymobiledevice3/bin/pymobiledevice3",
            "/opt/homebrew/bin/pymobiledevice3",
            "/usr/local/bin/pymobiledevice3"
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            logger.info("Found binary at \(c, privacy: .public)")
            return c
        }
        // Check Python user installs
        let libDir = "\(home)/Library/Python"
        if let versions = try? fm.contentsOfDirectory(atPath: libDir) {
            for ver in versions.sorted().reversed() {
                let c = "\(libDir)/\(ver)/bin/pymobiledevice3"
                if fm.isExecutableFile(atPath: c) {
                    logger.info("Found binary at \(c, privacy: .public)")
                    return c
                }
            }
        }
        // Fall back to which
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["pymobiledevice3"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                logger.info("Found binary via which at \(path, privacy: .public)")
                return path
            }
        } catch {}
        logger.error("Binary not found")
        return nil
    }

    private func resolvePythonPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // pipx venv
        let pipxBin = "\(home)/.local/pipx/venvs/pymobiledevice3/bin"
        for name in ["python3", "python"] {
            let c = "\(pipxBin)/\(name)"
            if fm.isExecutableFile(atPath: c) { return c }
        }
        // Adjacent to binary
        if let bin = binaryPath {
            let dir = (bin as NSString).deletingLastPathComponent
            for name in ["python3", "python"] {
                let c = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: c) { return c }
            }
        }
        // System python
        for c in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if fm.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    // MARK: - Daemon Script

    private var daemonScriptPath: String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.path(forResource: "location_daemon", ofType: "py") {
            return bundled
        }
        var dir = Bundle.main.bundlePath
        for _ in 0..<10 {
            dir = (dir as NSString).deletingLastPathComponent
            let c = (dir as NSString).appendingPathComponent("location_daemon.py")
            if fm.fileExists(atPath: c) { return c }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        for path in [
            "\(home)/Downloads/LocationSimulator2/Resources/location_daemon.py",
            "\(home)/Downloads/LocationSimulator-master/location_daemon.py"
        ] {
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Daemon Lifecycle

    private func startDaemon() throws {
        if daemonReady, let p = daemonProcess, p.isRunning { return }
        stopDaemon()

        guard let python = pythonPath else {
            logger.error("Cannot start daemon — Python not found")
            throw BridgeError.pythonNotFound
        }
        guard let script = daemonScriptPath else {
            logger.error("Cannot start daemon — location_daemon.py not found")
            throw BridgeError.daemonScriptMissing
        }

        logger.info("[stage 3] startDaemon python=\(python, privacy: .public) script=\(script, privacy: .public) udid=\(String(self.connectedUDIDs.first?.prefix(8) ?? "n/a"), privacy: .public)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        var args = [script, kTunnelInfoPath]
        if let udid = connectedUDIDs.first { args.append(udid) }
        process.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain the daemon's stderr on a background thread so Python
        // tracebacks (e.g. pymobiledevice3 / asyncio errors that fire before
        // the daemon can format an ERROR response) reach the unified log
        // instead of being lost to /dev/null.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let str = String(data: data, encoding: .utf8) else { return }
            for line in str.split(separator: "\n") where !line.isEmpty {
                logger.warning("Daemon stderr: \(String(line), privacy: .public)")
            }
        }

        let spawnStart = Date()
        do { try process.run() }
        catch {
            logger.error("Failed to launch daemon: \(error.localizedDescription, privacy: .public)")
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw BridgeError.daemonExited("spawn failed: \(error.localizedDescription)")
        }

        daemonProcess = process
        daemonStdin = stdinPipe.fileHandleForWriting
        daemonStdout = stdoutPipe.fileHandleForReading
        daemonStderr = stderrPipe

        let deadline = Date().addingTimeInterval(kDaemonStartTimeout)
        while Date() < deadline {
            guard let line = readLine(timeout: 1.0) else {
                if !process.isRunning {
                    let elapsed = Date().timeIntervalSince(spawnStart)
                    logger.error("Daemon exited during startup after \(String(format: "%.2f", elapsed), privacy: .public)s, status=\(process.terminationStatus, privacy: .public)")
                    stopDaemon()
                    throw BridgeError.daemonExited("Process exited during startup (status \(process.terminationStatus))")
                }
                continue
            }
            logger.info("Daemon stdout: \(line, privacy: .public)")
            if line == "READY" {
                let elapsed = Date().timeIntervalSince(spawnStart)
                logger.info("[stage 3] READY in \(String(format: "%.2f", elapsed), privacy: .public)s")
                daemonReady = true
                process.terminationHandler = { [weak self] _ in
                    self?.queue.async { self?.daemonReady = false }
                }
                return
            }
            if line.hasPrefix("ERROR") {
                let msg = String(line.dropFirst("ERROR".count))
                    .trimmingCharacters(in: .whitespaces)
                let elapsed = Date().timeIntervalSince(spawnStart)
                logger.error("[stage 3] daemon ERROR after \(String(format: "%.2f", elapsed), privacy: .public)s: \(msg, privacy: .public)")
                stopDaemon()
                throw classifyDaemonError(msg)
            }
        }
        let elapsed = Date().timeIntervalSince(spawnStart)
        logger.error("[stage 3] timeout after \(String(format: "%.2f", elapsed), privacy: .public)s waiting for READY")
        stopDaemon()
        throw BridgeError.daemonStartTimeout
    }

    /// Map a daemon ERROR string to a specific BridgeError so the UI can
    /// show targeted guidance. Falls back to `.connectionFailed` if the
    /// message doesn't match any known pattern.
    private func classifyDaemonError(_ msg: String) -> BridgeError {
        let lower = msg.lowercased()
        if lower.contains("developer mode is not enabled") {
            return .developerModeDisabled
        }
        if lower.contains("ddi mount failed") || lower.contains("personalized image") {
            return .ddiMountFailed(msg)
        }
        if lower.contains("no tunnel found") {
            return .tunneldRegistryEmpty
        }
        return .connectionFailed(msg)
    }

    private func stopDaemon() {
        if let stdin = daemonStdin, daemonProcess?.isRunning == true {
            stdin.write("QUIT\n".data(using: .utf8)!)
        }
        daemonStderr?.fileHandleForReading.readabilityHandler = nil
        daemonProcess?.terminate()
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
        daemonStderr = nil
        daemonReady = false
    }

    private func sendCommand(_ command: String) -> String? {
        guard let stdin = daemonStdin, daemonProcess?.isRunning == true else { return nil }
        stdin.write((command + "\n").data(using: .utf8)!)
        return readLine(timeout: 5.0)
    }

    private func readLine(timeout: TimeInterval) -> String? {
        guard let stdout = daemonStdout else { return nil }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let available = stdout.availableData
            if available.isEmpty { Thread.sleep(forTimeInterval: 0.01); continue }
            buffer.append(available)
            if let str = String(data: buffer, encoding: .utf8), str.contains("\n") {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if !buffer.isEmpty, let str = String(data: buffer, encoding: .utf8) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // MARK: - Tunneld Management

    func isTunneldRunning() -> Bool {
        // Fast path: HTTP probe of the tunneld API.
        if let url = URL(string: kTunneldURL) {
            let sem = DispatchSemaphore(value: 0)
            var running = false
            URLSession.shared.dataTask(with: url) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 { running = true }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 3)
            if running { return true }
        }
        // Fallback: the HTTP probe is unreliable from inside the app, so treat a
        // live `pymobiledevice3 remote tunneld` process as running. Without this,
        // a leftover tunneld (which survives app quit) is invisible here and the
        // app spawns a duplicate that fails to bind port 49151 (EADDRINUSE).
        return isTunneldProcessRunning()
    }

    /// True if a `pymobiledevice3 remote tunneld` process is alive, regardless of
    /// owning user. Used as a fallback when the HTTP probe fails.
    private func isTunneldProcessRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "pymobiledevice3 remote tunneld"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch {
            logger.error("pgrep tunneld check failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 && !data.isEmpty
    }

    /// Discover iOS devices (USB and Wi-Fi) using pymobiledevice3 usbmux list.
    ///
    /// `usbmux list` without flags returns both USB- and Wi-Fi-paired devices.
    /// Wi-Fi devices require a previous USB pairing with this Mac and "Sync over
    /// Wi-Fi" enabled in Finder; the tunneld daemon then builds the iOS 17+
    /// RemoteXPC tunnel over mDNS just like for USB devices.
    func discoverDevices() -> [DeviceInfo] {
        guard let binary = binaryPath else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--no-color", "usbmux", "list"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch {
            logger.error("Failed to list devices: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Fall back: try idevice_id
            return discoverDevicesViaLibimobiledevice()
        }

        // A device paired both via USB and Wi-Fi will appear twice in the
        // listing (once per transport). Prefer USB when both are present.
        var byUDID: [String: DeviceInfo] = [:]
        for entry in json {
            guard let udid = entry["UniqueDeviceID"] as? String
                    ?? entry["SerialNumber"] as? String else { continue }
            // Try to get device name from the JSON first
            var name = entry["DeviceName"] as? String
            // If no name, try ideviceinfo
            if name == nil || name?.isEmpty == true {
                name = queryDeviceName(udid: udid)
            }
            // Fall back to product type or UDID
            if name == nil || name?.isEmpty == true {
                name = entry["ProductType"] as? String
            }
            let rawType = (entry["ConnectionType"] as? String) ?? "USB"
            let connType = rawType.caseInsensitiveCompare("Network") == .orderedSame ? "Wi-Fi" : "USB"
            let info = DeviceInfo(id: udid, name: name ?? udid, connectionType: connType)
            if let existing = byUDID[udid], existing.connectionType == "USB" { continue }
            byUDID[udid] = info
        }
        return Array(byUDID.values).sorted { lhs, rhs in
            if lhs.connectionType != rhs.connectionType {
                return lhs.connectionType == "USB"  // USB first
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Query device name for a UDID via ideviceinfo or pymobiledevice3.
    private func queryDeviceName(udid: String) -> String? {
        // Try idevicename first (fast)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["idevicename", "-u", udid]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let name = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        } catch {}
        return nil
    }

    /// Fallback: discover devices via idevice_id (libimobiledevice), both USB and network.
    private func discoverDevicesViaLibimobiledevice() -> [DeviceInfo] {
        func list(flag: String) -> [String] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["idevice_id", flag]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let usbUDIDs = Set(list(flag: "-l"))
        let netUDIDs = Set(list(flag: "-n"))

        var byUDID: [String: DeviceInfo] = [:]
        for udid in usbUDIDs.union(netUDIDs) {
            let conn = usbUDIDs.contains(udid) ? "USB" : "Wi-Fi"
            byUDID[udid] = DeviceInfo(id: udid, name: String(udid.prefix(8)) + "...", connectionType: conn)
        }
        return Array(byUDID.values).sorted { lhs, rhs in
            if lhs.connectionType != rhs.connectionType {
                return lhs.connectionType == "USB"
            }
            return lhs.id < rhs.id
        }
    }

    func ensureTunneldRunning() -> Bool {
        if isTunneldRunning() { return true }
        guard !tunneldStartAttempted else { return false }
        tunneldStartAttempted = true
        guard let binary = binaryPath else { return false }

        logger.info("ensureTunneldRunning: launching via osascript with admin privileges, binary=\(binary, privacy: .public)")
        let osaStart = Date()
        let script = "do shell script \"\(binary) remote tunneld &> /dev/null & echo $!\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            let osaElapsed = Date().timeIntervalSince(osaStart)
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.info("ensureTunneldRunning: osascript exit=\(proc.terminationStatus, privacy: .public) elapsed=\(String(format: "%.2f", osaElapsed), privacy: .public)s stderr=\(errOutput, privacy: .public)")
            if proc.terminationStatus == 0 {
                let waitStart = Date()
                for attempt in 0..<10 {
                    Thread.sleep(forTimeInterval: 1.0)
                    if isTunneldRunning() {
                        let waitElapsed = Date().timeIntervalSince(waitStart)
                        logger.info("ensureTunneldRunning: tunneld up after \(attempt + 1, privacy: .public)s (probe latency \(String(format: "%.2f", waitElapsed), privacy: .public)s)")
                        return true
                    }
                }
                logger.error("ensureTunneldRunning: osascript succeeded but tunneld never bound (10s elapsed)")
            }
        } catch {
            logger.error("ensureTunneldRunning: osascript spawn failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    // MARK: - Connection

    func startTunnel(forDeviceUDID udid: String) throws {
        let shortUDID = String(udid.prefix(8))
        logger.info("startTunnel called for udid=\(shortUDID, privacy: .public)")
        if queue.sync(execute: { connectedUDIDs.contains(udid) && daemonReady }) {
            logger.info("startTunnel: already connected to \(shortUDID, privacy: .public), no-op")
            return
        }
        guard isAvailable() else { throw BridgeError.notInstalled }

        // Stage 1 — make sure tunneld itself is up.
        logger.info("[stage 1] tunneld liveness check")
        let stage1Start = Date()
        if !isTunneldRunning() {
            logger.warning("[stage 1] tunneld not running, attempting to start")
            if !ensureTunneldRunning() {
                let elapsed = Date().timeIntervalSince(stage1Start)
                logger.error("[stage 1] failed after \(String(format: "%.2f", elapsed), privacy: .public)s (startAttempted=\(self.tunneldStartAttempted))")
                throw tunneldStartAttempted
                    ? BridgeError.tunneldStartFailed
                    : BridgeError.tunneldNotRunning
            }
        }
        logger.info("[stage 1] tunneld up after \(String(format: "%.2f", Date().timeIntervalSince(stage1Start)), privacy: .public)s")

        // Stage 2 — make sure tunneld has built a tunnel for *this* device.
        // tunneld discovery is async over mDNS; a freshly-plugged device can
        // take 10–20 seconds to appear in the registry, so we poll patiently
        // before surfacing an error to the user.
        logger.info("[stage 2] registry poll begin (timeout 20s)")
        let stage2Start = Date()
        let result = waitForTunnelInRegistry(udid: udid, timeout: 20.0)
        let stage2Elapsed = Date().timeIntervalSince(stage2Start)
        switch result {
        case .found:
            logger.info("[stage 2] tunnel found for \(shortUDID, privacy: .public) after \(String(format: "%.2f", stage2Elapsed), privacy: .public)s")
        case .empty:
            logger.error("[stage 2] registry empty after \(String(format: "%.2f", stage2Elapsed), privacy: .public)s")
            throw BridgeError.tunneldRegistryEmpty
        case .otherDevices(let udids):
            let shortList = udids.map { String($0.prefix(8)) }.joined(separator: ",")
            logger.error("[stage 2] our udid \(shortUDID, privacy: .public) absent after \(String(format: "%.2f", stage2Elapsed), privacy: .public)s; present=[\(shortList, privacy: .public)]")
            throw BridgeError.noTunnelForDevice(udid: udid, availableUDIDs: udids)
        case .unreachable(let detail):
            logger.error("[stage 2] tunneld unreachable after \(String(format: "%.2f", stage2Elapsed), privacy: .public)s: \(detail, privacy: .public)")
            throw BridgeError.tunneldUnreachable(detail)
        }

        // Stage 3 — spin up the per-device daemon. Specific BridgeErrors
        // bubble up unchanged so the UI shows the right guidance.
        try queue.sync {
            connectedUDIDs.insert(udid)
            do { try startDaemon() }
            catch {
                connectedUDIDs.remove(udid)
                throw error
            }
        }
    }

    private enum RegistryProbe {
        case found
        case empty
        case otherDevices([String])
        case unreachable(String)
    }

    /// Poll the tunneld registry for the given UDID. Returns as soon as the
    /// UDID appears, or after `timeout` seconds, whichever comes first.
    private func waitForTunnelInRegistry(udid: String, timeout: TimeInterval) -> RegistryProbe {
        let deadline = Date().addingTimeInterval(timeout)
        var lastResult: RegistryProbe = .empty
        while Date() < deadline {
            let result = probeTunneldRegistry(udid: udid)
            if case .found = result { return .found }
            lastResult = result
            Thread.sleep(forTimeInterval: 0.5)
        }
        return lastResult
    }

    private func probeTunneldRegistry(udid: String) -> RegistryProbe {
        guard let url = URL(string: kTunneldURL) else {
            return .unreachable("invalid URL")
        }
        let sem = DispatchSemaphore(value: 0)
        var probe: RegistryProbe = .unreachable("no response")
        var rawBody: String?
        var httpStatus: Int = -1
        let probeStart = Date()
        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                probe = .unreachable(error.localizedDescription)
                return
            }
            httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard httpStatus == 200 else {
                probe = .unreachable("HTTP \(httpStatus)")
                return
            }
            guard let data = data else {
                probe = .unreachable("no body")
                return
            }
            rawBody = String(data: data, encoding: .utf8)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                probe = .unreachable("malformed JSON from tunneld")
                return
            }
            if json.isEmpty {
                probe = .empty
                return
            }
            if json[udid] != nil {
                probe = .found
                return
            }
            probe = .otherDevices(Array(json.keys).sorted())
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        let latencyMs = Int(Date().timeIntervalSince(probeStart) * 1000)
        let bodySnippet = rawBody?.prefix(512).description ?? "<no body>"
        let outcome: String = {
            switch probe {
            case .found: return "found"
            case .empty: return "empty"
            case .otherDevices(let u): return "other(\(u.count))"
            case .unreachable(let d): return "unreachable(\(d))"
            }
        }()
        logger.debug("registry probe: outcome=\(outcome, privacy: .public) http=\(httpStatus, privacy: .public) latency=\(latencyMs, privacy: .public)ms body=\(bodySnippet, privacy: .public)")
        return probe
    }

    func stopTunnel(forDeviceUDID udid: String) {
        queue.sync {
            connectedUDIDs.remove(udid)
            if connectedUDIDs.isEmpty { stopDaemon() }
        }
    }

    func stopAllTunnels() {
        queue.sync { stopDaemon(); connectedUDIDs.removeAll() }
    }

    // MARK: - Location Simulation

    func simulateLocation(latitude: Double, longitude: Double) -> Bool {
        queue.sync {
            guard daemonReady else { return false }
            let resp = sendCommand("SET \(latitude) \(longitude)")
            if resp == "OK" { return true }
            // Retry with daemon restart. Swallow errors here — the caller
            // only cares whether the location was set; a richer error path
            // already exists via startTunnel.
            do { try startDaemon() } catch { return false }
            return sendCommand("SET \(latitude) \(longitude)") == "OK"
        }
    }

    func clearSimulatedLocation() -> Bool {
        queue.sync {
            guard daemonReady else { return false }
            return sendCommand("CLEAR") == "OK"
        }
    }
}
