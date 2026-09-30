import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Root application model: project folder, detected files, log, generation.
@MainActor
final class AppModel: ObservableObject {

    let parameters = ParametersStore()
    let tools = ToolLibrary()
    let preview = PreviewController()
    /// Playback/selection state is app-wide: the layer picker lives in the left
    /// panel (it also decides which settings are shown) while the transport bar
    /// and canvases live in the preview pane.
    let player = PlaybackState()

    @Published var projectFolder: URL?
    @Published var detectedFiles = DetectedFiles() {
        didSet {
            guard detectedFiles != oldValue else { return }
            drillHoleSizes = Dictionary(uniqueKeysWithValues: detectedFiles.drills.map { ($0, ExcellonReader.holeSizes(in: $0)) })
        }
    }
    /// Hole diameters (mm) declared by each detected drill file.
    @Published private(set) var drillHoleSizes: [URL: [Double]] = [:]
    @Published var log = "Ready.\n"
    @Published var isGenerating = false
    @Published var showTestBoardDialog = false
    @Published var showGenerateDialog = false
    @Published var isExportingArtwork = false

    /// One reported stage of a generation run, for the Generate sheet.
    struct GenerationStep: Identifiable, Equatable {
        let id: Int
        var label: String
        var isDone = false
    }
    @Published private(set) var generationSteps: [GenerationStep] = []
    @Published private(set) var generationTotal = 0
    /// Set when a run ends: the summary line the sheet shows.
    @Published private(set) var generationSummary: String?
    @Published private(set) var generationFailed = false
    /// Output folder the user picked at Generate time (remembered for this
    /// session, cleared when the project changes).
    @Published var chosenOutputDir: URL?

    // MARK: Project file (see AppModel+Project.swift)

    /// The .cncproj this session was opened from or saved to; nil = untitled.
    @Published var projectURL: URL?
    /// Project state at the last open/save, for the "Edited" mark.
    @Published var savedProjectState: String?
    @Published var recentProjects: [URL] = []
    /// Files picked with Import Layer…, waiting for their roles to be confirmed.
    @Published var pendingImports: [PendingImport] = []
    /// An untitled project whose layers were imported, replaced or removed by
    /// hand — the only untitled state worth asking about before discarding.
    @Published var manualLayerEdits = false
    /// Unpacked project files → the file each was originally packed from.
    var layerOrigins: [URL: URL] = [:]

    /// The app's one model, for AppKit callbacks outside SwiftUI (quit).
    static weak var current: AppModel?

    let pcb2gcodeURL = ToolLocator.pcb2gcode
    let gerbvURL = ToolLocator.gerbv

    private var cancellables = Set<AnyCancellable>()
    private var generateTask: Task<Void, Never>?

    /// The user's chosen output folder, falling back to the suggested default
    /// (used for Copy Command before the first Generate).
    var outputDir: URL? {
        chosenOutputDir ?? projectFolder?.appendingPathComponent("Generated_GCode", isDirectory: true)
    }

