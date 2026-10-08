import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A file picked with Import Layer…, with the role it will take.
struct PendingImport: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// nil = skip this file.
    var slot: LayerSlot?
}

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    static let cncProject = UTType(exportedAs: "com.koraybirand.cnc-gcoder.project", conformingTo: .package)
}

/// Enables .cncproj files in the Open panel by extension. Filtering by type
/// alone greys them out whenever Launch Services has not (yet) registered the
/// declared type — the file then carries an anonymous dyn.* type instead.
private final class ProjectOpenPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.hasDirectoryPath || url.pathExtension.lowercased() == ProjectDocument.fileExtension
    }

    /// Folders stay enabled to navigate through, but only a project opens.
    func panel(_ sender: Any, validate url: URL) throws {
        guard url.pathExtension.lowercased() == ProjectDocument.fileExtension else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "Choose a .\(ProjectDocument.fileExtension) project."
            ])
        }
    }
}

/// Project documents: new / open / recent / save, and importing single
/// Gerber or drill files as layers.
extension AppModel {

    private static let recentKey = "recentProjects"
    /// Security-scoped bookmarks, in the same order (the sandbox only lets
    /// the app reopen what it holds a bookmark for).
    private static let recentBookmarksKey = "recentProjectBookmarks"
    private static let recentLimit = 10

    // MARK: - State

    var projectName: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Everything a project file records, as one comparable string.
    private var projectState: String {
        parameters.signature + "||" + detectedFiles.signature + "||" + (projectFolder?.path ?? "")
            + "||" + (chosenOutputDir?.path ?? "") + "||" + customLayers.signature
    }

    /// Unsaved changes worth asking about: an untitled project counts once it
    /// has any input files.
    var isProjectEdited: Bool {
        if projectURL == nil { return manualLayerEdits }
        // manualLayerEdits also flags a linked (version 1) project: saving packs it.
        return manualLayerEdits || projectState != savedProjectState
    }

    private func markSaved() {
        savedProjectState = projectState
        manualLayerEdits = false
    }

    // MARK: - New / open

    func newProject() {
        guard confirmDiscardChanges() else { return }
        layerEditor.end()
        projectURL = nil
        projectFolder = nil
        chosenOutputDir = nil
        layerOrigins = [:]
        customLayers = []
        parameters.drillLayerValues = [:]
        detectedFiles = DetectedFiles()
        preview.clear()
        editor.layerDidChange()
        clearUndoHistory()
        markSaved()
        appendLog("\nNew project.\n")
    }

