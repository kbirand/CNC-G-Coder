import Foundation

/// Files auto-detected in the selected EasyEDA gerber export folder.
nonisolated struct DetectedFiles: Equatable, Sendable {
    var front: URL?
    var back: URL?
    var outline: URL?
    var topMask: URL?
    var bottomMask: URL?
    var topSilk: URL?
    var bottomSilk: URL?
    var drills: [URL] = []

    var hasAnyToolpathInput: Bool {
        front != nil || back != nil || outline != nil || !drills.isEmpty
    }

    var hasAnything: Bool {
        hasAnyToolpathInput || topMask != nil || bottomMask != nil || topSilk != nil || bottomSilk != nil
    }

    /// Stable identity of the input set; part of the preview staleness signature.
    var signature: String {
        ([front, back, outline, topMask, bottomMask, topSilk, bottomSilk].map { $0?.path ?? "-" } + drills.map(\.path))
            .joined(separator: ",")
    }
}
