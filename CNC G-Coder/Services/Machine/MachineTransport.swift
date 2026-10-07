import Foundation
import Network
import Darwin
import AppKit   // NSWorkspace.willSleepNotification only

/// How the app reaches the controller: FluidNC's telnet service over Wi‑Fi,
/// the USB-UART of the ESP32 board, or the built-in simulator
/// (`SimulatorLauncher`, a `TCPTransport` to a localhost port).
nonisolated enum TransportKind: String, Codable, Sendable, CaseIterable {
    case tcp
    case serial
    case simulator

    var title: String {
        switch self {
        case .tcp: "Wi‑Fi"
        case .serial: "USB serial"
        case .simulator: "Simulator"
        }
    }
}

nonisolated enum MachineTransportError: LocalizedError, Sendable {
    case connectionFailed(String)
    case notConnected
    case openFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): reason
        case .notConnected: "Not connected to the controller."
        case .openFailed(let reason): reason
        case .writeFailed(let reason): "Write failed: \(reason)"
        }
    }
}

/// A byte link to a GRBL/FluidNC controller. One instance is one session:
/// `open()` once, `close()` once; after that `lines` has finished and a new
/// transport is created for the next connection.
///
/// Lines arrive trimmed, with empty lines dropped, so `ok`, `<Idle|…>`,
/// `[MSG:…]` and banners come through exactly as the firmware printed them
/// whether it terminated them with `\n` or `\r\n`. Real-time bytes (`?`,
/// `!`, `0x85`…) go out through `send(byte:)` with no terminator.
nonisolated protocol MachineTransport: Actor {
    nonisolated var kind: TransportKind { get }
    /// "192.168.1.39:23" / "/dev/cu.usbserial-1420 @115200"
    nonisolated var endpointDescription: String { get }
    /// Complete lines, trimmed, empty lines dropped. Finishes on close or failure.
    nonisolated var lines: AsyncStream<String> { get }
    func open() async throws
    func close()
    func send(data: Data) async throws
    /// Sends a text line, appending the newline GRBL expects.
    func send(line: String) async throws
    /// Sends a single real-time byte with no line terminator.
    func send(byte: UInt8) async throws
    /// Non-fatal notes gathered while opening (serial ioctl failures), cleared on return.
    func takeWarnings() -> [String]
}

extension MachineTransport {
    func send(line: String) async throws {
        try await send(data: Data((line + "\n").utf8))
    }

    func send(byte: UInt8) async throws {
        try await send(data: Data([byte]))
    }
}

/// Splits an inbound byte stream into `\n`-terminated lines, keeping any
/// partial tail for the next chunk. Shared by both transports so a serial
/// session and a telnet session hand the controller identical lines.
nonisolated struct LineSplitter: Sendable {
    private var buffer = Data()

    /// Appends a chunk and returns every complete line it finished, trimmed,
    /// empty lines dropped.
    mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard let text = String(data: lineData, encoding: .utf8) else { continue }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

// MARK: - TCP (FluidNC telnet, port 23)

/// A single TCP session to the controller, ported from the pendant's
/// `GRBLConnection`. Differences: a `.waiting` state (no route yet, refused,
/// or the macOS 15+ Local Network consent sheet still up on the first
/// connect) keeps waiting until the 5 s timeout instead of failing at once,
/// and a failed write closes the session so the caller sees a dead link as
/// disconnected rather than as a socket that silently eats commands.
actor TCPTransport: MachineTransport {
    nonisolated let kind: TransportKind = .tcp
    nonisolated let endpointDescription: String
    nonisolated let lines: AsyncStream<String>

    /// Seconds before an unanswered connect gives up (also the TCP handshake timeout).
    static let connectionTimeout: TimeInterval = 5

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "CNCGCoder.TCPTransport")
    private let lineContinuation: AsyncStream<String>.Continuation
    private var splitter = LineSplitter()

    private enum Phase { case idle, opening, open, closed }
    private var phase: Phase = .idle
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// The last reason the connection reported while `.waiting`; becomes the
    /// error text when the timeout expires in that state.
    private var waitingReason: String?
    private var warnings: [String] = []

    init(host: String, port: UInt16) {
        endpointDescription = "\(host):\(port)"

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(Self.connectionTimeout)
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 23,
                                  using: parameters)

        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        lineContinuation = continuation
    }

    /// Opens the socket and returns once it is ready, or throws if it cannot
    /// connect within `connectionTimeout`.
    func open() async throws {
        switch phase {
        case .open, .opening: return
        case .closed: throw MachineTransportError.connectionFailed("The connection was closed; open a new one.")
        case .idle: break
        }
        phase = .opening

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleState(state) }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.connectionTimeout))
                guard !Task.isCancelled else { return }
                await self?.connectTimedOut()
            }
            connection.start(queue: queue)
        }

        startReceiving()
    }

    /// Closes the socket and finishes `lines`. Safe to call more than once.
    func close() {
        guard phase != .closed else { return }
        phase = .closed
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.cancel()
        lineContinuation.finish()
    }

    func send(data: Data) async throws {
        guard phase == .open else { throw MachineTransportError.notConnected }
        let failure: NWError? = await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error)
            })
        }
        if let failure {
            close()
            throw MachineTransportError.writeFailed(failure.localizedDescription)
        }
    }

    func takeWarnings() -> [String] {
        defer { warnings.removeAll() }
        return warnings
    }

    // MARK: Internals

    private func finishOpen(_ result: Result<Void, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            if phase == .opening { phase = .open }
            finishOpen(.success(()))
        case .failed(let error):
            finishOpen(.failure(MachineTransportError.connectionFailed(error.localizedDescription)))
            close()
        case .waiting(let error):
            // Unreachable host, refused port, or the Local Network consent
            // sheet: Network keeps retrying, and so do we until the timeout.
            waitingReason = error.localizedDescription
        case .cancelled:
            finishOpen(.failure(MachineTransportError.notConnected))
            close()
        default:
            break
        }
    }

    private func connectTimedOut() {
        guard readyContinuation != nil else { return }
        let reason = waitingReason.map { "Could not connect to \(endpointDescription): \($0)" }
            ?? "Could not connect to \(endpointDescription): timed out after \(Int(Self.connectionTimeout)) s."
        finishOpen(.failure(MachineTransportError.connectionFailed(reason)))
        close()
    }

    private func startReceiving() {
        guard phase == .open else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            for line in splitter.append(data) {
                lineContinuation.yield(line)
            }
        }
        if isComplete || error != nil {
            close()
            return
        }
        startReceiving()
    }
}