    /// Open Gerber Folder: an untitled project from an EasyEDA export folder.
    func openGerberFolder() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder exported by EasyEDA (Gerber + drill files)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let useGerberOrigin = askGerberOrigin() else { return }
        projectURL = nil
        setGerberOrigin(useGerberOrigin)
        selectProjectFolder(url)
    }

    // MARK: - Origin of imported Gerbers

    /// Where X0 Y0 goes when the programs are zeroed on the board, in words.
    var zeroedOriginName: String {
        switch parameters.originMode {
        case "bottomRight": "lower-right corner"
        case "topLeft": "upper-left corner"
        case "topRight": "upper-right corner"
        case "center": "centre"
        case "custom": "custom point"
        default: "lower-left corner"
        }
    }

    /// Gerber files carry their own origin — the X0 Y0 of the design in the
    /// PCB editor. True keeps it (no zeroing); false moves X0 Y0 onto the board.
    func setGerberOrigin(_ useGerberOrigin: Bool) {
        guard parameters.zeroStart == useGerberOrigin else { return }
        parameters.zeroStart = !useGerberOrigin
        appendLog(useGerberOrigin
                  ? "\nOrigin: the Gerber files' own X0 Y0 (no zeroing).\n"
                  : "\nOrigin: X0 Y0 at the project's \(zeroedOriginName).\n")
    }

    /// Asks which origin the programs should use. Nil = cancelled.
    private func askGerberOrigin() -> Bool? {
        let alert = NSAlert()
        alert.messageText = "Use the Gerber files' own origin?"
        alert.informativeText = "Gerber files have an origin of their own — the X0 Y0 of the design in the PCB editor. "
            + "Keep it, or move X0 Y0 to the \(zeroedOriginName) of the board so you can touch off there.\n\n"
            + "You can change this later under Machine setup → Origin."
        alert.addButton(withTitle: "Use Gerber Origin")
        alert.addButton(withTitle: "Zero at \(zeroedOriginName.prefix(1).uppercased() + zeroedOriginName.dropFirst())")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    func openProject() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        let filter = ProjectOpenPanelFilter()
        panel.delegate = filter
        // A package is a folder: until Launch Services knows the type it is
        // listed as one, so it must be choosable as a directory too.
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Open a CNC G-Coder project (.\(ProjectDocument.fileExtension))."
        let response = withExtendedLifetime(filter) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return }
        openProject(at: url, confirmed: true)
    }

    func openProject(at url: URL, confirmed: Bool = false) {
        if !confirmed, !confirmDiscardChanges() { return }
        // A recent project resolved from its bookmark: access lasts the session.
        _ = url.startAccessingSecurityScopedResource()
        let document: ProjectDocument
        do {
            document = try ProjectDocument.read(url)
        } catch {
            appendLog("\nERROR opening project \(url.path): \(error.localizedDescription)\n")
            showError("Could not open \(url.lastPathComponent)", error.localizedDescription)
            removeRecent(url)
            return
        }

        // Packed files are unpacked into a fresh working folder; version 1
        // links are looked up where they were.
        let workDir = ProjectDocument.workingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var usedNames = Set<String>()
        var origins: [URL: URL] = [:]
        var files = DetectedFiles()
        var missing: [String] = []
        func take(_ stored: ProjectDocument.StoredFile) -> URL? {
            guard let url = ProjectDocument.materialize(stored, into: workDir, project: url, usedNames: &usedNames) else {
                missing.append(stored.name ?? stored.path)
                return nil
            }
            if ProjectDocument.isPacked(stored) { origins[url] = URL(fileURLWithPath: stored.path) }
            return url
        }
        for slot in LayerSlot.allCases where slot != .drill {
            if let stored = document.layers[slot.rawValue], let file = take(stored) { files[slot] = file }
        }
        // Each drill file's own settings travel with its entry.
        var drillValues: [String: [String: String]] = [:]
        for stored in document.drills {
            guard let file = take(stored) else { continue }
            files.drills.append(file)
            let own = (stored.parameters ?? [:]).filter { ParametersStore.drillLayerKeys.contains($0.key) }
            if !own.isEmpty { drillValues[file.lastPathComponent] = own }
        }
        let packed = document.version >= 3

        layerEditor.end()
        parameters.apply(document.parameters)
        parameters.drillLayerValues = drillValues
        if let x = document.guidesX { UserDefaults.standard.set(x, forKey: "previewGuidesX") }
        if let y = document.guidesY { UserDefaults.standard.set(y, forKey: "previewGuidesY") }
        projectURL = url
        projectFolder = url.deletingLastPathComponent()
        chosenOutputDir = document.outputFolder.map(\.linkedURL)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        layerOrigins = origins
        customLayers = document.customLayers ?? []
        // A drawing-only project opens on the drawing board: the 3D view has
        // no drawing tools, and shows such a project as a bare board.
        if !customLayers.isEmpty, !files.hasAnyToolpathInput {
            UserDefaults.standard.set(false, forKey: "preview3D")
        }
        detectedFiles = files
        preview.clear()
        editor.layerDidChange()
        preview.parametersDidChange()
        clearUndoHistory()
        markSaved()
        noteRecent(url)

        if !customLayers.isEmpty {
            let shapes = customLayers.reduce(0) { $0 + $1.shapes.count }
            appendLog("\nCustom layers: \(customLayers.map(\.name).joined(separator: ", ")) — \(shapes) shape\(shapes == 1 ? "" : "s") (stored in project.json, not in Layers).")
        }
        appendLog("\nOpened project \(url.path)"
                  + (packed ? " — \(origins.count) packed layer file\(origins.count == 1 ? "" : "s").\n"
                            : " (older format; saving converts it to a package with its layer files inside).\n"))
        if !packed { manualLayerEdits = true }
        if !missing.isEmpty {
            appendLog("WARNING: \(missing.count) file\(missing.count == 1 ? "" : "s") not found:\n"
                      + missing.map { "  \($0)\n" }.joined())
            showError("Some layer files could not be restored",
                      missing.joined(separator: "\n") + "\n\nThose layers are empty; use Import Layer… to add the files again.")
        }
    }

    // MARK: - Save

    @discardableResult
    func saveProject() -> Bool {
        guard let projectURL else { return saveProjectAs() }
        return write(to: projectURL)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.cncProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = projectName == "Untitled"
            ? (projectFolder?.lastPathComponent ?? "Untitled") + "." + ProjectDocument.fileExtension
            : projectName + "." + ProjectDocument.fileExtension
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? projectFolder
        panel.message = "Save the project: its layer files and every parameter."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    @discardableResult
    func saveProject(to url: URL) -> Bool { write(to: url) }

    private func write(to url: URL) -> Bool {
        // Every layer file is packed into the project package (Layers/), so
        // it never loses them; project.json holds the rest.
        var document = ProjectDocument()
        document.parameters = parameters.exportValues()
        if let chosenOutputDir { document.outputFolder = ProjectDocument.link(chosenOutputDir) }
        document.guidesX = UserDefaults.standard.string(forKey: "previewGuidesX")
        document.guidesY = UserDefaults.standard.string(forKey: "previewGuidesY")
        document.customLayers = customLayers
        let layers = LayerSlot.allCases.filter { $0 != .drill }.compactMap { slot in
            detectedFiles[slot].map { (slot: slot.rawValue, file: $0, origin: layerOrigins[$0]) }
        }
        let drills = detectedFiles.drills.map { file in
            let own = parameters.drillLayerValues[file.lastPathComponent] ?? [:]
            return (file: file, origin: layerOrigins[file], parameters: own.isEmpty ? nil : own)
        }
        do {
            document = try ProjectDocument.writePackage(document, to: url, layers: layers, drills: drills)
        } catch {
            appendLog("\nERROR saving project: \(error.localizedDescription)\n")
            showError("Could not save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
        projectURL = url
        markSaved()
        noteRecent(url)
        let count = document.layers.count + document.drills.count
        appendLog("\nSaved project \(url.path) — \(count) layer file\(count == 1 ? "" : "s") packed in (Show Package Contents → Layers).\n")
        return true
    }

    /// Asks before unsaved changes are thrown away. True = go ahead.
    func confirmDiscardChanges() -> Bool {
        // A program being streamed comes first: switching projects underneath
        // it would pull the preview away from a moving machine.
        if machine.isStreaming {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A program is being sent to the machine"
            alert.informativeText = "Stop the job before changing the project. Stopping holds the machine, resets the controller and leaves the spindle off."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop Job")
            if alert.runModal() == .alertSecondButtonReturn {
                Task { await machine.streamer.stop() }
            }
            return false
        }
        guard isProjectEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(projectName)?"
        alert.informativeText = "The project's layer files and parameters have changed since it was last saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - Recent projects

    func loadRecentProjects() {
        let defaults = UserDefaults.standard
        if let bookmarks = defaults.array(forKey: Self.recentBookmarksKey) as? [Data] {
            recentProjects = bookmarks.compactMap(FileAccess.resolve)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        } else {
            // Saved before bookmarks: plain paths (usable outside the sandbox).
            recentProjects = (defaults.stringArray(forKey: Self.recentKey) ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func storeRecent() {
        let defaults = UserDefaults.standard
        // Keep the bookmarks already held: a new one can only be made for an
        // item the app has access to right now.
        var known: [String: Data] = [:]
        for data in defaults.array(forKey: Self.recentBookmarksKey) as? [Data] ?? [] {
            if let url = FileAccess.resolve(data) { known[url.standardizedFileURL.path] = data }
        }
        defaults.set(recentProjects.map(\.path), forKey: Self.recentKey)
        defaults.set(recentProjects.compactMap { known[$0.standardizedFileURL.path] ?? FileAccess.bookmark($0) },
                     forKey: Self.recentBookmarksKey)
    }

    private func noteRecent(_ url: URL) {
        var list = recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        recentProjects = Array(list.prefix(Self.recentLimit))
        storeRecent()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func removeRecent(_ url: URL) {
        recentProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        storeRecent()
    }

    func clearRecentProjects() {
        recentProjects = []
        storeRecent()
    }

    // MARK: - Layers

    /// Import Layer…: pick Gerber / drill files from anywhere; their roles are
    /// guessed and confirmed in a sheet (pendingImports).
    func importLayers() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = projectFolder
        panel.message = "Choose Gerber or Excellon drill files to add as layers."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        pendingImports = panel.urls.map { PendingImport(url: $0, slot: GerberDetector.guessSlot(for: $0)) }
    }

    /// Applies the confirmed roles from the import sheet.
    func commitImports(useGerberOrigin: Bool? = nil) {
        if let useGerberOrigin, pendingImports.contains(where: { $0.slot != nil }) {
            setGerberOrigin(useGerberOrigin)
        }
        var files = detectedFiles
        var added: [String] = []
        for item in pendingImports {
            guard let slot = item.slot else { continue }
            if slot == .drill {
                if !files.drills.contains(item.url) { files.drills.append(item.url) }
            } else {
                files[slot] = item.url
            }
            added.append("\(slot.title): \(item.url.lastPathComponent)")
        }
        pendingImports = []
        guard !added.isEmpty else { return }
        layerEditor.end()
        if projectFolder == nil { projectFolder = files.drills.first?.deletingLastPathComponent()
            ?? LayerSlot.allCases.lazy.compactMap { files[$0] }.first?.deletingLastPathComponent() }
        setDetectedFiles(files, actionName: "Import Layers")
        if projectURL == nil { manualLayerEdits = true }
        appendLog("\nImported layers:\n" + added.map { "  \($0)\n" }.joined())
        preview.parametersDidChange()
    }

    /// Replace…: a new file for one layer role.
    func replaceLayer(_ slot: LayerSlot, drill: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.directoryURL = (drill ?? detectedFiles[slot])?.deletingLastPathComponent() ?? projectFolder
        panel.message = "Choose the file for \(slot.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        layerEditor.end()
        var files = detectedFiles
        if let drill, let index = files.drills.firstIndex(of: drill) {
            files.drills[index] = url
            // The replacement keeps the settings made for the file it replaces.
            parameters.renameDrillLayer(drill.lastPathComponent, to: url.lastPathComponent)
        } else {
            files[slot] = url
        }
        if projectFolder == nil { projectFolder = url.deletingLastPathComponent() }
        setDetectedFiles(files, actionName: "Replace Layer")
        if projectURL == nil { manualLayerEdits = true }
        appendLog("\n\(slot.title) → \(url.path)\n")
        preview.parametersDidChange()
    }

    func removeLayer(_ slot: LayerSlot, drill: URL? = nil) {
        layerEditor.end()
        var files = detectedFiles
        if let drill {
            files.drills.removeAll { $0 == drill }
        } else {
            files[slot] = nil
        }
        setDetectedFiles(files, actionName: "Remove Layer")
        if projectURL == nil { manualLayerEdits = true }
        appendLog("\nRemoved \(slot.title)\(drill.map { " (\($0.lastPathComponent))" } ?? "").\n")
        if files.hasAnyToolpathInput || customLayers.hasShapes { preview.parametersDidChange() } else { preview.clear() }
    }

    private func showError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
