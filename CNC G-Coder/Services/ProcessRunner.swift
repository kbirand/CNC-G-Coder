import Foundation

nonisolated struct ProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let commandLine: String
}

/// Runs an external process asynchronously, accumulating merged stdout+stderr
/// while the process runs (a plain waitUntilExit + readDataToEndOfFile deadlocks
/// once output exceeds the 64 KB pipe buffer). Task cancellation sends SIGTERM.
nonisolated enum ProcessRunner {

    static func run(executable: URL, arguments: [String], currentDirectory: URL? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        let commandLine = ([executable.path] + arguments).map(shellQuote).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                        buffer.append(rest)
                    }
                    let output = String(data: buffer.data, encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(
                        exitCode: proc.terminationStatus,
                        output: output,
                        commandLine: commandLine
                    ))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Lock-protected accumulation buffer; the readability handler runs on a background queue.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