// MARK: - USB serial

/// A POSIX/termios session on a `/dev/cu.*` port. The port is configured raw
/// at `baud`, 8N1, no flow control, and — the part that matters for an ESP32
/// board — with `HUPCL` cleared and DTR/RTS asserted together in one ioctl:
/// the auto-reset circuit pulls EN low only when the two lines differ, so
/// neither opening nor closing the port reboots the controller (which would
/// drop its Wi‑Fi clients and lose the machine position).
///
/// Reads come from a `DispatchSourceRead` on a private queue, where the
/// bytes are split into lines in order and yielded to `lines`; writes run on
/// a second queue so a blocking `write(2)` stalls neither the actor nor the
/// reader (a write that waits for the peer to drain while the peer waits for
/// us to read would otherwise deadlock). The port is closed when the Mac is
/// about to sleep: a USB-UART that goes away while open leaves the file
/// descriptor in a state that hangs the next read.
actor SerialTransport: MachineTransport {
    nonisolated let kind: TransportKind = .serial
    nonisolated let endpointDescription: String
    nonisolated let lines: AsyncStream<String>

    let path: String
    let baud: Int

    private let readQueue = DispatchQueue(label: "CNCGCoder.SerialTransport.read")
    private let writeQueue = DispatchQueue(label: "CNCGCoder.SerialTransport.write")
    private let lineContinuation: AsyncStream<String>.Continuation
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var sleepWatcher: Task<Void, Never>?

    private enum Phase { case idle, open, closed }
    private var phase: Phase = .idle
    private var warnings: [String] = []

    init(path: String, baud: Int = 115200) {
        self.path = path
        self.baud = baud
        endpointDescription = "\(path) @\(baud)"

        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        lineContinuation = continuation
    }

    func open() async throws {
        switch phase {
        case .open: return
        case .closed: throw MachineTransportError.openFailed("The port was closed; open a new one.")
        case .idle: break
        }

        let descriptor = try openDescriptor()
        do {
            try configure(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        fd = descriptor
        phase = .open
        startReading(descriptor)
        startSleepWatcher()
    }

    /// Closes the port and finishes `lines`. Safe to call more than once.
    /// DTR/RTS stay asserted (no `HUPCL`), so the ESP32 keeps running.
    func close() {
        guard phase != .closed else { return }
        phase = .closed
        sleepWatcher?.cancel()
        sleepWatcher = nil
        if let source {
            // The cancel handler closes the descriptor once the read source
            // has let go of it, behind any write still queued (see startReading).
            source.cancel()
            self.source = nil
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        fd = -1
        lineContinuation.finish()
    }

    func send(data: Data) async throws {
        guard phase == .open, fd >= 0 else { throw MachineTransportError.notConnected }
        let descriptor = fd
        let failure: String? = await withCheckedContinuation { continuation in
            writeQueue.async {
                continuation.resume(returning: Self.writeAll(data, to: descriptor))
            }
        }
        if let failure {
            close()
            throw MachineTransportError.writeFailed(failure)
        }
    }

    func takeWarnings() -> [String] {
        defer { warnings.removeAll() }
        return warnings
    }

    // MARK: Opening

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    /// Opens the device. `O_EXLOCK` keeps Candle/UGS from opening the same
    /// port underneath us; a driver that cannot lock gets a warning, not a
    /// failure, while a port that *is* locked by someone else is reported as
    /// in use. `O_NONBLOCK` only so the open itself cannot hang on a modem
    /// line; it is cleared again once the port is ours.
    private func openDescriptor() throws -> Int32 {
        let baseFlags = O_RDWR | O_NOCTTY | O_NONBLOCK
        var descriptor = Darwin.open(path, baseFlags | O_EXLOCK)
        if descriptor < 0 {
            let lockError = errno
            if lockError == EAGAIN || lockError == EWOULDBLOCK {
                throw MachineTransportError.openFailed("\(path) is in use by another application.")
            }
            descriptor = Darwin.open(path, baseFlags)
            if descriptor < 0 {
                throw MachineTransportError.openFailed("Could not open \(path): \(Self.errnoText()).")
            }
            warnings.append("Exclusive lock (O_EXLOCK) unavailable on \(path): \(String(cString: strerror(lockError))).")
        }
        // Second line of defence: no other process may open the port while we hold it.
        if ioctl(descriptor, UInt(TIOCEXCL)) < 0 {
            warnings.append("TIOCEXCL failed on \(path): \(Self.errnoText()).")
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags < 0 || fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) < 0 {
            let text = Self.errnoText()
            Darwin.close(descriptor)
            throw MachineTransportError.openFailed("Could not configure \(path): \(text).")
        }
        return descriptor
    }

    private func configure(_ descriptor: Int32) throws {
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else {
            throw MachineTransportError.openFailed("\(path) is not a serial port: \(Self.errnoText()).")
        }
        cfmakeraw(&attributes)
        // 8N1, receiver on, ignore modem control lines, no hardware flow
        // control (the UART bridge has no CTS wired), and keep DTR/RTS on
        // close so the ESP32 is not reset.
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attributes.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS | PARENB | CSTOPB)
        // A read returns as soon as one byte is in, or 0.2 s after the last.
        withUnsafeMutableBytes(of: &attributes.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 2
        }
        let speed = speed_t(baud)
        let standardSpeed = cfsetspeed(&attributes, speed) == 0
        guard tcsetattr(descriptor, TCSANOW, &attributes) == 0 else {
            throw MachineTransportError.openFailed("Could not set up \(path): \(Self.errnoText()).")
        }
        if !standardSpeed {
            // Non-POSIX rates (250000, 921600…) go through IOKit's
            // IOSSIOSPEED = _IOW('T', 2, speed_t) from <IOKit/serial/ioss.h>,
            // which is not importable here (it is a macro over a 64-bit speed_t).
            var rate = speed
            let IOSSIOSPEED: UInt = 0x8008_5402
            guard ioctl(descriptor, IOSSIOSPEED, &rate) == 0 else {
                throw MachineTransportError.openFailed("\(baud) baud is not supported by \(path).")
            }
        }
        tcflush(descriptor, TCIOFLUSH)

        // DTR and RTS asserted in one go. Both high = EN stays high on the
        // ESP32 auto-reset circuit; setting them one at a time would pass
        // through the (DTR, !RTS) combination that resets the board.
        var modemBits: Int32 = TIOCM_DTR | TIOCM_RTS
        if ioctl(descriptor, UInt(TIOCMSET), &modemBits) < 0 {
            warnings.append("Could not assert DTR/RTS on \(path) (TIOCMSET): \(Self.errnoText()).")
        }
    }

    // MARK: Reading

    /// Owned by `readQueue`: the splitter must stay in arrival order, which a
    /// hop into the actor per chunk would not guarantee.
    private final class ReadState: @unchecked Sendable {
        var splitter = LineSplitter()
        var buffer = [UInt8](repeating: 0, count: 4096)
    }

    private func startReading(_ descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        let state = ReadState()
        let continuation = lineContinuation
        source.setEventHandler { [weak self] in
            let count = state.buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                for line in state.splitter.append(Data(state.buffer[0..<count])) {
                    continuation.yield(line)
                }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // Hang-up or an unplugged adapter: the session is over.
                Task { [weak self] in await self?.close() }
            }
        }
        source.setCancelHandler { [writeQueue] in
            // Behind the writes already queued, so none of them can land on
            // a descriptor number the kernel has since handed to another file.
            writeQueue.async { Darwin.close(descriptor) }
        }
        self.source = source
        source.activate()
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> String? {
        var offset = 0
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
            guard let base = bytes.baseAddress else { return nil }
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return errnoText()
                }
                offset += written
            }
            return nil
        }
    }

    // MARK: Sleep

    private func startSleepWatcher() {
        sleepWatcher = Task { [weak self] in
            let center = await MainActor.run { NSWorkspace.shared.notificationCenter }
            for await _ in center.notifications(named: NSWorkspace.willSleepNotification) {
                guard !Task.isCancelled else { return }
                await self?.close()
            }
        }
    }
}
