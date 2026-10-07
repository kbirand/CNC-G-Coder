import Foundation

/// Launches the bundled FluidNC simulator (`Scripts/fake-grbl.py`, copied
/// into Contents/Resources by the "Bundle simulator" build phase) as a
/// child process on a free localhost port, so the Machine panel can be tried
/// without a controller and without a terminal.
///
/// The simulator boots with work zero at machine (11, 71, −81) and its probe
/// surface at machine Z −82 (1 mm below work Z0): with that preset the
/// sample boards pass the travel pre-flight, and a Z probe finds copper.
///
/// One instance at a time: `start` kills whatever it launched before. The
/// child is terminated on `stop`, at `exit` (an `atexit` handler) and, in
/// case the app dies without either, by the script's own `--parent-pid`
/// watchdog.
nonisolated enum SimulatorLauncherError: LocalizedError, Sendable {
    case pythonMissing
    case scriptMissing
    case launchFailed(String)
    case notListening(String)

    var errorDescription: String? {
        switch self {
        case .pythonMissing:
            "python3 is needed for the simulator — it comes with Xcode's command line tools (xcode-select --install)."
        case .scriptMissing:
            "The simulator script (fake-grbl.py) is missing from the app bundle."
        case .launchFailed(let reason):
            "The simulator could not be started: \(reason)"
        case .notListening(let reason):
            "The simulator did not come up: \(reason)"
        }
    }
}

actor SimulatorLauncher {
    nonisolated static let shared = SimulatorLauncher()

    /// Machine coordinates of the simulated work zero (`--wco`).
    nonisolated static let workZero = (x: 11.0, y: 71.0, z: -81.0)
    /// Machine Z of the simulated probe surface (`--surface`), 1 mm below work Z0.
    nonisolated static let probeSurface = -82.0
    nonisolated static let firmwareDescription = "FluidNC 3.9.9"

    private var process: Process?
    private var output = OutputCapture()
    private(set) var port: UInt16 = 0

    /// What the simulator printed so far (stdout + stderr), for the console
    /// when it fails to start.
    var logTail: String { output.text }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Starts a fresh simulator and returns the port it listens on once it
    /// accepts connections (≤ 5 s).
    func start() async throws -> UInt16 {
        stop()

        guard let python = Self.findPython() else { throw SimulatorLauncherError.pythonMissing }
        guard let script = Self.findScript() else { throw SimulatorLauncherError.scriptMissing }
        let port = try Self.freePort()

        let process = Process()
        process.executableURL = python
        process.arguments = [
            script.path,
            "--port", String(port),
            "--wco", "\(Self.number(Self.workZero.x)),\(Self.number(Self.workZero.y)),\(Self.number(Self.workZero.z))",
            "--surface", Self.number(Self.probeSurface),
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        // A clean environment: the user's PYTHON* variables must not redirect
        // the interpreter, and the script needs nothing but the stdlib.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]

        let capture = OutputCapture()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { capture.append(data) }
        }
        process.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty { capture.append(rest) }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw SimulatorLauncherError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.output = capture
        self.port = port
        Self.register(process)

        // Wait for the listening socket.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if !process.isRunning {
                let reason = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
                stop()
                throw SimulatorLauncherError.notListening(
                    reason.isEmpty ? "python3 exited with status \(process.terminationStatus)." : reason)
            }
            if Self.canConnect(port: port) { return port }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let reason = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        throw SimulatorLauncherError.notListening(reason.isEmpty ? "port \(port) never answered." : reason)
    }

    /// Terminates the simulator this launcher started (no-op when none runs).
    func stop() {
        guard let process else { return }
        Self.unregister(process)
        if process.isRunning {
            process.terminate()
            // SIGTERM is honoured within a few ms; make sure before returning.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        self.process = nil
        port = 0
    }

    // MARK: - Lookup

    nonisolated static func findPython() -> URL? {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            // /usr/bin/python3 is a shim that fails without the command line
            // tools; check that it actually runs.
            if path == "/usr/bin/python3", !Self.pythonRuns(path) { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private nonisolated static func pythonRuns(_ path: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = ["-c", "import socket, threading"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// The bundled copy, else the repository's `Scripts/fake-grbl.py` when
    /// the app runs out of DerivedData during development.
    nonisolated static func findScript() -> URL? {
        if let url = Bundle.main.url(forResource: "fake-grbl", withExtension: "py"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Scripts/fake-grbl.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let repo = dir.appendingPathComponent("CNC G-Coder/Scripts/fake-grbl.py")
            if FileManager.default.fileExists(atPath: repo.path) { return repo }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - Sockets

    /// A port the kernel hands out as free on 127.0.0.1.
    nonisolated static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SimulatorLauncherError.launchFailed("socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw SimulatorLauncherError.launchFailed("bind(): \(String(cString: strerror(errno)))") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw SimulatorLauncherError.launchFailed("getsockname(): \(String(cString: strerror(errno)))") }
        let port = UInt16(bigEndian: assigned.sin_port)
        guard port > 0 else { throw SimulatorLauncherError.launchFailed("no free port") }
        return port
    }

    nonisolated static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    private nonisolated static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Exit cleanup

    /// Processes to kill when the app exits, whichever way it exits.
    private nonisolated static let registry = ProcessRegistry()

    private nonisolated static func register(_ process: Process) {
        registry.add(process)
        registry.installExitHandlerOnce()
    }

    private nonisolated static func unregister(_ process: Process) {
        registry.remove(process)
    }

    /// Kills every simulator this app launched. Safe from any thread; used by
    /// the `atexit` handler and `applicationWillTerminate`.
    nonisolated static func terminateAll() {
        registry.terminateAll()
    }
}

/// Lock-protected set of launched processes, shared with the exit handler.
private nonisolated final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var exitHandlerInstalled = false

    func add(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes.append(process)
    }

    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        processes.removeAll { $0 === process }
    }

    func installExitHandlerOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !exitHandlerInstalled else { return }
        exitHandlerInstalled = true
        atexit { SimulatorLauncher.terminateAll() }
    }

    func terminateAll() {
        lock.lock()
        let running = processes
        processes.removeAll()
        lock.unlock()
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}

/// Lock-protected stdout/stderr accumulation; the readability handler runs
/// on a background queue.
private nonisolated final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        if storage.count > 64 * 1024 { storage.removeFirst(storage.count - 64 * 1024) }
        lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}
