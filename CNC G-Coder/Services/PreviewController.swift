import SwiftUI
import Combine

nonisolated enum PreviewRefreshMode: String {
    case auto
    case manual
}

nonisolated enum SettingsKeys {
    static let refreshMode = "previewRefreshMode"
    static let debounceSeconds = "previewDebounceSeconds"
}

/// Temp-directory layout for preview runs.
nonisolated enum PreviewPaths {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CNCGCoderPreview", isDirectory: true)
    }

    static func newRunDir() -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func cleanRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// State machine for the live preview: debounces parameter edits, runs pcb2gcode
/// into a temp directory (single-flight), parses the outputs, and tracks staleness.
@MainActor
final class PreviewController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case debouncing
        case running
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var document: PreviewDocument?
    @Published private(set) var lastRenderedSignature: String?

    weak var app: AppModel?

    private var debounceTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?

    var refreshMode: PreviewRefreshMode {
        PreviewRefreshMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.refreshMode) ?? "auto") ?? .auto
    }

    var debounceSeconds: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.debounceSeconds)
        return v > 0 ? v : 1.0
    }

    var currentSignature: String {
        guard let app else { return "" }
        return app.parameters.signature + "||" + app.detectedFiles.signature
    }

    var isStale: Bool {
        document != nil && lastRenderedSignature != currentSignature
    }

    var canPreview: Bool {
        guard let app else { return false }
        return app.projectFolder != nil && app.detectedFiles.hasAnyToolpathInput && app.pcb2gcodeURL != nil
    }

    /// Called after every parameter edit and after project-folder/file changes.
    func parametersDidChange() {
        objectWillChange.send()   // staleness badge is a computed property
        guard canPreview, refreshMode == .auto else { return }
        phase = .debouncing
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.debounceSeconds))
            guard !Task.isCancelled else { return }
            self.refreshNow()
        }
    }

    /// Runs a preview generation now (manual Refresh button, or end of debounce).
    func refreshNow() {
        guard let app, canPreview else { return }
        debounceTask?.cancel()

        if let bad = app.parameters.validationError {
            phase = .failed("Invalid value: \(bad)")
            return
        }
        guard let pcb2gcode = app.pcb2gcodeURL else { return }

        let snapshot = app.parameters.snapshot()
        let files = app.detectedFiles
        let signature = currentSignature

        let previous = runTask
        previous?.cancel()
        phase = .running
        runTask = Task { [weak self] in
            if let previous { await previous.value }   // single-flight
            guard !Task.isCancelled else { return }
            await self?.executePreview(pcb2gcode: pcb2gcode, snapshot: snapshot, files: files, signature: signature)
        }
    }

    /// Cancels any in-flight preview batch and waits for it to end
    /// (used by final Generate so two pcb2gcode batches never overlap).
    func cancelActiveRun() async {
        debounceTask?.cancel()
        runTask?.cancel()
        await runTask?.value
        if phase == .running || phase == .debouncing {
            phase = document != nil ? .ready : .idle
        }
    }

    private func executePreview(pcb2gcode: URL, snapshot: ParameterSnapshot, files: DetectedFiles, signature: String) async {
        let runDir = PreviewPaths.newRunDir()
        do {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create preview folder: \(error.localizedDescription)")
            return
        }

        let batch = await Pcb2GcodeService.runBatch(pcb2gcode: pcb2gcode, params: snapshot, files: files, outputDir: runDir)

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: runDir)
            return
        }
        guard batch.succeeded, !batch.outputs.isEmpty else {
            app?.appendLog("\n--- Preview failed ---\n" + batch.log)
            try? FileManager.default.removeItem(at: runDir)
            phase = .failed(Self.excerpt(batch.log))
            return
        }

        // Parse the generated .ngc files off the main actor.
        let outputs = batch.outputs
        let layers = await Task.detached(priority: .userInitiated) {
            outputs.compactMap { output -> ParsedLayer? in
                guard var layer = try? GCodeParser.parse(fileURL: output.url, layer: output.layer) else { return nil }
                layer.toolDiameter = output.toolDiameter
                return layer
            }
        }.value

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: runDir)
            return
        }
        guard !layers.isEmpty else {
            try? FileManager.default.removeItem(at: runDir)
            phase = .failed("No toolpaths could be parsed")
            return
        }

        var bounds = CGRect.null
        for layer in layers {
            if let b = layer.cutBounds ?? layer.allBounds { bounds = bounds.union(b) }
        }

        let previousTemp = document?.tempDir
        document = PreviewDocument(
            layers: layers.sorted { $0.id < $1.id },
            bounds: bounds.isNull ? .zero : bounds,
            tempDir: runDir,
            token: UUID(),
            projectSize: batch.projectSize
        )
        lastRenderedSignature = signature
        phase = .ready

        let summary = document!.layers
            .map { "\($0.displayName): \($0.moves.count) moves" }
            .joined(separator: ", ")
        app?.appendLog("Preview updated (\(summary))\n")

        if let previousTemp {
            try? FileManager.default.removeItem(at: previousTemp)
        }
    }

    /// Shows an externally generated G-code file (e.g. the parameter test
    /// board) in the preview, replacing the current document. The next
    /// project refresh regenerates the normal preview.
    func loadExternal(url: URL, toolDiameter: Double?) {
        Task { [weak self] in
            let layer = await Task.detached(priority: .userInitiated) { () -> ParsedLayer? in
                guard var parsed = try? GCodeParser.parse(fileURL: url, layer: .test) else { return nil }
                parsed.toolDiameter = toolDiameter
                return parsed
            }.value
            guard let self else { return }
            guard let layer, let bounds = layer.cutBounds ?? layer.allBounds else {
                self.phase = .failed("Could not parse the test board G-code")
                return
            }
            // Own empty temp dir so document-swap cleanup never touches user files.
            let dir = PreviewPaths.newRunDir()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let previousTemp = self.document?.tempDir
            self.document = PreviewDocument(layers: [layer], bounds: bounds, tempDir: dir, token: UUID())
            self.lastRenderedSignature = nil   // project preview is stale while showing the test board
            self.phase = .ready
            if let previousTemp { try? FileManager.default.removeItem(at: previousTemp) }
        }
    }

    private nonisolated static func excerpt(_ log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init)
        if let errorLine = lines.last(where: { $0.localizedCaseInsensitiveContains("error") }) {
            return String(errorLine.prefix(200))
        }
        return String((lines.last ?? "pcb2gcode failed").prefix(200))
    }
}
