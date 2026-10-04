import Foundation
import CryptoKit

/// App Sandbox file access. The app may read and write what the user picked
/// in an open or save panel — for this session. To come back to it after a
/// relaunch (recent projects, the output folder) it keeps a security-scoped
/// bookmark; and since pcb2gcode, a child process, only inherits the app's
/// static sandbox (not the folders granted later), its input files are copied
/// into the app's own temporary space first.
nonisolated enum FileAccess {

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Bookmarks

    /// A bookmark that restores access to `url` after a relaunch.
    static func bookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData())
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: [Data: URL] = [:]

    /// The bookmarked item, with access started (once per bookmark, held for
    /// the rest of the session). Nil when it no longer exists.
    static func resolve(_ bookmark: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let url = resolved[bookmark] { return url }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        resolved[bookmark] = url
        return url
    }

    /// Whether files can be written into `folder` (created if missing).
    static func canWrite(into folder: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
            return true
        }
        return fm.isWritableFile(atPath: folder.path)
    }

    // MARK: - Helper processes

    /// A copy of `url` the helper process may read: in the app's temporary
    /// space, at a path named after its contents, so the same file always
    /// lands at the same path (job caching keys on the path). Outside the
    /// sandbox, and on failure, the file itself.
    static func helperReadable(_ url: URL) -> URL {
        guard isSandboxed, !url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
              let data = FileManager.default.contents(atPath: url.path) else { return url }
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let dir = PreviewPaths.root.appendingPathComponent("inputs/\(digest)", isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return url }
        }
        return copy
    }

    /// Every input file, as copies the helper process may read.
    static func helperReadable(_ files: DetectedFiles) -> DetectedFiles {
        guard isSandboxed else { return files }
        var out = files
        for slot in LayerSlot.allCases where slot != .drill {
            out[slot] = files[slot].map(helperReadable)
        }
        out.drills = files.drills.map(helperReadable)
        return out
    }
}
