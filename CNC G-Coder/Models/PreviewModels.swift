import Foundation
import CoreGraphics

/// One G-code output file's role.
nonisolated enum LayerKind: Hashable, Sendable, Comparable {
    case front
    case back
    case outline
    case drill(index: Int, name: String)
    case maskTop
    case maskBottom
    case test

    var displayName: String {
        switch self {
        case .front: "Front copper"
        case .back: "Back copper"
        case .outline: "Outline"
        case .drill(_, let name): name
        case .maskTop: "Top mask etch"
        case .maskBottom: "Bottom mask etch"
        case .test: "Test board"
        }
    }

    var isDrill: Bool {
        if case .drill = self { return true }
        return false
    }

    var isMask: Bool {
        self == .maskTop || self == .maskBottom
    }

    private var rank: Int {
        switch self {
        case .front: 0
        case .back: 1
        case .outline: 2
        case .drill(let index, _): 3 + index
        case .maskTop: 1000       // mask etching happens last in the workflow
        case .maskBottom: 1001
        case .test: 2000
        }
    }

    static func < (lhs: LayerKind, rhs: LayerKind) -> Bool { lhs.rank < rhs.rank }
}

nonisolated enum MoveKind: Sendable {
    case rapid   // G0, or any travel at/above the board surface
    case cut     // moving below Z0
    case plunge  // vertical-only descent below Z0 (drill strokes, cut entries)
}

/// One machine motion, in program order. Units: mm, G-code coordinates (Y up).
nonisolated struct ToolpathMove: Sendable {
    var start: CGPoint
    var end: CGPoint
    var zStart: Double
    var zEnd: Double
    var kind: MoveKind
    var feed: Double?             // mm/min (nil for rapids)
    var sourceLine: Int           // 1-based line number in the .ngc file
    var cumulativeTime: Double    // estimated seconds elapsed at end of this move
    var cumulativeDistance: Double // mm of 3D travel at end of this move
}

/// Parsed content of one generated .ngc file.
nonisolated struct ParsedLayer: Identifiable, Sendable {
    let id: LayerKind
    let fileURL: URL
    var toolDiameter: Double?
    var moves: [ToolpathMove] = []
    var drillHits: [CGPoint] = []
    var cutBounds: CGRect?
    var allBounds: CGRect?
    var zMin: Double = 0
    var zMax: Double = 0
    var totalTime: Double = 0
    var totalDistance: Double = 0
    var lineCount: Int = 0

    var displayName: String { id.displayName }
}

/// A file produced by a pcb2gcode batch.
nonisolated struct GeneratedOutput: Sendable {
    let layer: LayerKind
    let url: URL
    /// Cutter diameter (mm) used for this program; nil when unknown (drills).
    var toolDiameter: Double?
}

/// One complete, parsed preview generation.
nonisolated struct PreviewDocument: Sendable {
    var layers: [ParsedLayer]
    var bounds: CGRect        // union of cut bounds (fallback: all bounds), mm
    var tempDir: URL
    var token: UUID           // identity for view-side caches
    /// Project extent (mm) when origins were normalized (zeroing on): every
    /// program shares one origin per side and the back frame is the mirror
    /// image of the front frame across this rectangle. nil = raw pcb2gcode
    /// frames (zeroing off, or externally loaded G-code).
    var projectSize: CGSize? = nil
}
