import Foundation
import os

private let kTunnelInfoPath = "/tmp/pymobiledevice3_tunnel.txt"
private let kDaemonStartTimeout: TimeInterval = 15
private let kTunneldURL = "http://127.0.0.1:49151/"
private let logger = Logger(subsystem: "com.locationsimulator", category: "Bridge")

/// Errors from the pymobiledevice3 bridge.
enum BridgeError: LocalizedError {
    case notInstalled
    case tunnelNotRunning
    case daemonFailed(String)
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "pymobiledevice3 not found. Install: pip3 install pymobiledevice3"
        case .tunnelNotRunning:
            return "Tunnel not running. The app will attempt to start it with admin privileges."
        case .daemonFailed(let msg):
            return "Daemon error: \(msg)"
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
            logger.info("Found binary at \(c)")
            return c
        }
        // Check Python user installs
        let libDir = "\(home)/Library/Python"
        if let versions = try? fm.contentsOfDirectory(atPath: libDir) {
            for ver in versions.sorted().reversed() {
                let c = "\(libDir)/\(ver)/bin/pymobiledevice3"
                if fm.isExecutableFile(atPath: c) {
                    logger.info("Found binary at \(c)")
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
                logger.info("Found binary via which at \(path)")
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

    private func startDaemon() -> Bool {
        if daemonReady, let p = daemonProcess, p.isRunning { return true }
        stopDaemon()

        guard let python = pythonPath else {
            logger.error("Cannot start daemon — Python not found")
            return false
        }
        guard let script = daemonScriptPath else {
            logger.error("Cannot start daemon — location_daemon.py not found")
            return false
        }

        logger.info("Starting daemon: \(python) \(script)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        var args = [script, kTunnelInfoPath]
        if let udid = connectedUDIDs.first { args.append(udid) }
        process.arguments = args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() }
        catch {
            logger.error("Failed to launch daemon: \(error.localizedDescription)")
            return false
        }

        daemonProcess = process
        daemonStdin = stdinPipe.fileHandleForWriting
        daemonStdout = stdoutPipe.fileHandleForReading

        let deadline = Date().addingTimeInterval(kDaemonStartTimeout)
        while Date() < deadline {
            guard let line = readLine(timeout: 1.0) else {
                if !process.isRunning { stopDaemon(); return false }
                continue
            }
            logger.info("Daemon: \(line)")
            if line == "READY" {
                daemonReady = true
                process.terminationHandler = { [weak self] _ in
                    self?.queue.async { self?.daemonReady = false }
                }
                return true
            }
            if line.hasPrefix("ERROR") { stopDaemon(); return false }
        }
        stopDaemon()
        return false
    }

    private func stopDaemon() {
        if let stdin = daemonStdin, daemonProcess?.isRunning == true {
            stdin.write("QUIT\n".data(using: .utf8)!)
        }
        daemonProcess?.terminate()
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
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
        guard let url = URL(string: kTunneldURL) else { return false }
        let sem = DispatchSemaphore(value: 0)
        var running = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { running = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return running
    }

    /// Discover USB-connected iOS devices using pymobiledevice3 usbmux list.
    func discoverDevices() -> [DeviceInfo] {
        guard let binary = binaryPath else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--no-color", "usbmux", "list", "--usb"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch {
            logger.error("Failed to list USB devices: \(error.localizedDescription)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Fall back: try idevice_id
            return discoverDevicesViaLibimobiledevice()
        }

        var devices: [DeviceInfo] = []
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
            devices.append(DeviceInfo(id: udid, name: name ?? udid, connectionType: "USB"))
        }
        return devices
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

    /// Fallback: discover USB devices via idevice_id (libimobiledevice).
    private func discoverDevicesViaLibimobiledevice() -> [DeviceInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["idevice_id", "-l"]
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
            .map { DeviceInfo(id: $0, name: String($0.prefix(8)) + "...", connectionType: "USB") }
    }

    func ensureTunneldRunning() -> Bool {
        if isTunneldRunning() { return true }
        guard !tunneldStartAttempted else { return false }
        tunneldStartAttempted = true
        guard let binary = binaryPath else { return false }

        logger.info("Starting tunneld with admin privileges")
        let script = "do shell script \"\(binary) remote tunneld &> /dev/null & echo $!\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                for _ in 0..<10 {
                    Thread.sleep(forTimeInterval: 1.0)
                    if isTunneldRunning() { return true }
                }
            }
        } catch {}
        return false
    }

    // MARK: - Connection

    func startTunnel(forDeviceUDID udid: String) throws {
        if queue.sync(execute: { connectedUDIDs.contains(udid) && daemonReady }) { return }
        guard isAvailable() else { throw BridgeError.notInstalled }
        if !isTunneldRunning() { _ = ensureTunneldRunning() }
        let success = queue.sync { () -> Bool in
            connectedUDIDs.insert(udid)
            return startDaemon()
        }
        guard success else {
            throw BridgeError.connectionFailed("Failed to connect. Ensure tunneld is running.")
        }
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
            // Retry with daemon restart
            if startDaemon() { return sendCommand("SET \(latitude) \(longitude)") == "OK" }
            return false
        }
    }

    func clearSimulatedLocation() -> Bool {
        queue.sync {
            guard daemonReady else { return false }
            return sendCommand("CLEAR") == "OK"
        }
    }
}
