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
    /// The shape editor for hand-drawn (custom) layers.
    let editor = ShapeEditor()
    /// Edits imported Gerber and drill files (track widths, pad and hole sizes).
    let layerEditor = LayerFileEditor()
    /// The app's undo history: parameter edits, layer-file changes and
    /// drawing edits, in the order they were made. Owned here rather than
    /// taken from the window — SwiftUI does not hand this window's undo
    /// manager to the model — and driven by Edit → Undo / Redo.
    let history = UndoManager()

    @Published var projectFolder: URL?
    @Published var detectedFiles = DetectedFiles() {
        didSet {
            guard detectedFiles != oldValue else { return }
            drillHoleSizes = Dictionary(uniqueKeysWithValues: detectedFiles.drills.map { ($0, ExcellonReader.holeSizes(in: $0)) })
        }
    }
    /// Hole diameters (mm) declared by each detected drill file.
    @Published private(set) var drillHoleSizes: [URL: [Double]] = [:]
    /// Hand-drawn layers from the shape editor; every non-empty one becomes
    /// a program of its own (see CustomLayerGenerator). Saved in the project.
    @Published var customLayers: [CustomLayer] = [] {
        didSet {
            guard customLayers != oldValue else { return }
            if projectURL == nil, !customLayers.isEmpty { manualLayerEdits = true }
            // The last drawing gone and nothing else to show: drop the preview
            // rather than keep showing a program for shapes that no longer exist.
            if !customLayers.hasShapes, !detectedFiles.hasAnyToolpathInput, preview.document != nil {
                preview.clear()
            }
            preview.parametersDidChange()
        }
    }
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

    private var cancellables = Set<AnyCancellable>()
    /// Parameter values as of the last recorded undo step (see AppModel+Undo.swift).
    var lastParameterValues: [String: String] = [:]
    var lastParameterEdit: (key: String, date: Date)?
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
        editor.app = self
        editor.undoManager = history
        layerEditor.app = self
        parameters.library = tools
        // objectWillChange fires before the new value lands; defer one runloop
        // turn so the preview controller reads the updated signature.
        lastParameterValues = parameters.exportValues()
        parameters.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.preview.parametersDidChange()
                    self?.noteParameterChange()
                }
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
        if let pcb2gcodeURL {
            if let r = try? await ProcessRunner.run(executable: pcb2gcodeURL, arguments: ["--version"]) {
                let version = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                appendLog("pcb2gcode \(version) — \(ToolLocator.pcb2gcodeIsBundled ? "built into the app" : pcb2gcodeURL.path)\n")
            }
        } else if !ToolLocator.isAppStoreBuild {
            appendLog("Note: pcb2gcode is not available; the native toolpath engine is used.\n")
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
        // Dev hook: `-debugCustomDemo 1` adds a drawn layer with one of every
        // shape kind and selects it (custom-only when no folder is given).
        if UserDefaults.standard.bool(forKey: "debugCustomDemo") {
            let layer = addCustomLayer()
            var demo = layer
            demo.toolDiameter = 0.3
            demo.cutDepth = -0.1
            demo.shapes = [
                DrawnShape(geometry: .line(points: [CGPoint(x: 2, y: 2), CGPoint(x: 14, y: 2), CGPoint(x: 14, y: 8)], closed: false), strokeWidth: 0.8),
                DrawnShape(geometry: .rect(origin: CGPoint(x: 18, y: 2), size: CGSize(width: 10, height: 6), cornerRadius: 1, rotation: 0), filled: true),
                DrawnShape(geometry: .circle(center: CGPoint(x: 36, y: 5), diameter: 6), strokeWidth: 0),
                DrawnShape(geometry: .line(points: [CGPoint(x: 44, y: 2), CGPoint(x: 52, y: 2), CGPoint(x: 48, y: 9)], closed: true)),
                DrawnShape(geometry: .text(origin: CGPoint(x: 2, y: 12), string: "CNC G-CODER", height: 3, rotation: 0, style: TextStyle())),
                DrawnShape(geometry: .text(origin: CGPoint(x: 2, y: 18), string: "Label 42", height: 3, rotation: 0,
                                           style: TextStyle(family: "Helvetica", bold: true)))
            ]
            editor.setLayer(demo, actionName: "Demo")
            // `-debugSelectShape 1` also selects the demo's rectangle, which
            // opens the floating properties panel.
            // Delayed: the canvas resets the selection when it sees the layer change.
            if UserDefaults.standard.bool(forKey: "debugSelectShape") {
                let id = demo.shapes[1].id
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.editor.selection = [id]
                }
            }
            appendLog("[debug] custom demo layer added\n")
            // Save again so the drawn layer is in the project file.
            if let path = UserDefaults.standard.string(forKey: "debugSaveProject") {
                saveProject(to: URL(fileURLWithPath: path))
            }
        }
        // Dev hook: `-debugUndoTest 1` edits a parameter, undoes and redoes it,
        // logging the value at each step.
        if UserDefaults.standard.bool(forKey: "debugUndoTest") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let before = self.parameters.isolationWidth
                self.parameters.isolationWidth = "0.77"
                try? await Task.sleep(for: .seconds(1))
                let edited = self.parameters.isolationWidth
                self.undoManager?.undo()
                try? await Task.sleep(for: .seconds(1))
                let undone = self.parameters.isolationWidth
                self.undoManager?.redo()
                try? await Task.sleep(for: .seconds(1))
                let redone = self.parameters.isolationWidth
                self.undoManager?.undo()
                let line = "[debug] undo test: \(before) → \(edited) → undo \(undone) → redo \(redone) → undo \(self.parameters.isolationWidth) (manager \(self.undoManager == nil ? "missing" : "ok"))\n"
                self.appendLog(line)
                try? line.write(toFile: NSTemporaryDirectory() + "cnc-undo-test.txt", atomically: true, encoding: .utf8)
            }
        }
        // Dev hook: `-debugEditLayer front` (a LayerSlot raw value, or drill0,
        // drill1…) opens that file in the layer editor once a preview exists;
        // `-debugEditSelect tracks|pads|all` then selects in it,
        // `-debugEditTrackWidth 0.8` / `-debugEditHole 1.2` resize the selection
        // and `-debugEditDoneAfter` ends the edit (below).
        if let raw = UserDefaults.standard.string(forKey: "debugEditLayer") {
            let target: LayerEditTarget? = raw.hasPrefix("drill")
                ? Int(raw.dropFirst(5)).map { .drill($0) } : LayerSlot(rawValue: raw).map { .layer($0) }
            Task { [weak self] in
                for _ in 0..<120 where self?.preview.document == nil { try? await Task.sleep(for: .seconds(0.5)) }
                guard let self, let target else { return }
                self.layerEditor.begin(target)
                guard let artwork = self.layerEditor.artwork else { return }
                switch (UserDefaults.standard.string(forKey: "debugEditSelect"), artwork) {
                case ("tracks", .gerber(let image)): self.layerEditor.selection = Set(image.objects.filter(\.isTrack).map(\.id))
                case ("pads", .gerber(let image)): self.layerEditor.selection = Set(image.objects.filter(\.isFlash).map(\.id))
                case ("all", _): self.layerEditor.selectAll()
                default: break
                }
                let width = UserDefaults.standard.double(forKey: "debugEditTrackWidth")
                if width > 0 { self.layerEditor.setTrackWidth(width, of: self.layerEditor.selection) }
                let hole = UserDefaults.standard.double(forKey: "debugEditHole")
                if hole > 0 { self.layerEditor.setHoleDiameter(hole, of: self.layerEditor.selection) }
                // `-debugEditDoneAfter 10` presses Done that many seconds later.
                let done = UserDefaults.standard.double(forKey: "debugEditDoneAfter")
                if done > 0 {
                    try? await Task.sleep(for: .seconds(done))
                    self.layerEditor.end()
                }
            }
        }
        // Dev hook: `-debugCompareEngines /path/report` runs pcb2gcode and the
        // native engine on the -debugProjectFolder files with the current
        // settings, writes a report and overlay images there, and quits.
        if let dir = UserDefaults.standard.string(forKey: "debugCompareEngines") {
            // `-debugCompareNativeOnly 1`: both sides native — for the safety
            // figures on boards pcb2gcode takes too long on.
            let binary = UserDefaults.standard.bool(forKey: "debugCompareNativeOnly") ? nil : pcb2gcodeURL
            let report = await EngineComparison.run(pcb2gcode: binary, params: parameters.snapshot(),
                                                   files: detectedFiles, reportDir: URL(fileURLWithPath: dir))
            print(report)
            exit(0)
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
        layerEditor.end()
        projectFolder = url
        chosenOutputDir = nil   // a new project must never inherit the old destination
        manualLayerEdits = false
        layerOrigins = [:]
        customLayers = []
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
        clearUndoHistory()

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
        let hasCustom = customLayers.hasShapes
        if !detectedFiles.hasAnything && !hasCustom {
            return "Nothing to generate — open a project, or draw on a custom layer."
        }
        if detectedFiles.hasAnything {
            if projectFolder == nil { return "Choose a project folder first." }
        }
        if let bad = parameters.validationError { return "Invalid value in \"\(bad)\" — fix it before generating." }
        if let layer = customLayers.first(where: { !$0.isEmpty && $0.validationError != nil }) {
            return "Custom layer \"\(layer.name)\": \(layer.validationError ?? "")."
        }
        return nil
    }

    /// Runs a generation into `destination`. Both targets share the same
    /// pcb2gcode batch; only what is written at the end differs.
    func startGeneration(target: GenerateTarget, destination: URL) {
        guard !isGenerating else { return }
        let pcb2gcodeURL = self.pcb2gcodeURL
        if let blocker = generationBlocker(for: target) {
            appendLog("\nERROR: \(blocker)\n")
            return
        }

        guard FileAccess.canWrite(into: destination) else {
            let problem = "No permission to write to \(destination.path) — use Choose… to pick the folder."
            appendLog("\nERROR: \(problem)\n")
            generationSteps = []
            generationSummary = problem
            generationFailed = true
            return
        }
        chosenOutputDir = destination
        isGenerating = true
        generationSteps = []
        generationSummary = nil
        generationFailed = false
        generationTotal = (detectedFiles.hasAnything ? Pcb2GcodeService.stepCount(parameters.snapshot(), files: detectedFiles, pcb2gcode: pcb2gcodeURL) : 0)
            + (customLayers.hasShapes ? 1 : 0)
            + (target == .laser ? 1 : 0)   // plus the rendering pass
        appendLog("\n--- \(target == .cnc ? "Generating" : "Exporting laser artwork") into \(destination.path) ---\n")

        let snapshot = parameters.snapshot()
        let files = detectedFiles
        let custom = customLayers
        let options = ArtworkExport.Options.current

        generateTask = Task { [weak self] in
            guard let self else { return }
            await self.preview.cancelActiveRun()   // never two pcb2gcode batches at once

            // Both targets generate into a temp folder: pcb2gcode may only
            // write inside the app's sandbox. The CNC target then copies the
            // .ngc files over; the laser target writes only the artwork.
            let workDir = PreviewPaths.newRunDir()
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            } catch {
                self.finishGeneration(summary: "Could not create the working folder: \(error.localizedDescription)", failed: true)
                return
            }
            defer { try? FileManager.default.removeItem(at: workDir) }

            var batch = Pcb2GcodeService.BatchResult()
            if files.hasAnything {
                batch = await Pcb2GcodeService.runBatch(
                    pcb2gcode: pcb2gcodeURL, params: snapshot, files: files, outputDir: workDir,
                    onStep: { [weak self] event, total in
                        Task { @MainActor [weak self] in self?.reportStep(event, total: total) }
                    })
                self.appendLog(batch.log)
            }

            if Task.isCancelled {
                self.finishGeneration(summary: "Cancelled.", failed: true)
                return
            }
            guard batch.succeeded else {
                self.finishGeneration(summary: "pcb2gcode failed — see the Log.", failed: true)
                return
            }
            // Drawn layers are generated in-app, into the same folder and frame.
            if custom.hasShapes {
                let stepID = 100_000
                self.reportStep(.started(id: stepID, label: "Custom layers"), total: self.generationTotal)
                // No Gerber programs: the drawing sets the origin frame itself.
                if batch.outputs.isEmpty { batch.frame = CustomLayerGenerator.frame(layers: custom, params: snapshot) }
                let frame = batch.frame
                let result = await Task.detached(priority: .userInitiated) {
                    CustomLayerGenerator.write(layers: custom, params: snapshot, frame: frame, outputDir: workDir)
                }.value
                self.appendLog(result.log)
                batch.outputs += result.outputs
                self.reportStep(.finished(id: stepID), total: self.generationTotal)
            }
            guard !batch.outputs.isEmpty else {
                self.finishGeneration(summary: "No programs were produced — see the Log.", failed: true)
                return
            }

            switch target {
            case .cnc:
                if snapshot.maskMode == "svg", files.topMask != nil || files.bottomMask != nil {
                    let maskResult = Pcb2GcodeService.exportMaskSVGs(files: files, outputDir: destination)
                    self.appendLog(maskResult.log)
                }
                var count = 0
                for output in batch.outputs {
                    let target = destination.appendingPathComponent(output.url.lastPathComponent)
                    do {
                        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                        try FileManager.default.copyItem(at: output.url, to: target)
                        count += 1
                    } catch {
                        self.appendLog("ERROR writing \(target.path): \(error.localizedDescription)\n")
                    }
                }
                self.finishGeneration(summary: "\(count) program\(count == 1 ? "" : "s") written.",
                                      failed: count < batch.outputs.count)

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
