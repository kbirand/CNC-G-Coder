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

/// The role an input file plays. Every role holds one file except drills,
/// where each file becomes its own program.
nonisolated enum LayerSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case front, back, outline, topMask, bottomMask, topSilk, bottomSilk, drill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .front: "Top copper"
        case .back: "Bottom copper"
        case .outline: "Board outline"
        case .topMask: "Top mask"
        case .bottomMask: "Bottom mask"
        case .topSilk: "Top silkscreen"
        case .bottomSilk: "Bottom silkscreen"
        case .drill: "Drill"
        }
    }
}

extension DetectedFiles {
    /// The file in a single-file role (nil for .drill, which holds a list).
    subscript(slot: LayerSlot) -> URL? {
        get {
            switch slot {
            case .front: front
            case .back: back
            case .outline: outline
            case .topMask: topMask
            case .bottomMask: bottomMask
            case .topSilk: topSilk
            case .bottomSilk: bottomSilk
            case .drill: nil
            }
        }
        set {
            switch slot {
            case .front: front = newValue
            case .back: back = newValue
            case .outline: outline = newValue
            case .topMask: topMask = newValue
            case .bottomMask: bottomMask = newValue
            case .topSilk: topSilk = newValue
            case .bottomSilk: bottomSilk = newValue
            case .drill: if let newValue, !drills.contains(newValue) { drills.append(newValue) }
            }
        }
    }
}
