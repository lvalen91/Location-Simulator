import Foundation
import os

// MARK: - Logging (unified log + build-independent file log under /tmp)

/// Privacy marker so existing `os.Logger`-style call sites
/// (`\(x, privacy: .public)`) keep compiling against the `Log` wrapper.
enum LogPrivacy { case `public`, `private`, auto }

/// A composed message supporting `os.Logger`-style string interpolation,
/// including the `privacy:` specifier (which the file log ignores).
struct LogMessage: ExpressibleByStringInterpolation {
    let text: String
    init(stringLiteral value: String) { self.text = value }
    init(stringInterpolation: StringInterpolation) { self.text = stringInterpolation.result }
    struct StringInterpolation: StringInterpolationProtocol {
        var result = ""
        init(literalCapacity: Int, interpolationCount: Int) { result.reserveCapacity(literalCapacity) }
        mutating func appendLiteral(_ literal: String) { result += literal }
        mutating func appendInterpolation(_ value: Any) { result += String(describing: value) }
        mutating func appendInterpolation(_ value: Any, privacy: LogPrivacy) { result += String(describing: value) }
    }
}

/// Drop-in replacement for `os.Logger` that tees to BOTH the unified log (so
/// `log stream` still works) and a timestamped file under /tmp — so logs are
/// available on any build (release included), reachable via Help ▸ Reveal Logs.
struct Log {
    let category: String
    private let osLogger: Logger
    init(category: String) {
        self.category = category
        self.osLogger = Logger(subsystem: "com.locationsimulator", category: category)
    }
    func info(_ m: LogMessage)    { osLogger.info("\(m.text, privacy: .public)");    FileLog.shared.log("INFO", category, m.text) }
    func error(_ m: LogMessage)   { osLogger.error("\(m.text, privacy: .public)");   FileLog.shared.log("ERROR", category, m.text) }
    func warning(_ m: LogMessage) { osLogger.warning("\(m.text, privacy: .public)"); FileLog.shared.log("WARN", category, m.text) }
    func debug(_ m: LogMessage)   { osLogger.debug("\(m.text, privacy: .public)");   FileLog.shared.log("DEBUG", category, m.text) }
}

/// Thread-safe append-only file logger. One timestamped file per app launch in
/// /tmp/LocationSimulator, pruned to the most recent few.
final class FileLog: @unchecked Sendable {
    static let shared = FileLog()
    static let directoryURL = URL(fileURLWithPath: "/tmp/LocationSimulator", isDirectory: true)

    let currentFileURL: URL
    private let queue = DispatchQueue(label: "com.locationsimulator.filelog")
    private var handle: FileHandle?
    private let lineFormatter: DateFormatter

    private init() {
        let fm = FileManager.default
        // Owner-only: logs hold the device UDID and spoofed coordinates, and
        // /tmp is world-readable.
        try? fm.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directoryURL.path)

        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        currentFileURL = Self.directoryURL.appendingPathComponent("app-\(nameFormatter.string(from: Date())).log")

        lineFormatter = DateFormatter()
        lineFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        fm.createFile(atPath: currentFileURL.path, contents: nil,
                      attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: currentFileURL)
        prune(keep: 10)
        log("INFO", "App", "=== Location Simulator log started (\(currentFileURL.lastPathComponent)) ===")
    }

    func log(_ level: String, _ category: String, _ message: String) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let line = "\(self.lineFormatter.string(from: Date())) [\(level)] \(category): \(message)\n"
            if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
        }
    }

    /// Keep only the most recent `keep` app logs so /tmp doesn't accumulate.
    private func prune(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directoryURL, includingPropertiesForKeys: nil) else { return }
        let logs = files.filter { $0.lastPathComponent.hasPrefix("app-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in logs.dropLast(keep) { try? fm.removeItem(at: url) }
    }
}

