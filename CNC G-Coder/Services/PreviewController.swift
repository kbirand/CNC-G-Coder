import SwiftUI
import Combine

nonisolated enum PreviewRefreshMode: String {
    case auto
    case manual
}

nonisolated enum SettingsKeys {
    static let refreshMode = "previewRefreshMode"
    static let debounceSeconds = "previewDebounceSeconds"
    static let unitSystem = "unitSystem"
    static let snapToGrid = "previewSnapToGrid"
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

    /// Where a running preview generation is, for the progress shown on the canvas.
    struct RunProgress: Equatable {
        var step: Int
        var total: Int
        var label: String
        var fraction: Double { total > 0 ? min(1, Double(step) / Double(total)) : 0 }
    }

    @Published private(set) var phase: Phase = .idle
    /// Set while a run is in progress; nil otherwise.
    @Published private(set) var progress: RunProgress?
    /// Jobs of the current run that are in flight, by id → label.
    private var running: [Int: String] = [:]
    private var finishedSteps = 0
    @Published private(set) var document: PreviewDocument?
    @Published private(set) var lastRenderedSignature: String?
    /// Signature of the most recently *scheduled* run (debounced or running).
    /// Guards against re-running for changes that don't affect the G-code.
    private var lastRequestedSignature: String?

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
        return app.parameters.signature + "||" + app.detectedFiles.signature + "||" + app.customLayers.signature
    }

    var isStale: Bool {
        document != nil && lastRenderedSignature != currentSignature
    }

    var canPreview: Bool {
        guard let app else { return false }
        let gerbers = app.projectFolder != nil && app.detectedFiles.hasAnyToolpathInput && app.pcb2gcodeURL != nil
        return gerbers || app.customLayers.hasShapes
    }

    /// Called after every parameter edit and after project-folder/file changes.
    func parametersDidChange() {
        objectWillChange.send()   // staleness badge is a computed property
        guard canPreview, refreshMode == .auto else { return }
        // Every parameter lives in UserDefaults, and so does UI state (layer
        // picker, view toggles) — a single defaults write republishes the whole
        // store, so this fires for changes that cannot alter the G-code.
        // Regenerate only when the values pcb2gcode actually consumes moved;
        // the first project selection is covered because the file signature
        // changes with it.
        let signature = currentSignature
        guard signature != lastRequestedSignature else { return }
        lastRequestedSignature = signature
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
        if let layer = app.customLayers.first(where: { !$0.isEmpty && $0.validationError != nil }) {
            phase = .failed("Custom layer \"\(layer.name)\": \(layer.validationError ?? "")")
            return
        }
        let pcb2gcode = app.pcb2gcodeURL

        let snapshot = app.parameters.snapshot()
        let files = app.detectedFiles
        let custom = app.customLayers
        let signature = currentSignature
        lastRequestedSignature = signature   // manual Refresh always regenerates

        let previous = runTask
        previous?.cancel()
        phase = .running
        runTask = Task { [weak self] in
            if let previous { await previous.value }   // single-flight
            guard !Task.isCancelled else { return }
            await self?.executePreview(pcb2gcode: pcb2gcode, snapshot: snapshot, files: files,
                                       custom: custom, signature: signature)
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

    private func executePreview(pcb2gcode: URL?, snapshot: ParameterSnapshot, files: DetectedFiles,
                                custom: [CustomLayer], signature: String) async {
        let runDir = PreviewPaths.newRunDir()
        do {
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create preview folder: \(error.localizedDescription)")
            return
        }

        // Gerber layers need pcb2gcode; drawn layers are generated in-app.
        let useBatch = files.hasAnyToolpathInput && pcb2gcode != nil
        // One more step than the batch reports: reading the programs back.
        let total = (useBatch ? Pcb2GcodeService.stepCount(snapshot, files: files) : 0)
            + (custom.hasShapes ? 1 : 0) + 1
        progress = RunProgress(step: 0, total: total, label: useBatch ? "Starting pcb2gcode" : "Custom layers")
        defer { progress = nil }
        // Unchanged layers come straight from the cache; the rest run in parallel.
        running = [:]
        finishedSteps = 0
        var batch = Pcb2GcodeService.BatchResult()
        if useBatch, let pcb2gcode {
            batch = await Pcb2GcodeService.runBatch(
                pcb2gcode: pcb2gcode, params: snapshot, files: files, outputDir: runDir,
                cache: Pcb2GcodeService.previewCache,
                onStep: { event, _ in
                    Task { @MainActor [weak self] in
                        // A late report from a cancelled run must not revive the bar.
                        guard let self, self.progress != nil else { return }
                        switch event {
                        case .started(let id, let label): self.running[id] = label
                        case .finished(let id):
                            self.running[id] = nil
                            self.finishedSteps += 1
                        }
                        let label = self.running.sorted { $0.key < $1.key }.map(\.value).joined(separator: " · ")
                        self.progress = RunProgress(step: self.finishedSteps, total: total,
                                                    label: label.isEmpty ? "Finishing" : label)
                    }
                })
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: runDir)
            return
        }
        guard batch.succeeded else {
            app?.appendLog("\n--- Preview failed ---\n" + batch.log)
            try? FileManager.default.removeItem(at: runDir)
            phase = .failed(Self.excerpt(batch.log))
            return
        }
        if custom.hasShapes {
            progress = RunProgress(step: finishedSteps, total: total, label: "Custom layers")
            // No Gerber programs: the drawing sets the origin frame itself.
            if batch.outputs.isEmpty { batch.frame = CustomLayerGenerator.frame(layers: custom, params: snapshot) }
            let frame = batch.frame
            let result = await Task.detached(priority: .userInitiated) {
                CustomLayerGenerator.write(layers: custom, params: snapshot, frame: frame, outputDir: runDir)
            }.value
            batch.outputs += result.outputs
            if result.log.contains("WARNING") || result.log.contains("ERROR") { app?.appendLog(result.log) }
            finishedSteps += 1
        }
        guard !batch.outputs.isEmpty else {
            try? FileManager.default.removeItem(at: runDir)
            phase = .failed("No programs to preview")
            return
        }

        // Parse the generated .ngc files off the main actor.
        progress = RunProgress(step: total - 1, total: total, label: "Reading toolpaths")
        let layers = await GCodeParser.parseLayers(batch.outputs)

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
            frame: batch.frame,
            mirrorAxis: Double(snapshot.mirrorAxis) ?? 0,
            mirrorYAxis: snapshot.mirrorYAxis
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

    /// Drops the current preview (new project, or no inputs left).
    func clear() {
        debounceTask?.cancel()
        runTask?.cancel()
        progress = nil
        if let temp = document?.tempDir { try? FileManager.default.removeItem(at: temp) }
        document = nil
        lastRenderedSignature = nil
        lastRequestedSignature = nil
        phase = .idle
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
