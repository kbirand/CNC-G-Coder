import Foundation
import CoreGraphics

/// One G-code output file's role.
nonisolated enum LayerKind: Hashable, Sendable, Comparable {
    case front
    case back
    case outline
    case drill(index: Int, name: String)
    /// Holes too large for any bit on hand, milled as helices (same drill file).
    case millDrill(index: Int, name: String)
    case maskTop
    case maskBottom
    case silkTop
    case silkBottom
    /// A layer drawn by hand in the shape editor (see CustomLayer).
    case custom(CustomLayerRef)
    case test

    var displayName: String {
        switch self {
        case .front: String(localized: "Front copper")
        case .back: String(localized: "Back copper")
        case .outline: String(localized: "Outline")
        case .drill(_, let name): name
        case .millDrill(_, let name): name + " milled"
        case .maskTop: String(localized: "Top mask etch")
        case .maskBottom: String(localized: "Bottom mask etch")
        case .silkTop: String(localized: "Top silkscreen")
        case .silkBottom: String(localized: "Bottom silkscreen")
        case .custom(let ref): ref.name
        case .test: String(localized: "Test board")
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The drawn layer behind a `.custom` kind.
    var customRef: CustomLayerRef? {
        if case .custom(let ref) = self { return ref }
        return nil
    }

    var isDrill: Bool {
        if case .drill = self { return true }
        return false
    }

    /// The drill file (its position in the project's list) behind a drill
    /// program or its milled holes.
    var drillIndex: Int? {
        switch self {
        case .drill(let index, _), .millDrill(let index, _): index
        default: nil
        }
    }

    /// The same drill file's other program: drilled ↔ milled holes.
    var drillSibling: LayerKind? {
        switch self {
        case .drill(let index, let name): .millDrill(index: index, name: name)
        case .millDrill(let index, let name): .drill(index: index, name: name)
        default: nil
        }
    }

    var isMask: Bool {
        self == .maskTop || self == .maskBottom
    }

    var isSilk: Bool {
        self == .silkTop || self == .silkBottom
    }

    /// Filename stem for everything this layer produces — the generated
    /// program and its laser artwork — so both folders read the same way:
    /// "front-copper.ngc" next to "front-copper_white-on-black.svg".
    var fileSlug: String {
        displayName.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    private var rank: Int {
        switch self {
        case .front: 0
        case .back: 1
        case .outline: 2
        case .drill(let index, _): 3 + 2 * index
        case .millDrill(let index, _): 4 + 2 * index   // right after its drill program
        case .maskTop: 1000       // mask etching happens late in the workflow
        case .maskBottom: 1001
        case .silkTop: 1100       // legend last of all, on top of the cured mask
        case .silkBottom: 1101
        case .custom(let ref): 1500 + ref.index   // drawn layers, in their list order
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

/// One drilled hole of a drill program: where, how wide (the bit announced
/// by the tool-change comment before its section), how deep, and which
/// plunge moves make it (peck drilling plunges the same hole several times).
nonisolated struct DrillHole: Sendable {
    var center: CGPoint
    /// Bit diameter, mm.
    var diameter: Double
    /// Positive mm below Z0: the deepest plunge at this XY.
    var depth: Double
    /// Index (into `ParsedLayer.moves`) of the first plunge into this hole.
    var moveIndex: Int
    /// Index of the last plunge into it.
    var lastMoveIndex: Int
}

/// Parsed content of one generated .ngc file.
nonisolated struct ParsedLayer: Identifiable, Sendable {
    let id: LayerKind
    let fileURL: URL
    var toolDiameter: Double?
    var moves: [ToolpathMove] = []
    var drillHits: [CGPoint] = []
    /// The holes of a drill program (`drillHits` with bit size, depth and
    /// the plunge moves), for the 3D view.
    var drillHoles: [DrillHole] = []
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
    /// Where X0/Y0 was put when origins were normalized (zeroing on). nil =
    /// raw pcb2gcode frames (zeroing off, or externally loaded G-code).
    var frame: ProjectFrame? = nil
    var projectSize: CGSize? { frame?.rect.size }
    /// The mirror settings these programs were generated with. Views must use
    /// THESE, not the live parameters: editing the mirror axis re-renders the
    /// canvas long before pcb2gcode has produced matching geometry, and
    /// pairing a new axis with old coordinates throws the back side across
    /// the canvas until the run finishes.
    var mirrorAxis: Double = 0
    var mirrorYAxis: Bool = false
}

/// How the programs were zeroed. Every program shares one origin per board
/// side; the back side's programs are mirrored, so its origin is given in its
/// own (mirrored) view.
nonisolated struct ProjectFrame: Sendable, Equatable {
    /// Extent of all programs in the design (Gerber) frame, front side.
    var rect: CGRect
    /// X0/Y0 of the front programs, from the project's lower-left corner.
    var frontOrigin: CGPoint
    /// X0/Y0 of the back programs, from the lower-left corner of the project
    /// as the machine sees it after the flip.
    var backOrigin: CGPoint
    var mirrorYAxis: Bool

    /// Maps back-side program coordinates onto the front programs' frame —
    /// the display-only "un-mirror" that overlays the two sides.
    var backToFront: CGAffineTransform {
        let w = rect.width, h = rect.height
        let fo = frontOrigin, bo = backOrigin
        if mirrorYAxis {
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: bo.x - fo.x, ty: h - bo.y - fo.y)
        }
        return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w - bo.x - fo.x, ty: bo.y - fo.y)
    }

    /// A front-program point in design (Gerber) coordinates.
    func designPoint(fromFront point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + rect.minX + frontOrigin.x, y: point.y + rect.minY + frontOrigin.y)
    }

    /// Design (Gerber) coordinates → front-program coordinates.
    var designToFront: CGAffineTransform {
        CGAffineTransform(translationX: -(rect.minX + frontOrigin.x), y: -(rect.minY + frontOrigin.y))
    }

    /// Design (Gerber) coordinates → back-program coordinates: the mirror
    /// pcb2gcode applies, followed by the back side's own zeroing shift
    /// (see Pcb2GcodeService.normalizeOrigins — the axis value cancels out).
    var designToBack: CGAffineTransform {
        if mirrorYAxis {
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                     tx: -(rect.minX + backOrigin.x), ty: rect.maxY - backOrigin.y)
        }
        return CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                 tx: rect.maxX - backOrigin.x, ty: -(rect.minY + backOrigin.y))
    }
}

extension PreviewDocument {
    /// Back-side coordinates → front-side coordinates, for overlaying.
    var backToFront: CGAffineTransform {
        if let frame { return frame.backToFront }
        let axis = CGFloat(mirrorAxis)
        return mirrorYAxis
            ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * axis)
            : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * axis, ty: 0)
    }

    /// A front-program point in design (Gerber) coordinates.
    func designPoint(fromFront point: CGPoint) -> CGPoint {
        frame?.designPoint(fromFront: point) ?? point
    }
}

extension LayerKind {
    /// Programs machined after flipping the board (mirrored coordinates).
    nonisolated var isBackSide: Bool {
        if case .custom(let ref) = self { return ref.back }
        return self == .back || self == .maskBottom || self == .silkBottom
    }
}
