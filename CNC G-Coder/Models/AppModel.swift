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
    /// The GRBL/FluidNC session behind the Machine panel (connection, jog,
    /// probe, job streaming). One per app: the link outlives projects.
    let machine = MachineController()

    @Published var projectFolder: URL? {
        didSet {
            // Height maps are keyed by the project; a different folder means
            // a different board.
            if projectFolder != oldValue { loadHeightMaps() }
        }
    }
    /// Probed height maps of the current project, per board side (see
    /// HeightMap). Kept in Application Support, never beside the user's files.
    @Published var heightMaps: [BoardSide: HeightMap] = [:]
    /// Set by the sidebar's "Send … to Machine…" before the Machine panel
    /// opens; the Program controls consume it.
    @Published var requestedMachineLayer: LayerKind?
    /// The Machine inspector in the main window (toolbar toggle, View →
    /// Machine Panel ⇧⌘M, "Send … to Machine…"). Remembered across launches.
    @Published var showMachineInspector = UserDefaults.standard.bool(forKey: "ui.machineInspector") {
        didSet { UserDefaults.standard.set(showMachineInspector, forKey: "ui.machineInspector") }
    }
    @Published var detectedFiles = DetectedFiles() {
        didSet {
            guard detectedFiles != oldValue else { return }
            drillHoleSizes = Dictionary(uniqueKeysWithValues: detectedFiles.drills.map { ($0, ExcellonReader.holeSizes(in: $0)) })
            measureMaskOpenings()
        }
    }

    /// Finds the widest opening of the mask layers for the automatic mask
    /// clear width (ParametersStore.widestMaskOpening). Done at once, so a
    /// snapshot taken right after the files change already has it.
    private func measureMaskOpenings() {
        let masks = [detectedFiles.topMask, detectedFiles.bottomMask].compactMap { $0 }
        let widest = masks.compactMap(NativeToolpathEngine.widestFeature(in:)).max()
        if parameters.widestMaskOpening != widest { parameters.widestMaskOpening = widest }
    }
    /// Hole diameters (mm) declared by each detected drill file.
    @Published private(set) var drillHoleSizes: [URL: [Double]] = [:]

    /// The drill file (its name, the key of its own settings in
    /// ParametersStore.drillLayerValues) behind a drill program or its
    /// milled holes; nil for every other program.
    func drillFile(for kind: LayerKind) -> String? {
        guard let index = kind.drillIndex, detectedFiles.drills.indices.contains(index) else { return nil }
        return detectedFiles.drills[index].lastPathComponent
    }
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
    @Published var projectURL: URL? {
        didSet {
            guard projectURL != oldValue else { return }
            // An untitled project being saved keeps its maps in memory (the
            // folder stays the same); opening another project replaces them
            // once its folder lands (projectFolder's didSet).
            loadHeightMaps(carryOver: oldValue == nil && projectURL != nil)
        }
    }
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
    var lastParameterValues = ParameterState()
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
        machine.app = self
        parameters.library = tools
        // objectWillChange fires before the new value lands; defer one runloop
        // turn so the preview controller reads the updated signature.
        lastParameterValues = parameters.exportState()
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

    // MARK: - Height maps (machine autolevel)

    /// What a project's height maps are filed under: the project file, or the
    /// Gerber folder of an untitled one. Nil for an untitled drawing-only
    /// project (maps stay in memory).
    var heightMapKey: String? { projectURL?.path ?? projectFolder?.path }

    /// Design (Gerber) → program frame of `side` (`ProjectFrame.designToFront`
    /// / `designToBack`); identity when the preview has no frame (zeroing
    /// off, no document, an external program). Height maps live in design
    /// coordinates and go through this at the edges.
    func heightMapFrame(side: BoardSide) -> CGAffineTransform {
        guard let frame = preview.document?.frame else { return .identity }
        return side == .back ? frame.designToBack : frame.designToFront
    }

    /// Bumped by View Options → "Fit Machine Travel": the canvas frames the
    /// machine's travel area once (never by default — the board stays the
    /// default framing).
    @Published var travelFitRequest = 0

    /// Keeps a probed map for its side and writes it to Application Support.
    func saveHeightMap(_ map: HeightMap) {
        heightMaps[map.side] = map
        guard let key = heightMapKey else { return }
        let url = HeightMap.storageURL(projectKey: key, side: map.side)
        do {
            try map.write(to: url)
            appendLog("[machine] Height map (\(map.side.title)) saved: \(url.path)\n")
        } catch {
            appendLog("[machine] ERROR saving the height map: \(error.localizedDescription)\n")
        }
    }

    /// Reads the current project's maps from disk. With `carryOver`, maps
    /// already in memory survive when the new key has none on disk (an
    /// untitled project being saved for the first time).
    func loadHeightMaps(carryOver: Bool = false) {
        var loaded: [BoardSide: HeightMap] = [:]
        if let key = heightMapKey {
            for side in BoardSide.allCases {
                let url = HeightMap.storageURL(projectKey: key, side: side)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if let map = try? HeightMap.read(from: url) { loaded[side] = map }
            }
        }
        if loaded.isEmpty, carryOver { return }
        heightMaps = loaded
    }

    private func startup() async {
        PreviewPaths.cleanRoot()
        try? FileManager.default.removeItem(at: ProjectDocument.workingRoot)
        TempRoots.cleanStale(named: ProjectDocument.workingRootName)
        if let pcb2gcodeURL {
            if let r = try? await ProcessRunner.run(executable: pcb2gcodeURL, arguments: ["--version"]) {
                let version = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                appendLog("pcb2gcode \(version) — \(ToolLocator.pcb2gcodeIsBundled ? "built into the app" : pcb2gcodeURL.path)\n")
            }
        } else if !ToolLocator.isAppStoreBuild {
            appendLog("Note: pcb2gcode is not available; the native toolpath engine is used.\n")
        }
        // Dev hooks: `-debugProjectFolder /path/to/gerbers` skips the open panel
        // (`-debugOpenProject /path/x.cncproj` opens a saved project instead);
        // adding `-debugGenerate 1` (or `-debugGenerateLaser 1`) also runs that
        // generation straight into a folder beside the project, no panel.
        var debugOpened = false
        if let debugFolder = UserDefaults.standard.string(forKey: "debugProjectFolder") {
            selectProjectFolder(URL(fileURLWithPath: debugFolder, isDirectory: true))
            debugOpened = true
        } else if let path = UserDefaults.standard.string(forKey: "debugOpenProject") {
            openProject(at: URL(fileURLWithPath: path), confirmed: true)
            debugOpened = true
        }
        if debugOpened {
            // `-debugDrillSettings "a.drl:drillMillLarge=true,zDrill=-2;b.drl:zDrill=-1.5"`
            // gives drill files settings of their own, as the sidebar does.
            if let spec = UserDefaults.standard.string(forKey: "debugDrillSettings") {
                for entry in spec.split(separator: ";") {
                    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    for pair in parts[1].split(separator: ",") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { parameters.setDrillValue(kv[0], kv[1], file: parts[0]) }
                    }
                    appendLog("[debug] \(parts[0]) settings: \(parts[1])\n")
                }
            }
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
                // `-debugGenerateLog /path/log.txt` writes the Log there once
                // that generation has finished, then quits.
                if let logPath = UserDefaults.standard.string(forKey: "debugGenerateLog") {
                    Task { [weak self] in
                        for _ in 0..<1200 {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard let self else { return }
                            if !self.isGenerating, self.generationSummary != nil { break }
                        }
                        try? self?.log.write(toFile: logPath, atomically: true, encoding: .utf8)
                        exit(0)
                    }
                }
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
        // Dev hook: `-debugHoleTest /path/out.ngc` writes a hole fit test
        // (2/3/4 mm, six variants, a 2 mm corn bit) and shows it in the preview.
        if let holePath = UserDefaults.standard.string(forKey: "debugHoleTest") {
            var corn = MachineTool(name: "Corn 2 mm")
            corn.diameter = 2; corn.cutDepth = -1.8; corn.depthPerPass = 0.6
            corn.feedXY = 300; corn.feedZ = 100
            let spec = TestBoardGenerator.HoleFitSpec(diameters: [2, 3, 4], offsets: [-0.05, 0, 0.05, 0.10, 0.15, 0.20],
                                                      tool: corn, zsafe: 3)
            if let result = TestBoardGenerator.holeFitTest(spec) {
                let url = URL(fileURLWithPath: holePath)
                try? result.gcode.write(to: url, atomically: true, encoding: .utf8)
                try? result.legend.write(to: url.deletingPathExtension().appendingPathExtension("legend.txt"),
                                         atomically: true, encoding: .utf8)
                preview.loadExternal(url: url, toolDiameter: spec.cut)
            }
        }
        // Dev hook: `-debugTestDialog 1` opens Generate Test Board… at launch.
        if UserDefaults.standard.bool(forKey: "debugTestDialog") { showTestBoardDialog = true }
        // Dev hook: `-debugOpenProject /path/x.cncproj` opens a saved project.
        if let path = UserDefaults.standard.string(forKey: "debugOpenProject") {
            openProject(at: URL(fileURLWithPath: path), confirmed: true)
        }
        // Dev hook: `-debugTestBoard /path/out.ngc` generates a default test
        // board there and shows it in the preview.
        if let testPath = UserDefaults.standard.string(forKey: "debugTestBoard") {
            var bit = MachineTool(name: "V-bit 30° · 0.1 mm tip")
            bit.shape = .vBit; bit.tipDiameter = 0.1; bit.tipAngle = 30; bit.feedZ = 60
            let spec = TestBoardGenerator.Spec(
                width: 60, height: 45, rows: 4, cols: 5,
                depthFrom: -0.04, depthTo: -0.12,
                feedFrom: 120, feedTo: 360, tool: bit,
                isolationWidth: Double(parameters.isolationWidth.trimmingCharacters(in: .whitespaces)) ?? 0.2, zsafe: 3
            )
            if let result = TestBoardGenerator.generate(spec) {
                let url = URL(fileURLWithPath: testPath)
                try? result.gcode.write(to: url, atomically: true, encoding: .utf8)
                appendLog("\n[debug] test board written to \(testPath)\n")
                preview.loadExternal(url: url, toolDiameter: spec.widestCut)
            }
        }
        await runMachineDevHooks()
    }

    // MARK: - Machine dev hooks

    /// Logs a machine hook event to the Log tab and stdout.
    private func machineLog(_ text: String) {
        appendLog("[machine] \(text)\n")
        print("[machine] \(text)")
    }

    /// Headless machine control against the fake controller (Scripts/fake-grbl.py):
    /// `-debugMachineConnect host:port` (or `sim` for the built-in simulator)
    /// or `-debugMachineSerial /dev/cu.…` connects and identifies; `-debugMachineSend <front|back|outline|drill0|…|/path.ngc>`
    /// streams a program; `-debugMachineAutoContinue 1` continues every
    /// tool-change suspension after a second; `-debugMachineScript "a;b;c"` runs
    /// steps (jog:x,1 | zero:xy | setx:5 | gozero | safez | send:front |
    /// wait:suspended | continue | hold | resume | fromLine:120 | stop |
    /// estop | savezero[:name] | usezero:name | verify:front | probez |
    /// wait:done | sleep:2 | home | unlock);
    /// `-debugMachineProbeMap 3x3` probes a map over the first program;
    /// `-debugMachineClampZ 1` prepares with "Clamp Z to top";
    /// `-debugMachineExitWhenDone 1` prints the job summary and quits.
    private func runMachineDevHooks() async {
        let defaults = UserDefaults.standard
        let tcp = defaults.string(forKey: "debugMachineConnect")
        let serial = defaults.string(forKey: "debugMachineSerial")
        guard tcp != nil || serial != nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0)   // hook output reaches a redirected file line by line
        let exitWhenDone = defaults.bool(forKey: "debugMachineExitWhenDone")

        if let tcp, ["sim", "simulator"].contains(tcp.lowercased()) {
            await machine.connectSimulator()
        } else if let tcp {
            let parts = tcp.split(separator: ":", maxSplits: 1).map(String.init)
            let host = parts.first ?? tcp
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 23 : 23
            await machine.connect(tcpHost: host, port: port)
        } else if let serial {
            await machine.connect(serialPath: serial, baud: 115200)
        }
        guard machine.isConnected else {
            machineLog("connect failed: \(machine.lastError ?? "unknown error")")
            if exitWhenDone { exit(1) }
            return
        }
        // The first report decides homed/alarm; wait for it before anything else.
        _ = await machine.waitForStatus(timeout: 5) { _ in true }
        machineLog("connected: \(machine.firmware.description) (\(machine.statusSummary), homed \(machine.homed), trusted \(machine.positionTrusted))")

        if defaults.bool(forKey: "debugMachineAutoContinue") {
            Task { [weak self] in
                var continued = 0
                while let self, self.machine.isConnected {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self.machine.streamer.isSuspended else { continue }
                    try? await Task.sleep(for: .seconds(1))
                    guard self.machine.streamer.isSuspended else { continue }
                    continued += 1
                    self.machineLog("auto-continue #\(continued) from line \(self.machine.streamer.resumeLine ?? 0)")
                    await self.machine.continueJob()
                    if self.machine.streamer.isSuspended {
                        self.machineLog("continue refused: \(self.machine.streamer.lastMessage ?? "?")")
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }

        if let script = defaults.string(forKey: "debugMachineScript") {
            await runMachineScript(script)
        } else if let target = defaults.string(forKey: "debugMachineSend") {
            if await machineSend(target) {
                await machine.streamer.start()
                machineLog("start: \(machine.streamer.state)" + (machine.streamer.lastMessage.map { " — \($0)" } ?? ""))
            }
        }

        if let grid = defaults.string(forKey: "debugMachineProbeMap") {
            await machineProbeMap(grid)
        }

        if exitWhenDone {
            await machine.streamer.waitUntilFinished()
            let s = machine.streamer
            let name = s.program?.name ?? "none"
            let summary = "JOB \(name): sent \(s.sentLine), acked \(s.ackedLine), errors \(s.lineErrors.count), final \(s.state)"
            machineLog(summary)
            print(summary)
            exit(0)
        }
    }

    /// Resolves a hook's layer name (or .ngc path) against the preview
    /// document, waiting for it to exist.
    private func machineResolveLayer(_ target: String) async -> ParsedLayer? {
        if target.hasPrefix("/") {
            let url = URL(fileURLWithPath: target)
            preview.loadExternal(url: url, toolDiameter: nil)
            for _ in 0..<60 where preview.document?.layers.first?.id != .test { try? await Task.sleep(for: .milliseconds(500)) }
            return preview.document?.layers.first { $0.id == .test }
        }
        for _ in 0..<120 where preview.document == nil { try? await Task.sleep(for: .milliseconds(500)) }
        // Let a running regeneration land so the program matches the settings.
        for _ in 0..<60 where preview.isStale && !preview.showsExternalFile { try? await Task.sleep(for: .milliseconds(500)) }
        guard let layers = preview.document?.layers else { return nil }
        let key = target.lowercased()
        let kind: LayerKind?
        switch key {
        case "front": kind = .front
        case "back": kind = .back
        case "outline": kind = .outline
        case "masktop", "mask_top", "mask-top": kind = .maskTop
        case "maskbottom", "mask_bottom", "mask-bottom": kind = .maskBottom
        case "silktop", "silk_top", "silk-top": kind = .silkTop
        case "silkbottom", "silk_bottom", "silk-bottom": kind = .silkBottom
        case "test": kind = .test
        default:
            if key.hasPrefix("drill"), let index = Int(key.dropFirst(5)) {
                kind = layers.map(\.id).first { if case .drill(let i, _) = $0 { return i == index } else { return false } }
            } else {
                kind = layers.map(\.id).first { $0.fileSlug == key || $0.displayName.lowercased() == key }
            }
        }
        guard let kind, let layer = layers.first(where: { $0.id == kind }) else {
            machineLog("no layer named “\(target)” — have: " + layers.map { $0.id.fileSlug }.joined(separator: ", "))
            return nil
        }
        return layer
    }

    /// Prepares and loads a program for the hooks. True when loaded.
    private func machineSend(_ target: String) async -> Bool {
        guard let layer = await machineResolveLayer(target) else { return false }
        // `-debugMachineClampZ 1`: prepare with "Clamp Z to top" (air tests).
        let options = ProgramOptions(applyBacklash: MachineSettings.applyBacklash,
                                     heightMap: UserDefaults.standard.bool(forKey: "debugMachineApplyMap") ? heightMaps[layer.id.boardSide] : nil,
                                     applyBelowZ: MachineSettings.heightMapApplyBelowZ,
                                     frame: heightMapFrame(side: layer.id.boardSide),
                                     clampZAboveWork: UserDefaults.standard.bool(forKey: "debugMachineClampZ") ? machine.clampZWork() : nil)
        do {
            let program = try await machine.prepareProgram(layer: layer, name: layer.id.fileSlug + ".ngc", options: options)
            requestedMachineLayer = layer.id   // the Machine window's Program tab adopts this program instead of preparing its own
            machineLog("loaded \(program.name): \(program.lines.count) lines, \(program.segments.count) segments, "
                       + "tool changes at \(program.toolChangeLines.sorted()), est. \(Int(program.parsed.totalTime)) s → \(program.url.path)")
            if let clamp = program.options.clampZAboveWork {
                machineLog("clamp Z above work \(GRBLCommand.number(clamp)): " + (program.notes.first { $0.hasPrefix("Z clamped") } ?? "no note"))
            } else if UserDefaults.standard.bool(forKey: "debugMachineClampZ") {
                machineLog("clamp Z requested but unavailable (Z travel \(machine.axisRanges[.z].map { "\($0)" } ?? "unknown"), WCO \(machine.status.workOffset?.summary ?? "unknown"))")
            }
            _ = await machine.waitForStatus(timeout: 10) { $0.state == .idle }
            return true
        } catch {
            machineLog("prepare failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Probes an `AxB` map over the first program's cut bounds and saves it.
    private func machineProbeMap(_ grid: String) async {
        for _ in 0..<120 where preview.document == nil { try? await Task.sleep(for: .milliseconds(500)) }
        guard let layer = preview.document?.layers.first else { machineLog("probe map: no program"); return }
        let counts = grid.lowercased().split(separator: "x").compactMap { Int($0) }
        // The map is anchored to the board: the program's bounds in design coordinates.
        let frame = heightMapFrame(side: layer.id.boardSide)
        let bounds = (layer.cutBounds ?? layer.allBounds ?? .zero).applying(frame.inverted())
        var map = HeightMap.auto(for: bounds, side: layer.id.boardSide)
        if counts.count == 2 {
            map.nx = max(2, counts[0])
            map.ny = max(2, counts[1])
            map.clear()
        }
        machineLog("probe map \(map.nx)×\(map.ny) over design \(map.rect) (\(map.side.title)), frame tx \(frame.tx) ty \(frame.ty), work rect \(map.rect.applying(frame))")
        _ = await machine.waitForStatus(timeout: 10) { $0.state == .idle }
        await machine.probeHeightMap(map)
        guard let result = heightMaps[map.side], result.isComplete else {
            machineLog("probe map failed: \(machine.streamer.lastMessage ?? "?")")
            return
        }
        let path: String
        if let key = heightMapKey {
            path = HeightMap.storageURL(projectKey: key, side: map.side).path
        } else {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cnc-heightmap-\(map.side.rawValue).json")
            try? result.write(to: url)
            path = url.path
        }
        let deviation = result.maxDeviation.map { String(format: "%.3f", $0) } ?? "?"
        machineLog("probe map done: \(result.probedCount)/\(result.totalCount) points, reference Z \(result.referenceZ.map(GRBLCommand.number) ?? "?"), max deviation \(deviation) mm, design origin \(result.probedDesignOrigin?.summary ?? "?") → \(path)")
    }

    /// Runs `step;step;…` against the machine, logging each.
    private func runMachineScript(_ script: String) async {
        var lastSeenError = machine.lastError
        for raw in script.split(separator: ";") {
            let step = raw.trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { continue }
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0].lowercased()
            let argument = parts.count > 1 ? parts[1] : ""
            machineLog("step: \(step)")
            let m = machine
            switch verb {
            case "sleep":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "jog":
                let args = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let axis = args.first.flatMap({ Axis(rawValue: $0.uppercased()) }) else { machineLog("jog: bad axis"); continue }
                let distance = args.count > 1 ? Double(args[1]) ?? 1 : 1
                await m.jog(axis: axis, direction: distance < 0 ? .negative : .positive, distance: abs(distance), feed: MachineSettings.jogFeed)
                _ = await m.waitForStatus(timeout: 30) { $0.state == .idle }
            case "zero":
                let axes = argument.uppercased().compactMap { Axis(rawValue: String($0)) }
                await m.zero(axes: axes.isEmpty ? Axis.allCases : axes)
            case "setx", "sety", "setz":
                let axis = Axis(rawValue: String(verb.last!).uppercased()) ?? .x
                let before = m.status.workOffset
                await m.setAxis(axis, workValue: Double(argument) ?? 0)
                // G10 is acknowledged before the controller reports the new
                // WCO:; a following step (send with Clamp Z) needs the fresh one.
                _ = await m.waitForStatus(timeout: 3) { $0.workOffset != nil && $0.workOffset != before }
            case "gozero":
                await m.goToWorkZero()
                _ = await m.waitForStatus(timeout: 60) { $0.state == .idle }
            case "safez":
                await m.safePosition()
                _ = await m.waitForStatus(timeout: 60) { $0.state == .idle }
            case "home":
                await m.home()
            case "unlock":
                await m.unlock()
            case "send":
                if await machineSend(argument) {
                    await m.streamer.start()
                    machineLog("start: \(m.streamer.state)" + (m.streamer.lastMessage.map { " — \($0)" } ?? ""))
                }
            case "verify":
                if m.streamer.program == nil || !argument.isEmpty {
                    guard await machineSend(argument.isEmpty ? "front" : argument) else { continue }
                }
                await m.streamer.verify()
                machineLog("verify: \(m.streamer.state)" + (m.streamer.lastMessage.map { " — \($0)" } ?? ""))
            case "wait":
                switch argument.lowercased() {
                case "suspended":
                    for _ in 0..<1200 where !m.streamer.isSuspended && m.streamer.isActive { try? await Task.sleep(for: .milliseconds(500)) }
                    machineLog("wait:suspended → \(m.streamer.state), resume line \(m.streamer.resumeLine ?? 0)")
                case "idle":
                    _ = await m.waitForStatus(timeout: 600) { $0.state == .idle }
                default:
                    await m.streamer.waitUntilFinished()
                    machineLog("wait:done → \(m.streamer.state), acked \(m.streamer.ackedLine)/\(m.streamer.program?.lines.count ?? 0), errors \(m.streamer.lineErrors.count), elapsed \(Int(m.streamer.elapsed)) s")
                }
            case "continue":
                await m.continueJob()
                machineLog("continue: \(m.streamer.state)" + (m.streamer.lastMessage.map { " — \($0)" } ?? "")
                           + (m.streamer.validityPrompt.map { " — height map prompt: \($0)" } ?? ""))
            case "hold":
                m.streamer.pause()
                _ = await m.waitForStatus(timeout: 5) { $0.state.isHoldComplete }
                machineLog("hold: \(m.status.state.name)")
            case "resume":
                m.streamer.resume()
            case "fromline":
                if m.streamer.isActive { await m.streamer.stop() }
                await m.sendFromLine(Int(argument) ?? 1)
                machineLog("fromLine: \(m.streamer.state)" + (m.streamer.lastMessage.map { " — \($0)" } ?? ""))
            case "stop":
                // The script's stop ends the job whatever its state (a
                // suspended job included — the controller's stop leaves a
                // parked job alone on purpose, as ⌘. does during a tool change).
                if m.streamer.isActive { await m.streamer.stop() } else { await m.stop() }
                machineLog("stop: \(m.streamer.state), machine \(m.status.state.name), trusted \(m.positionTrusted)")
            case "estop":
                let before = m.status.state.name
                m.emergencyStop()
                _ = await m.waitForStatus(timeout: 5) { _ in true }
                machineLog("estop: was \(before) → job \(m.streamer.state), machine \(m.status.state.name), trusted \(m.positionTrusted)")
            case "savezero":
                // The work origin as a machine position, like the Positions tab's "Save work zero".
                if let wco = m.status.workOffset {
                    m.positions.add(name: argument.isEmpty ? "Work zero" : argument, position: wco)
                    machineLog("savezero: \(m.positions.positions.last?.name ?? "?") = \(wco.summary)")
                } else {
                    machineLog("savezero: work offset unknown")
                }
            case "usezero":
                if let saved = m.positions.positions.first(where: { $0.name.caseInsensitiveCompare(argument) == .orderedSame }) {
                    await m.setWorkOrigin(machine: saved.position)
                    machineLog("usezero: \(saved.name) → WCO \(m.status.workOffset?.summary ?? "?"), work \(m.status.workPosition?.summary ?? "?")")
                } else {
                    machineLog("usezero: no saved position named “\(argument)”")
                }
            case "steps":
                // steps:x — read the axis' steps/mm (FluidNC).
                if let axis = Axis(rawValue: argument.uppercased()) {
                    do { machineLog("steps \(axis.rawValue): \(GRBLCommand.number(try await m.readStepsPerMM(axis))), config \(try await m.readConfigFilename())") }
                    catch { machineLog("steps: \(error.localizedDescription)") }
                }
            case "calibrate":
                // calibrate:x,commanded,measured[,file] — correct the axis' steps/mm and save.
                let parts = argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 3, let axis = Axis(rawValue: parts[0].uppercased()),
                   let commanded = Double(parts[1]), let measured = Double(parts[2]) {
                    do {
                        let current = try await m.readStepsPerMM(axis)
                        guard let corrected = MachineController.correctedSteps(current: current, commanded: commanded, measured: measured) else { machineLog("calibrate: bad numbers"); break }
                        let file = parts.count > 3 ? parts[3] : try await m.readConfigFilename()
                        let change = try await m.writeStepsPerMM(axis, corrected, saveTo: file)
                        machineLog("calibrate \(axis.rawValue): \(GRBLCommand.number(change.previous)) → \(GRBLCommand.number(change.current)) (saved to \(change.savedTo ?? "nothing"))")
                    } catch { machineLog("calibrate: \(error.localizedDescription)") }
                }
            case "probez":
                // A height-mapped program: the bit is measured at the work
                // origin, where the map's reference was probed.
                let atOrigin = m.streamer.program?.options.heightMap != nil
                let failure = atOrigin ? await m.probeZAtWorkOrigin() : await m.probeZ()
                machineLog("probeZ\(atOrigin ? " at origin" : ""): " + (failure ?? "ok — PRB \(m.lastProbe?.position.summary ?? "?"), work Z now \(m.status.workPosition.map { GRBLCommand.number($0.z) } ?? "?")"))
            default:
                machineLog("unknown step “\(step)”")
            }
            if let error = m.lastError, error != lastSeenError {
                lastSeenError = error
                machineLog("lastError: \(error)")
            }
        }
        machineLog("script done — \(machine.statusSummary), work \(machine.status.workPosition?.summary ?? "?")")
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
        // EasyEDA names drill files the same in every export: the previous
        // project's per-file settings must not land on this one's.
        parameters.drillLayerValues = [:]
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
                // Last of all, so it sees every move the other passes wrote.
                self.appendLog(BacklashCompensation.apply(.current, files: batch.outputs.map(\.url)))
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
            appendLog(BacklashCompensation.apply(.current, files: [url]))
        } catch {
            appendLog("\nERROR exporting \(layer.displayName): \(error.localizedDescription)\n")
        }
    }

    // MARK: - Backlash compensation (Machine setup)

    /// Opens the test dialog on the backlash test.
    func openBacklashTest() {
        UserDefaults.standard.set(TestKind.backlash.rawValue, forKey: TestKind.storageKey)
        showTestBoardDialog = true
    }

    /// Writes a compensated copy of any G-code file — for programs made
    /// outside the app.
    func compensateGCodeFile() {
        let settings = BacklashCompensation.Settings.current
        guard settings.isActive else { return }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        open.message = "Choose a G-code file to compensate (\(settings.summary))."
        guard open.runModal() == .OK, let source = open.url else { return }

        let save = NSSavePanel()
        let ext = source.pathExtension.isEmpty ? "ngc" : source.pathExtension
        save.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-compensated." + ext
        save.directoryURL = source.deletingLastPathComponent()
        save.allowsOtherFileTypes = true
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let url = save.url else { return }

        do {
            let text = try String(contentsOf: source, encoding: .utf8)
            let result = try BacklashCompensation.apply(settings, to: text)
            try result.text.write(to: url, atomically: true, encoding: .utf8)
            appendLog("\nBacklash compensation (\(settings.summary)): \(source.lastPathComponent) → \(url.path), \(result.takeUps) take-up moves.\n")
        } catch {
            appendLog("\nERROR: could not compensate \(source.lastPathComponent): \(error.localizedDescription)\n")
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
