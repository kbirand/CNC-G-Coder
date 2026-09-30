import Foundation

/// A saved project. Since version 3 a .cncproj is a PACKAGE — a folder that
/// Finder shows as one file (right-click → Show Package Contents):
///
///     Board.cncproj/
///       project.json      parameters, layer roles, where each file came from
///       Layers/           the Gerber and drill files themselves, unchanged
///
/// Being self-contained, a project can be moved or copied without losing its
/// Gerbers; on open the files are copied into a private working folder, so
/// the package is never read from while it may be rewritten.
///
/// Older projects still open: version 2 was a single JSON file with the files
/// embedded (base64), version 1 a single JSON file with links. Both become a
/// package on their next save.
nonisolated struct ProjectDocument: Codable, Sendable {
    static let fileExtension = "cncproj"
    static let manifestName = "project.json"
    static let layersFolder = "Layers"

    /// One layer file, and where it originally came from.
    struct StoredFile: Codable, Sendable {
        /// File name, kept so programs and the layer list read the same.
        var name: String?
        /// Version 3: the file inside the package, e.g. "Layers/Gerber_TopLayer.GTL".
        var file: String?
        /// Version 2: the file itself, embedded (base64 in the JSON).
        var contents: Data?
        /// Where the file was when it was saved (version 1: the link).
        var path: String
        /// Version 1 only: the link relative to the project file.
        var relativePath: String?
    }

    var format = "cnc-gcoder-project"
    var version = 3
    /// Single-file layers, keyed by LayerSlot raw value.
    var layers: [String: StoredFile] = [:]
    var drills: [StoredFile] = []
    /// Every parameter, as preset keys (ParametersStore.exportValues()).
    var parameters: [String: String] = [:]
    /// Output folder chosen at Generate time (a link — output is not packed).
    var outputFolder: StoredFile?
    var guidesX: String?
    var guidesY: String?
    /// Hand-drawn layers from the shape editor (absent in older projects).
    var customLayers: [CustomLayer]?

    static func link(_ url: URL) -> StoredFile {
        StoredFile(name: url.lastPathComponent, path: url.path)
    }

    /// `name`, or "name 2", "name 3"… if already taken (case-insensitive).
    static func uniqueName(_ base: String, used: inout Set<String>) -> String {
        var name = base
        var n = 2
        while used.contains(name.lowercased()) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }

    // MARK: - Reading

    /// Reads a project: the manifest inside a package, or an older single file.
    static func read(_ url: URL) throws -> ProjectDocument {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let json = isDirectory.boolValue ? url.appendingPathComponent(manifestName) : url
        return try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: json))
    }

    /// Makes a stored file available on disk in `folder` (under its own name,
    /// made unique): copied out of the package, written from embedded
    /// contents, or — version 1 — found through its link.
    static func materialize(_ file: StoredFile, into folder: URL, project: URL,
                            usedNames: inout Set<String>) -> URL? {
        let fm = FileManager.default
        let base = file.name ?? URL(fileURLWithPath: file.path).lastPathComponent
        if let inner = file.file {
            let source = project.appendingPathComponent(inner)
            guard fm.fileExists(atPath: source.path) else { return nil }
            let target = folder.appendingPathComponent(uniqueName(base, used: &usedNames))
            return (try? fm.copyItem(at: source, to: target)) != nil ? target : nil
        }
        if let contents = file.contents {
            let target = folder.appendingPathComponent(uniqueName(base, used: &usedNames))
            return (try? contents.write(to: target, options: .atomic)) != nil ? target : nil
        }
        if let relative = file.relativePath {
            let url = URL(fileURLWithPath: relative, relativeTo: project.deletingLastPathComponent()).standardizedFileURL
            if fm.fileExists(atPath: url.path) { return url }
        }
        let url = URL(fileURLWithPath: file.path)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// True when the stored file lives inside the project (not a link).
    static func isPacked(_ file: StoredFile) -> Bool {
        file.file != nil || file.contents != nil
    }

    // MARK: - Writing

    /// Builds the package in a staging folder next to `url`, then swaps it in,
    /// so a failed save never leaves a half-written project behind.
    /// `layers`/`drills` are the files to pack, with their original locations.
    static func writePackage(_ document: ProjectDocument, to url: URL,
                             layers: [(slot: String, file: URL, origin: URL?)],
                             drills: [(file: URL, origin: URL?)]) throws -> ProjectDocument {
        let fm = FileManager.default
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).saving-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let layerDir = staging.appendingPathComponent(layersFolder, isDirectory: true)
        try fm.createDirectory(at: layerDir, withIntermediateDirectories: true)

        var document = document
        var used = Set<String>()
        func pack(_ file: URL, origin: URL?) throws -> StoredFile {
            let name = uniqueName(file.lastPathComponent, used: &used)
            try fm.copyItem(at: file, to: layerDir.appendingPathComponent(name))
            return StoredFile(name: name, file: "\(layersFolder)/\(name)", path: (origin ?? file).path)
        }
        document.layers = [:]
        for layer in layers { document.layers[layer.slot] = try pack(layer.file, origin: layer.origin) }
        document.drills = try drills.map { try pack($0.file, origin: $0.origin) }
        document.version = 3

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: staging.appendingPathComponent(manifestName), options: .atomic)

        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: staging)
            } catch {
                // replaceItemAt refuses to swap a single-file (older) project for
                // a package; the staging copy is complete, so replace by hand.
                try fm.removeItem(at: url)
                try fm.moveItem(at: staging, to: url)
            }
        } else {
            try fm.moveItem(at: staging, to: url)
        }
        return document
    }

    /// Where an opened project's files are copied to; cleared at launch.
    static var workingRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CNCGCoderProjects", isDirectory: true)
    }
}