    init() {
        Self.current = self
        preview.app = self
        player.preview = preview
        parameters.library = tools
        // objectWillChange fires before the new value lands; defer one runloop
        // turn so the preview controller reads the updated signature.
        parameters.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.preview.parametersDidChange() }
            }
            .store(in: &cancellables)
        // Drill bits on hand resolve through the library: editing one must
        // regenerate like any parameter edit (the signature includes them).
        tools.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.preview.parametersDidChange() }
            }
            .store(in: &cancellables)
        loadRecentProjects()
        Task { await startup() }
    }

    func appendLog(_ text: String) {
        log += text
    }

    private func startup() async {
        PreviewPaths.cleanRoot()
        try? FileManager.default.removeItem(at: ProjectDocument.workingRoot)
        guard let pcb2gcodeURL else {
            appendLog("WARNING: pcb2gcode not found. Install with: brew install pcb2gcode\n")
            return
        }
        if let r = try? await ProcessRunner.run(executable: pcb2gcodeURL, arguments: ["--version"]) {
            let version = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog("Found \(version) at \(pcb2gcodeURL.path)\n")
        }
        if gerbvURL == nil {
            appendLog("Note: gerbv not found (only needed for solder-mask SVGs). Install with: brew install gerbv\n")
        }
        // Dev hooks: `-debugProjectFolder /path/to/gerbers` skips the open panel;
        // adding `-debugGenerate 1` (or `-debugGenerateLaser 1`) also runs that
        // generation straight into a folder beside the project, no panel.
        if let debugFolder = UserDefaults.standard.string(forKey: "debugProjectFolder") {
            selectProjectFolder(URL(fileURLWithPath: debugFolder, isDirectory: true))
            // `-debugGenerateDialog 1` opens the Generate sheet at launch.
            if UserDefaults.standard.bool(forKey: "debugGenerateDialog") { showGenerateDialog = true }
            let target: GenerateTarget? = UserDefaults.standard.bool(forKey: "debugGenerate") ? .cnc
                : (UserDefaults.standard.bool(forKey: "debugGenerateLaser") ? .laser : nil)
            // `-debugSaveProject /path/x.cncproj` saves it straight away.
            if let path = UserDefaults.standard.string(forKey: "debugSaveProject") {
                saveProject(to: URL(fileURLWithPath: path))
            }
            if let target, let projectFolder {
                startGeneration(target: target,
                                destination: projectFolder.appendingPathComponent(target.folderName, isDirectory: true))
            }
        }
        // Dev hook: `-debugImport /a.gbr,/b.drl` shows the Import Layers sheet for those files.
        if let list = UserDefaults.standard.string(forKey: "debugImport") {
            pendingImports = list.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                .map { PendingImport(url: $0, slot: GerberDetector.guessSlot(for: $0)) }
        }
        // Dev hook: `-debugRefreshAfter 12` regenerates the preview after that
        // many seconds (to watch an update over an existing preview); with
        // `-debugEdit key=value` it edits that parameter instead, as a user would.
        let refreshDelay = UserDefaults.standard.double(forKey: "debugRefreshAfter")
        if refreshDelay > 0 {
            let edit = UserDefaults.standard.string(forKey: "debugEdit")?.split(separator: "=", maxSplits: 1).map(String.init)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(refreshDelay))
                guard let self else { return }
                if let edit, edit.count == 2 {
                    self.appendLog("\n[debug] edit \(edit[0]) = \(edit[1])\n")
                    self.parameters.apply([edit[0]: edit[1]])
                } else {
                    self.preview.refreshNow()
                }
            }
        }
        // Dev hook: `-debugOpenProject /path/x.cncproj` opens a saved project.
        if let path = UserDefaults.standard.string(forKey: "debugOpenProject") {
            openProject(at: URL(fileURLWithPath: path), confirmed: true)
        }
        // Dev hook: `-debugTestBoard /path/out.ngc` generates a default test
        // board there and shows it in the preview.
        if let testPath = UserDefaults.standard.string(forKey: "debugTestBoard") {
            let spec = TestBoardGenerator.Spec(
                width: 60, height: 45, rows: 4, cols: 5,
                depthFrom: -0.04, depthTo: -0.12,
                feedFrom: 120, feedTo: 360, tool: 0.1, isolationWidth: 0.2,
                spindle: "12000", zsafe: 3, plungeFeed: 60
            )
            if let result = TestBoardGenerator.generate(spec) {
                let url = URL(fileURLWithPath: testPath)
                try? result.gcode.write(to: url, atomically: true, encoding: .utf8)
                appendLog("\n[debug] test board written to \(testPath)\n")
                preview.loadExternal(url: url, toolDiameter: spec.tool)
            }
        }
    }

    // MARK: - Project folder

    func chooseProjectFolder() {
        openGerberFolder()
    }

    func selectProjectFolder(_ url: URL) {
        projectFolder = url
        chosenOutputDir = nil   // a new project must never inherit the old destination
        manualLayerEdits = false
        layerOrigins = [:]
        detectedFiles = GerberDetector.detect(in: url)

        appendLog("\nSelected project folder: \(url.path)\n")
        appendLog("Auto-detected:\n")
        appendLog("Top: \(detectedFiles.front?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Bottom: \(detectedFiles.back?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Outline: \(detectedFiles.outline?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Top mask: \(detectedFiles.topMask?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Bottom mask: \(detectedFiles.bottomMask?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Top silkscreen: \(detectedFiles.topSilk?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Bottom silkscreen: \(detectedFiles.bottomSilk?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Drills: \(detectedFiles.drills.count)\n")

        preview.parametersDidChange()
    }

    // MARK: - Final generation

    /// What a generation run produces.
    enum GenerateTarget: String, CaseIterable, Identifiable, Sendable {
        case cnc, laser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cnc: "CNC G-code"
            case .laser: "Laser artwork"
            }
        }
        var icon: String {
            switch self {
            case .cnc: "hammer.fill"
            case .laser: "rays"
            }
        }
        /// Folder name suggested next to the project.
        var folderName: String {
            switch self {
            case .cnc: "Generated_GCode"
            case .laser: "Laser_Artwork"
            }
        }
    }

    /// Why a run cannot start, or nil when it can.
    func generationBlocker(for target: GenerateTarget) -> String? {
        if pcb2gcodeURL == nil { return "pcb2gcode not found — install it with: brew install pcb2gcode" }
        if projectFolder == nil { return "Choose a project folder first." }
        if !detectedFiles.hasAnything { return "No Gerber files were recognized in this project." }
        if let bad = parameters.validationError { return "Invalid value in \"\(bad)\" — fix it before generating." }
        return nil
    }

    /// Runs a generation into `destination`. Both targets share the same
    /// pcb2gcode batch; only what is written at the end differs.
    func startGeneration(target: GenerateTarget, destination: URL) {
        guard !isGenerating, let pcb2gcodeURL else { return }
        if let blocker = generationBlocker(for: target) {
            appendLog("\nERROR: \(blocker)\n")
            return
        }

        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        chosenOutputDir = destination
        isGenerating = true
        generationSteps = []
        generationSummary = nil
        generationFailed = false
        generationTotal = Pcb2GcodeService.stepCount(parameters.snapshot(), files: detectedFiles)
            + (target == .laser ? 1 : 0)   // plus the rendering pass
        appendLog("\n--- \(target == .cnc ? "Generating" : "Exporting laser artwork") into \(destination.path) ---\n")

        let snapshot = parameters.snapshot()
        let files = detectedFiles
        let gerbv = gerbvURL
        let options = ArtworkExport.Options.current

        generateTask = Task { [weak self] in
            guard let self else { return }
            await self.preview.cancelActiveRun()   // never two pcb2gcode batches at once

            // The laser target generates into a temp folder and writes only
            // the rendered artwork; the CNC target keeps the .ngc files.
            let workDir = target == .cnc ? destination : PreviewPaths.newRunDir()
            if target == .laser {
                do {
                    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                } catch {
                    self.finishGeneration(summary: "Could not create the working folder: \(error.localizedDescription)", failed: true)
                    return
                }
            }
            defer { if target == .laser { try? FileManager.default.removeItem(at: workDir) } }

            let batch = await Pcb2GcodeService.runBatch(
                pcb2gcode: pcb2gcodeURL, params: snapshot, files: files, outputDir: workDir,
                onStep: { event, total in
                    Task { @MainActor [weak self] in self?.reportStep(event, total: total) }
                })
            self.appendLog(batch.log)

            if Task.isCancelled {
                self.finishGeneration(summary: "Cancelled.", failed: true)
                return
            }
            guard batch.succeeded, !batch.outputs.isEmpty else {
                self.finishGeneration(summary: "pcb2gcode produced no programs — see the Log.", failed: true)
                return
            }

            switch target {
            case .cnc:
                if snapshot.maskMode == "svg", files.topMask != nil || files.bottomMask != nil {
                    if let gerbv {
                        let maskResult = await Pcb2GcodeService.exportMaskSVGs(gerbv: gerbv, files: files, outputDir: destination)
                        self.appendLog(maskResult.log)
                    } else {
                        self.appendLog("WARNING: gerbv not found; solder-mask SVGs were not generated.\nInstall it with: brew install gerbv\n")
                    }
                }
                let count = batch.outputs.count
                self.finishGeneration(summary: "\(count) program\(count == 1 ? "" : "s") written.", failed: false)

            case .laser:
                self.reportStep(.started(id: self.generationTotal, label: "Rendering \(options.format.title) artwork"),
                                total: self.generationTotal)
                let layers = await GCodeParser.parseLayers(batch.outputs)
                var bounds = CGRect.null
                for layer in layers {
                    if let b = layer.cutBounds ?? layer.allBounds { bounds = bounds.union(b) }
                }
                let document = PreviewDocument(
                    layers: layers.sorted { $0.id < $1.id },
                    bounds: bounds.isNull ? .zero : bounds,
                    tempDir: workDir,
                    token: UUID(),
                    frame: batch.frame,
                    mirrorAxis: Double(snapshot.mirrorAxis) ?? 0,
                    mirrorYAxis: snapshot.mirrorYAxis
                )
                var written = 0
                for layer in document.layers {
                    if ArtworkExport.wouldBeBlank(layer: layer, document: document, options: options) {
                        self.appendLog("Skipped \(layer.displayName): none of it falls inside the \(options.frameMode.title) frame.\n")
                        continue
                    }
                    let name = ArtworkExport.suggestedFilename(layer: layer.id, options: options)
                    let result = ArtworkExport.export(layer: layer, document: document, options: options,
                                                      output: destination.appendingPathComponent(name))
                    self.appendLog(result.log)
                    if result.succeeded { written += 1 }
                }
                self.finishGeneration(
                    summary: "\(written) \(options.format.title) file\(written == 1 ? "" : "s") written.",
                    failed: written == 0)
            }
        }
    }

    func cancelGeneration() {
        generateTask?.cancel()
    }

    /// Jobs run in parallel: each appears when it starts and is ticked off
    /// when it finishes, in whatever order that happens.
    private func reportStep(_ event: Pcb2GcodeService.StepEvent, total: Int) {
        generationTotal = max(generationTotal, total)
        switch event {
        case .started(let id, let label):
            generationSteps.append(GenerationStep(id: id, label: label))
        case .finished(let id):
            if let i = generationSteps.firstIndex(where: { $0.id == id }) { generationSteps[i].isDone = true }
        }
    }

    private func finishGeneration(summary: String, failed: Bool) {
        for i in generationSteps.indices { generationSteps[i].isDone = true }
        generationSummary = summary
        generationFailed = failed
        isGenerating = false
        appendLog("\n\(summary)\n")
    }

    // MARK: - Program export (CNC, per layer)

    /// Saves one layer's program exactly as the preview shows it — the same
    /// pcb2gcode run, post-processing and origin as Generate would write.
    func exportProgram(layer: LayerKind) {
        guard let document = preview.document,
              let parsed = document.layers.first(where: { $0.id == layer }) else {
            appendLog("\nERROR: \(layer.displayName) is not in the current preview; refresh first.\n")
            return
        }
        guard !preview.isStale else {
            appendLog("\nERROR: the preview is out of date — refresh it before exporting \(layer.displayName).\n")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = layer.fileSlug + ".ngc"
        panel.allowedContentTypes = [UTType(filenameExtension: "ngc") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.directoryURL = chosenOutputDir ?? projectFolder
        panel.message = "Save the \(layer.displayName) program for the CNC."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.copyItem(at: parsed.fileURL, to: url)
            appendLog("\nExported \(layer.displayName) → \(url.path)\n")
        } catch {
            appendLog("\nERROR exporting \(layer.displayName): \(error.localizedDescription)\n")
        }
    }

    // MARK: - Layer artwork export (laser)

    /// Exports one layer's TOOLPATH — the geometry the preview draws, swept at
    /// the cutter diameter — for a laser engraver. The generated G-code is
    /// untouched; this is the same program rendered as artwork.
    func exportArtwork(layer: LayerKind, options: ArtworkExport.Options) {
        guard !isExportingArtwork else { return }
        guard let document = preview.document,
              let parsed = document.layers.first(where: { $0.id == layer }) else {
            appendLog("\nERROR: \(layer.displayName) is not in the current preview; refresh first.\n")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtworkExport.suggestedFilename(layer: layer, options: options)
        panel.allowedContentTypes = [options.format.contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = chosenOutputDir ?? projectFolder
        panel.message = "Export the \(layer.displayName) toolpath at 1:1 scale for a laser engraver."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingArtwork = true
        appendLog("\n--- Exporting \(layer.displayName) as \(options.format.title) ---\n")

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ArtworkExport.export(layer: parsed, document: document, options: options, output: url)
            }.value
            guard let self else { return }
            self.appendLog(result.log)
            if !result.succeeded { self.appendLog("Export failed.\n") }
            self.isExportingArtwork = false
        }
    }

    // MARK: - Small actions

    func openOutputFolder() {
        guard let outputDir, FileManager.default.fileExists(atPath: outputDir.path) else { return }
        NSWorkspace.shared.open(outputDir)
    }

    func copyCommand() {
        guard let outputDir else { return }
        let command = Pcb2GcodeService.previewCommand(
            pcb2gcode: pcb2gcodeURL,
            params: parameters.snapshot(),
            files: detectedFiles,
            outputDir: outputDir
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