private let kTunnelInfoPath = "/tmp/pymobiledevice3_tunnel.txt"
private let kDaemonStartTimeout: Duration = .seconds(120)  // first-run DDI download + mount can exceed a minute
private let kTunneldURL = "http://127.0.0.1:49151/"
private let logger = Log(category: "Bridge")

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
///
/// Implemented as an `actor`: actor isolation replaces the former serial
/// `DispatchQueue` + `NSLock`s + `DispatchSemaphore`s for race-free access to
/// the daemon/connection state. Because actors are *reentrant* at every
/// `await`, the order-sensitive daemon protocol (write a command, read its one
/// reply line) is additionally guarded by an explicit single-in-flight I/O gate
/// (`lockIO`/`unlockIO`) and a single long-lived stdout line reader.
actor Pymobiledevice3Bridge {
    static let shared = Pymobiledevice3Bridge()

    // MARK: - Daemon state
    private var daemonProcess: Process?
    private var daemonStdin: FileHandle?
    private var daemonStdout: FileHandle?
    private var daemonStderr: Pipe?
    private var daemonReady = false
    private var connectedUDIDs: Set<String> = []
    private var tunneldStartAttempted = false

    // MARK: - Cached tool paths
    private var binaryPathResolved = false
    private var _binaryPath: String?
    private var pythonPathResolved = false
    private var _pythonPath: String?

    // MARK: - Daemon stdout line reader
    // A single long-lived task drains the daemon's stdout via the async byte
    // stream and hands each line to the (at most one) waiting consumer, or
    // buffers it. Never create a per-command iterator: each `.lines` iteration
    // buffers from the shared fd and would strand bytes.
    private var readerTask: Task<Void, Never>?
    private var lineBuffer: [String] = []
    private var lineWaiter: CheckedContinuation<String?, Never>?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var readerClosed = false
    // Monotonic generations so a stale/cancelled timeout or a torn-down reader
    // can never resolve or feed a *later* command's waiter.
    private var waiterGeneration = 0
    private var readerGeneration = 0

    // MARK: - I/O serialization gate (one command write+read at a time)
    private var ioBusy = false
    private var ioWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    // MARK: - Blocking work offload

    /// Run synchronous, blocking work (short-lived `Process` invocations) off
    /// the actor's executor on a GCD global queue, bridged back via a
    /// continuation. Keeps blocking subprocess/`osascript` calls from starving
    /// the cooperative thread pool.
    private nonisolated func runBlocking<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    // MARK: - I/O gate

    /// Acquire the I/O gate. Uses direct hand-off so exactly one command's
    /// write→read sequence runs at a time even across `await` suspension points.
    private func lockIO() async {
        if !ioBusy {
            ioBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioWaiters.append(cont)
        }
        // Resumed via hand-off in unlockIO(); ioBusy is already true.
    }

    private func unlockIO() {
        if !ioWaiters.isEmpty {
            let next = ioWaiters.removeFirst()
            next.resume()   // hand off; keep ioBusy == true
        } else {
            ioBusy = false
        }
    }

    // MARK: - Binary Discovery

    func isAvailable() async -> Bool { await binaryPath() != nil }

    func binaryPath() async -> String? {
        if binaryPathResolved { return _binaryPath }
        let resolved = await runBlocking { Self.resolveBinaryPath() }
        binaryPathResolved = true
        _binaryPath = resolved
        return resolved
    }

    private func pythonPath() async -> String? {
        if pythonPathResolved { return _pythonPath }
        let bin = await binaryPath()
        let resolved = await runBlocking { Self.resolvePythonPath(binaryPath: bin) }
        pythonPathResolved = true
        _pythonPath = resolved
        return resolved
    }

    private nonisolated static func resolveBinaryPath() -> String? {
        let fm = FileManager.default
        // Prefer a vendored copy bundled inside the .app (zero-install path).
        if let res = Bundle.main.resourceURL {
            let vendored = res.appendingPathComponent("vendor/pymobiledevice3").path
            if fm.isExecutableFile(atPath: vendored) {
                logger.info("Using bundled pymobiledevice3 at \(vendored, privacy: .public)")
                return vendored
            }
        }
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

    private nonisolated static func resolvePythonPath(binaryPath: String?) -> String? {
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

    // MARK: - Dependency Installation

    /// Path to the Homebrew binary, or nil if Homebrew isn't installed.
    nonisolated func homebrewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Drop the cached binary path and re-resolve. Call before a scan so a
    /// newly- or externally-installed pymobiledevice3 is picked up.
    func refreshAvailability() async -> Bool {
        binaryPathResolved = false
        _binaryPath = nil
        return await isAvailable()
    }

    /// Install pymobiledevice3 via Homebrew + pipx, streaming combined
    /// stdout/stderr lines to `progress`. Returns true if pymobiledevice3 is
    /// resolvable afterward.
    func installViaHomebrew(progress: @Sendable @escaping (String) -> Void) async -> Bool {
        guard let brew = homebrewPath() else {
            progress("Homebrew not found.")
            return false
        }
        let pipx = (brew as NSString).deletingLastPathComponent + "/pipx"
        let script = "\"\(brew)\" install pipx && \"\(pipx)\" install pymobiledevice3"
        progress("$ \(script)")
        let ok = await runStreaming(executable: "/bin/bash", arguments: ["-lc", script], progress: progress)
        binaryPathResolved = false
        _binaryPath = nil
        let available = await isAvailable()
        progress(available ? "✓ pymobiledevice3 ready." : "✗ pymobiledevice3 still not found.")
        return ok && available
    }

    /// Spawn a process, streaming combined output lines to `progress` off the
    /// actor. Resolves true on exit status 0.
    private nonisolated func runStreaming(executable: String, arguments: [String],
                                          progress: @Sendable @escaping (String) -> Void) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch {
            progress("Failed to start: \(error.localizedDescription)")
            return false
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }   // EOF
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(data: buffer[buffer.startIndex..<nl], encoding: .utf8) ?? ""
                        buffer.removeSubrange(buffer.startIndex...nl)
                        progress(line)
                    }
                }
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                    progress(line)
                }
                process.waitUntilExit()
                cont.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    // MARK: - Daemon Script

    private nonisolated static func daemonScriptPath() -> String? {
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

    /// Spawn the persistent daemon and read until it reports READY. Must be
    /// called while holding the I/O gate (callers: startTunnel stage 3, and the
    /// simulateLocation retry path, both of which lock the gate first).
    /// A bundled standalone daemon binary (frozen with pymobiledevice3), if the
    /// .app ships one. Lets the daemon run without a system Python install.
    private nonisolated static func bundledDaemonBinary() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let path = res.appendingPathComponent("vendor/location_daemon").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func startDaemon() async throws {
        if daemonReady, let p = daemonProcess, p.isRunning { return }
        stopDaemon()

        let process = Process()
        var args: [String]
        if let frozen = Self.bundledDaemonBinary() {
            // Bundled standalone daemon — no system Python or script file needed.
            process.executableURL = URL(fileURLWithPath: frozen)
            args = [kTunnelInfoPath]
            logger.info("[stage 3] startDaemon (bundled) \(frozen, privacy: .public) udid=\(String(self.connectedUDIDs.first?.prefix(8) ?? "n/a"), privacy: .public)")
        } else {
            guard let python = await pythonPath() else {
                logger.error("Cannot start daemon — Python not found")
                throw BridgeError.pythonNotFound
            }
            guard let script = Self.daemonScriptPath() else {
                logger.error("Cannot start daemon — location_daemon.py not found")
                throw BridgeError.daemonScriptMissing
            }
            process.executableURL = URL(fileURLWithPath: python)
            args = [script, kTunnelInfoPath]
            logger.info("[stage 3] startDaemon python=\(python, privacy: .public) script=\(script, privacy: .public) udid=\(String(self.connectedUDIDs.first?.prefix(8) ?? "n/a"), privacy: .public)")
        }
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

        let started = ContinuousClock.now
        do { try process.run() }
        catch {
            logger.error("Failed to launch daemon: \(error.localizedDescription, privacy: .public)")
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw BridgeError.daemonExited("spawn failed: \(error.localizedDescription)")
        }

        daemonProcess = process
        daemonStdin = stdinPipe.fileHandleForWriting
        daemonStderr = stderrPipe
        startLineReader(stdoutPipe.fileHandleForReading)

        let deadline = started.advanced(by: kDaemonStartTimeout)
        while ContinuousClock.now < deadline {
            guard let line = await readLine(timeout: .seconds(1)) else {
                if !process.isRunning {
                    logger.error("Daemon exited during startup, status=\(process.terminationStatus, privacy: .public)")
                    stopDaemon()
                    throw BridgeError.daemonExited("Process exited during startup (status \(process.terminationStatus))")
                }
                continue
            }
            logger.info("Daemon stdout: \(line, privacy: .public)")
            if line == "READY" {
                logger.info("[stage 3] READY")
                daemonReady = true
                process.terminationHandler = { [weak self] _ in
                    Task { await self?.markDaemonExited() }
                }
                return
            }
            if line.hasPrefix("ERROR") {
                let msg = String(line.dropFirst("ERROR".count))
                    .trimmingCharacters(in: .whitespaces)
                logger.error("[stage 3] daemon ERROR: \(msg, privacy: .public)")
                stopDaemon()
                throw classifyDaemonError(msg)
            }
        }
        logger.error("[stage 3] timeout waiting for READY")
        stopDaemon()
        throw BridgeError.daemonStartTimeout
    }

    private func markDaemonExited() {
        daemonReady = false
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
            try? stdin.write(contentsOf: Data("QUIT\n".utf8))
        }
        daemonStderr?.fileHandleForReading.readabilityHandler = nil
        daemonProcess?.terminate()
        readerTask?.cancel()
        readerTask = nil
        daemonProcess = nil
        daemonStdin = nil
        daemonStdout = nil
        daemonStderr = nil
        daemonReady = false
        lineBuffer.removeAll()
        readerClosed = true
        // Invalidate any in-flight reader/timeout callbacks from the daemon
        // we're tearing down so they can't touch the next daemon's waiter.
        readerGeneration &+= 1
        waiterGeneration &+= 1
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(returning: nil)
        }
    }

    private func sendCommand(_ command: String, timeout: Duration = .seconds(5)) async -> String? {
        guard let stdin = daemonStdin, daemonProcess?.isRunning == true else { return nil }
        do { try stdin.write(contentsOf: Data((command + "\n").utf8)) }
        catch { return nil }
        return await readLine(timeout: timeout)
    }

    // MARK: - Line reader

    private func startLineReader(_ handle: FileHandle) {
        daemonStdout = handle
        readerClosed = false
        lineBuffer.removeAll()
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(returning: nil)
        }
        readerTask?.cancel()
        readerGeneration &+= 1
        let generation = readerGeneration
        readerTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    if Task.isCancelled { break }
                    await self?.appendLine(line, generation: generation)
                }
            } catch {
                logger.warning("Daemon stdout reader ended: \(error.localizedDescription, privacy: .public)")
            }
            await self?.markReaderClosed(generation: generation)
        }
    }

    /// Await the next daemon line, or nil on timeout / reader closed. Exactly
    /// one consumer at a time is guaranteed by the I/O gate.
    private func readLine(timeout: Duration) async -> String? {
        if !lineBuffer.isEmpty { return lineBuffer.removeFirst() }
        if readerClosed { return nil }
        // Defensive: clear any stale waiter (should not happen under the gate).
        if let stale = lineWaiter {
            lineWaiter = nil
            stale.resume(returning: nil)
        }
        waiterGeneration &+= 1
        let generation = waiterGeneration
        let line = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            lineWaiter = cont
            // Start the timeout only after the waiter is registered, so a tiny
            // timeout cannot fire before there is anything to resolve. The
            // generation guard ensures a stale or cancelled timeout never
            // resolves a *later* command's waiter — `try?` swallows the
            // CancellationError, so this body runs even when cancelled.
            pendingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolveWaiterTimeout(generation: generation)
            }
        }
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = nil
        return line
    }

    private func resolveWaiterTimeout(generation: Int) {
        guard generation == waiterGeneration, let waiter = lineWaiter else { return }
        lineWaiter = nil
        waiter.resume(returning: nil)
    }

    private func appendLine(_ line: String, generation: Int) {
        guard generation == readerGeneration else { return }
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(returning: line)
        } else {
            lineBuffer.append(line)
        }
    }

    private func markReaderClosed(generation: Int) {
        guard generation == readerGeneration else { return }
        readerClosed = true
        if let waiter = lineWaiter {
            lineWaiter = nil
            waiter.resume(returning: nil)
        }
    }

    // MARK: - Tunneld Management

    func isTunneldRunning() async -> Bool {
        // Fast path: HTTP probe of the tunneld API.
        if let url = URL(string: kTunneldURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        // Fallback: the HTTP probe is unreliable from inside the app, so treat a
        // live `pymobiledevice3 remote tunneld` process as running. Without this,
        // a leftover tunneld (which survives app quit) is invisible here and the
        // app spawns a duplicate that fails to bind port 49151 (EADDRINUSE).
        return await runBlocking { Self.isTunneldProcessRunning() }
    }

    /// True if a `pymobiledevice3 remote tunneld` process is alive, regardless of
    /// owning user. Used as a fallback when the HTTP probe fails.
    private nonisolated static func isTunneldProcessRunning() -> Bool {
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
    func discoverDevices() async -> [DeviceInfo] {
        guard let binary = await binaryPath() else { return [] }
        return await runBlocking { Self.performDiscoverDevices(binary: binary) }
    }

    private nonisolated static func performDiscoverDevices(binary: String) -> [DeviceInfo] {
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

    /// Query device name for a UDID via idevicename (libimobiledevice).
    private nonisolated static func queryDeviceName(udid: String) -> String? {
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
    private nonisolated static func discoverDevicesViaLibimobiledevice() -> [DeviceInfo] {
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

    func ensureTunneldRunning() async -> Bool {
        if await isTunneldRunning() { return true }
        guard !tunneldStartAttempted else { return false }
        tunneldStartAttempted = true
        guard let binary = await binaryPath() else { return false }

        logger.info("ensureTunneldRunning: launching via osascript with admin privileges, binary=\(binary, privacy: .public)")
        let launched = await runBlocking { Self.launchTunneld(binary: binary) }
        guard launched else {
            logger.error("ensureTunneldRunning: osascript launch failed")
            return false
        }
        for attempt in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            if await isTunneldRunning() {
                logger.info("ensureTunneldRunning: tunneld up after \(attempt + 1, privacy: .public)s")
                return true
            }
        }
        logger.error("ensureTunneldRunning: osascript succeeded but tunneld never bound (10s elapsed)")
        return false
    }

    /// Launch tunneld as root via an osascript admin prompt. Returns true if the
    /// osascript process exited 0 (the admin prompt was accepted).
    private nonisolated static func launchTunneld(binary: String) -> Bool {
        // The bundle path contains a space ("Location Simulator.app") — without
        // quoting, sh runs /Applications/Location and the launch silently fails
        // (echo $! still makes osascript exit 0).
        let script = "do shell script \"'\(binary)' remote tunneld &> /dev/null & echo $!\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.info("launchTunneld: osascript exit=\(proc.terminationStatus, privacy: .public) stderr=\(errOutput, privacy: .public)")
            return proc.terminationStatus == 0
        } catch {
            logger.error("launchTunneld: osascript spawn failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Connection

    func startTunnel(forDeviceUDID udid: String) async throws {
        let shortUDID = String(udid.prefix(8))
        logger.info("startTunnel called for udid=\(shortUDID, privacy: .public)")
        if connectedUDIDs.contains(udid) && daemonReady {
            logger.info("startTunnel: already connected to \(shortUDID, privacy: .public), no-op")
            return
        }
        guard await isAvailable() else { throw BridgeError.notInstalled }

        // Stage 1 — make sure tunneld itself is up.
        logger.info("[stage 1] tunneld liveness check")
        if !(await isTunneldRunning()) {
            logger.warning("[stage 1] tunneld not running, attempting to start")
            if !(await ensureTunneldRunning()) {
                logger.error("[stage 1] failed (startAttempted=\(self.tunneldStartAttempted))")
                throw tunneldStartAttempted
                    ? BridgeError.tunneldStartFailed
                    : BridgeError.tunneldNotRunning
            }
        }
        logger.info("[stage 1] tunneld up")

        // Stage 2 — make sure tunneld has built a tunnel for *this* device.
        // tunneld discovery is async over mDNS; a freshly-plugged device can
        // take 10–20 seconds to appear in the registry, so we poll patiently
        // before surfacing an error to the user.
        logger.info("[stage 2] registry poll begin (timeout 20s)")
        let result = await waitForTunnelInRegistry(udid: udid, timeout: .seconds(20))
        switch result {
        case .found:
            logger.info("[stage 2] tunnel found for \(shortUDID, privacy: .public)")
        case .empty:
            logger.error("[stage 2] registry empty")
            throw BridgeError.tunneldRegistryEmpty
        case .otherDevices(let udids):
            let shortList = udids.map { String($0.prefix(8)) }.joined(separator: ",")
            logger.error("[stage 2] our udid \(shortUDID, privacy: .public) absent; present=[\(shortList, privacy: .public)]")
            throw BridgeError.noTunnelForDevice(udid: udid, availableUDIDs: udids)
        case .unreachable(let detail):
            logger.error("[stage 2] tunneld unreachable: \(detail, privacy: .public)")
            throw BridgeError.tunneldUnreachable(detail)
        }

        // Stage 3 — spin up the per-device daemon under the I/O gate. Specific
        // BridgeErrors bubble up unchanged so the UI shows the right guidance.
        await lockIO()
        defer { unlockIO() }
        connectedUDIDs.insert(udid)
        do { try await startDaemon() }
        catch {
            connectedUDIDs.remove(udid)
            throw error
        }
    }

    private enum RegistryProbe: Sendable {
        case found
        case empty
        case otherDevices([String])
        case unreachable(String)
    }

    /// Poll the tunneld registry for the given UDID. Returns as soon as the
    /// UDID appears, or after `timeout`, whichever comes first.
    private func waitForTunnelInRegistry(udid: String, timeout: Duration) async -> RegistryProbe {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastResult: RegistryProbe = .empty
        while ContinuousClock.now < deadline {
            let result = await probeTunneldRegistry(udid: udid)
            if case .found = result { return .found }
            lastResult = result
            try? await Task.sleep(for: .milliseconds(500))
        }
        return lastResult
    }

    private func probeTunneldRegistry(udid: String) async -> RegistryProbe {
        guard let url = URL(string: kTunneldURL) else {
            return .unreachable("invalid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard httpStatus == 200 else {
                logger.debug("registry probe: http=\(httpStatus, privacy: .public)")
                return .unreachable("HTTP \(httpStatus)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreachable("malformed JSON from tunneld")
            }
            if json.isEmpty { return .empty }
            if json[udid] != nil { return .found }
            return .otherDevices(Array(json.keys).sorted())
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    func stopTunnel(forDeviceUDID udid: String) async {
        await lockIO()
        defer { unlockIO() }
        connectedUDIDs.remove(udid)
        if connectedUDIDs.isEmpty { stopDaemon() }
    }

    func stopAllTunnels() async {
        await lockIO()
        defer { unlockIO() }
        stopDaemon()
        connectedUDIDs.removeAll()
    }

    // MARK: - Location Simulation

    func simulateLocation(latitude: Double, longitude: Double) async -> Bool {
        await lockIO()
        defer { unlockIO() }
        guard daemonReady else { return false }
        if await sendCommand("SET \(latitude) \(longitude)") == "OK" { return true }
        // Retry with a daemon restart. Swallow errors here — the caller only
        // cares whether the location was set; a richer error path already
        // exists via startTunnel.
        do { try await startDaemon() } catch { return false }
        return await sendCommand("SET \(latitude) \(longitude)") == "OK"
    }

    func clearSimulatedLocation() async -> Bool {
        await lockIO()
        defer { unlockIO() }
        guard daemonReady else { return false }
        return await sendCommand("CLEAR") == "OK"
    }
}
