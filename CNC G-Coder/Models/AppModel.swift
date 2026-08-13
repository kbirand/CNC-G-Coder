import SwiftUI
import AppKit
import Combine

/// Root application model: project folder, detected files, log, generation.
@MainActor
final class AppModel: ObservableObject {

    let parameters = ParametersStore()
    let preview = PreviewController()
    /// Playback/selection state is app-wide: the layer picker lives in the left
    /// panel (it also decides which settings are shown) while the transport bar
    /// and canvases live in the preview pane.
    let player = PlaybackState()

    @Published var projectFolder: URL?
    @Published var detectedFiles = DetectedFiles()
    @Published var log = "Ready.\n"
    @Published var isGenerating = false
    @Published var showTestBoardDialog = false
    /// Output folder the user picked at Generate time (remembered for this
    /// session, cleared when the project changes).
    @Published var chosenOutputDir: URL?

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
        preview.app = self
        player.preview = preview
        // objectWillChange fires before the new value lands; defer one runloop
        // turn so the preview controller reads the updated signature.
        parameters.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.preview.parametersDidChange() }
            }
            .store(in: &cancellables)
        Task { await startup() }
    }

    func appendLog(_ text: String) {
        log += text
    }

    private func startup() async {
        PreviewPaths.cleanRoot()
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
        // adding `-debugGenerate 1` also runs a final generation immediately.
        if let debugFolder = UserDefaults.standard.string(forKey: "debugProjectFolder") {
            selectProjectFolder(URL(fileURLWithPath: debugFolder, isDirectory: true))
            if UserDefaults.standard.bool(forKey: "debugGenerate") {
                generate()
            }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectProjectFolder(url)
    }

    func selectProjectFolder(_ url: URL) {
        projectFolder = url
        chosenOutputDir = nil   // a new project must never inherit the old destination
        detectedFiles = GerberDetector.detect(in: url)

        appendLog("\nSelected project folder: \(url.path)\n")
        appendLog("Auto-detected:\n")
        appendLog("Top: \(detectedFiles.front?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Bottom: \(detectedFiles.back?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Outline: \(detectedFiles.outline?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Top mask: \(detectedFiles.topMask?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Bottom mask: \(detectedFiles.bottomMask?.lastPathComponent ?? "NOT FOUND")\n")
        appendLog("Drills: \(detectedFiles.drills.count)\n")

        preview.parametersDidChange()
    }

    // MARK: - Final generation

    func generate() {
        guard !isGenerating else { return }
        guard let pcb2gcodeURL else {
            appendLog("\nERROR: pcb2gcode not found. Expected /opt/homebrew/bin/pcb2gcode or /usr/local/bin/pcb2gcode\n")
            return
        }
        guard detectedFiles.hasAnything else { return }
        if let bad = parameters.validationError {
            appendLog("\nERROR: invalid value in \"\(bad)\" — fix it before generating.\n")
            return
        }

        // Ask where to write the programs (the standard New Folder button is
        // available for creating a fresh destination).
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Generate"
        panel.message = "Choose the folder for the generated G-code programs — use New Folder to create one."
        panel.directoryURL = chosenOutputDir ?? projectFolder
        guard panel.runModal() == .OK, let outputDir = panel.url else { return }
        chosenOutputDir = outputDir

        isGenerating = true
        appendLog("\n--- Generating into \(outputDir.path) ---\n")

        let snapshot = parameters.snapshot()
        let files = detectedFiles
        let gerbv = gerbvURL

        generateTask = Task { [weak self] in
            guard let self else { return }
            await self.preview.cancelActiveRun()   // never two pcb2gcode batches at once

            let batch = await Pcb2GcodeService.runBatch(pcb2gcode: pcb2gcodeURL, params: snapshot, files: files, outputDir: outputDir)
            self.appendLog(batch.log)

            if snapshot.maskMode == "svg", files.topMask != nil || files.bottomMask != nil {
                if let gerbv {
                    let maskResult = await Pcb2GcodeService.exportMaskSVGs(gerbv: gerbv, files: files, outputDir: outputDir)
                    self.appendLog(maskResult.log)
                } else {
                    self.appendLog("WARNING: gerbv not found; solder-mask SVGs were not generated.\nInstall it with: brew install gerbv\n")
                }
            }

            self.appendLog("\nDone. Check the output folder.\n")
            self.isGenerating = false
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
