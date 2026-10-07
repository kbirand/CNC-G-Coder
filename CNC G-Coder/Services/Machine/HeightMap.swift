import Foundation
import CoreGraphics
import CryptoKit

// Height map (autolevel): a grid of probed surface heights over the board,
// used to warp a program's Z so the etch depth stays even on a board that is
// not flat. Candle's algorithm, kept bilinear: the bicubic variant was
// deliberately not ported.

/// Which side of the board a program is machined on. The board is flipped
/// and re-clamped between the sides, so a map probed on one side says
/// nothing about the other — a map is only ever applied to programs of its
/// own side.
nonisolated enum BoardSide: String, Codable, Sendable, CaseIterable {
    case front, back

    var title: String {
        switch self {
        case .front: "Front"
        case .back: "Back"
        }
    }
}

extension LayerKind {
    /// The side a program of this kind is cut on.
    nonisolated var boardSide: BoardSide { isBackSide ? .back : .front }
}

/// Why a program could not be warped (`HeightMap.apply`). `line` is 1-based;
/// 0 when the problem is the map rather than a program line.
nonisolated struct HeightMapError: LocalizedError {
    var line: Int
    var reason: String

    var errorDescription: String? { line > 0 ? "line \(line): \(reason)" : reason }
}

/// A probed height grid anchored to the board: `origin`/`size` are in
/// **design (Gerber) coordinates**, like drawn layers, so the map stays on
/// the board whatever "X0 Y0 at" the project uses. A frame transform
/// `T` (design → that side's program/work frame; `AppModel.heightMapFrame`,
/// identity with zeroing off or for an external program) converts at the
/// edges: the probe program emits `p.applying(T)`, `apply` maps each
/// program XY through `T.inverted()`, the overlays draw through `T`.
///
/// `points[row][col]` holds the surface height at `gridPoint(row:col:)`
/// **relative to `referenceZ`**, the machine Z first probed at work X0/Y0
/// (the design point `(0,0).applying(T.inverted())`). Storing the grid
/// relative to that one spot keeps the map valid after Z is re-zeroed there
/// following a tool change (the usual workflow: probe Z on the copper at
/// the origin, run). A moved work origin — the board moved, or X0/Y0 put
/// elsewhere on it without re-zeroing there — shows up in
/// `validity(currentDesignOrigin:programSide:)` through
/// `probedDesignOrigin`, the machine coordinates of design (0,0) at probe
/// time.
nonisolated struct HeightMap: Codable, Equatable, Sendable {
    /// File format: 2 = design coordinates. Files without a version (1,
    /// work coordinates) are not loaded.
    static let currentVersion = 2
    var version: Int = HeightMap.currentVersion
    /// Design XY of grid point (row 0, col 0).
    var origin: CGPoint
    /// Extent of the grid rectangle in mm; the last column/row sits on its
    /// far edge.
    var size: CGSize
    var nx: Int
    var ny: Int
    /// Work Z the probe travels at between points.
    var zClear: Double = 1
    /// Absolute work Z the probe heads for; no contact by then is a failure.
    var zMaxDepth: Double = -2
    var feedFast: Double = 100
    var feedSlow: Double = 20
    /// `[row][col]`, `ny` rows of `nx`; nil until probed. Relative to
    /// `referenceZ`.
    var points: [[Double?]]
    /// Machine Z of the reference probe at work X0/Y0; nil until probed.
    var referenceZ: Double?
    /// Machine coordinates of design (0,0) when the map was probed: XY =
    /// `(0,0).applying(T) + WCO`, Z = the work offset's Z. The same point
    /// now (`validity`) means the board and the work zero are where they were.
    var probedDesignOrigin: MachinePosition?
    var probedAt: Date?
    var side: BoardSide
    var firmwareVersion: String?

    init(origin: CGPoint, size: CGSize, nx: Int, ny: Int, side: BoardSide) {
        self.origin = origin
        self.size = size
        self.nx = max(2, nx)
        self.ny = max(2, ny)
        self.side = side
        self.points = Self.emptyPoints(nx: self.nx, ny: self.ny)
    }

    /// Smallest and largest grid the UI offers (a 15×15 map is 225 probes).
    static let countRange = 2...15

    // MARK: - Geometry

    var stepX: Double { size.width / Double(max(nx, 2) - 1) }
    var stepY: Double { size.height / Double(max(ny, 2) - 1) }
    var totalCount: Int { nx * ny }
    var rect: CGRect { CGRect(origin: origin, size: size) }

    func gridPoint(row: Int, col: Int) -> CGPoint {
        CGPoint(x: origin.x + Double(col) * stepX, y: origin.y + Double(row) * stepY)
    }

    /// A grid over `bounds` (a program's cut bounds, in DESIGN coordinates —
    /// convert a program's bounds through `T.inverted()`) plus `margin`,
    /// with points about `targetPitch` apart, 2…15 per axis.
    static func auto(for bounds: CGRect, side: BoardSide, margin: Double = 1, targetPitch: Double = 10) -> HeightMap {
        let base = bounds.isNull || bounds.isInfinite ? CGRect(x: 0, y: 0, width: 20, height: 20) : bounds.standardized
        let r = base.insetBy(dx: -max(margin, 0), dy: -max(margin, 0))
        func count(_ length: Double) -> Int {
            let cells = (length / max(targetPitch, 0.1)).rounded()
            return min(countRange.upperBound, max(countRange.lowerBound, Int(cells) + 1))
        }
        return HeightMap(origin: r.origin, size: r.size, nx: count(r.width), ny: count(r.height), side: side)
    }

    // MARK: - Points

    private static func emptyPoints(nx: Int, ny: Int) -> [[Double?]] {
        Array(repeating: Array(repeating: nil, count: nx), count: ny)
    }

    /// Whether `points` is the `ny` × `nx` table the grid describes (the
    /// counts can be edited after the map was probed, or loaded from a file).
    private var hasValidShape: Bool {
        nx >= 2 && ny >= 2 && points.count == ny && points.allSatisfy { $0.count == nx }
    }

    /// Forgets every probed value (also after changing `nx`/`ny`).
    mutating func clear() {
        nx = max(2, nx)
        ny = max(2, ny)
        points = Self.emptyPoints(nx: nx, ny: ny)
        referenceZ = nil
        probedDesignOrigin = nil
        probedAt = nil
        firmwareVersion = nil
    }

    var probedCount: Int {
        points.reduce(0) { $0 + $1.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    }

    var isComplete: Bool {
        hasValidShape && referenceZ != nil && points.allSatisfy { $0.allSatisfy { $0 != nil } }
    }

    /// Max − min over the probed points; nil before the first point.
    var maxDeviation: Double? {
        let values = points.flatMap { $0.compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return hi - lo
    }

    // MARK: - Probing

    /// Serpentine, row-major: row 0 left to right, row 1 right to left, …
    /// so the probe never crosses the whole board between points.
    func probeOrder() -> [(row: Int, col: Int)] {
        var order: [(row: Int, col: Int)] = []
        order.reserveCapacity(nx * ny)
        for row in 0..<ny {
            let cols = row.isMultiple(of: 2) ? Array(0..<nx) : Array((0..<nx).reversed())
            for col in cols { order.append((row, col)) }
        }
        return order
    }

    /// The probe program in work coordinates (`frame` = design → work):
    /// `G21 G90`, up to `zClear`, to the reference at work X0/Y0, probe,
    /// then every grid point in `probeOrder()`: rapid to it at `zClear`,
    /// `G38.2` down to `zMaxDepth` at `feedSlow`, back up. Each `G38.2` line
    /// maps to its probe index through `probeIndex(forProgramLine:)` (−1 =
    /// reference).
    func probeProgram(frame: CGAffineTransform) -> [String] { build(frame: frame).lines }

    /// The probe index of a `G38.2` line of `probeProgram(frame:)` (0-based
    /// line index), nil for any other line. The layout does not depend on
    /// the frame.
    func probeIndex(forProgramLine line: Int) -> Int? { build(frame: .identity).probes[line] }

    private func build(frame: CGAffineTransform) -> (lines: [String], probes: [Int: Int]) {
        let clear = "G0 Z" + GRBLCommand.number(zClear)
        let probe = "G38.2 Z" + GRBLCommand.number(zMaxDepth) + " " + GRBLCommand.feedWord(feedSlow)
        var lines = ["G21 G90", clear, "G0 X0.000 Y0.000"]
        var probes: [Int: Int] = [:]
        probes[lines.count] = -1
        lines.append(probe)
        lines.append(clear)
        for (index, p) in probeOrder().enumerated() {
            let point = gridPoint(row: p.row, col: p.col).applying(frame)
            lines.append("G0 X" + GRBLCommand.number(point.x) + " Y" + GRBLCommand.number(point.y))
            probes[lines.count] = index
            lines.append(probe)
            lines.append(clear)
        }
        return (lines, probes)
    }

    /// Stores a probe result: index −1 is the reference at work X0/Y0 and
    /// sets `referenceZ`; any other index stores `machineZ − referenceZ` at
    /// `probeOrder()[index]`. Points probed before the reference are dropped
    /// (nothing to relate them to).
    mutating func record(probeIndex: Int, machineZ: Double) {
        if probeIndex < 0 {
            referenceZ = machineZ
            if probedAt == nil { probedAt = Date() }
            return
        }
        guard let referenceZ else { return }
        let order = probeOrder()
        guard order.indices.contains(probeIndex) else { return }
        if !hasValidShape {
            nx = max(2, nx)
            ny = max(2, ny)
            points = Self.emptyPoints(nx: nx, ny: ny)
        }
        let p = order[probeIndex]
        points[p.row][p.col] = machineZ - referenceZ
    }

    // MARK: - Interpolation

    /// Bilinear interpolation of the surface offset at design (x, y). Outside
    /// the grid the point is clamped onto its edge, so the offset continues
    /// flat beyond the probed rectangle instead of being extrapolated. 0
    /// until the map is complete.
    func interpolate(x: Double, y: Double) -> Double {
        guard isComplete else { return 0 }
        func cell(_ v: Double, _ o: Double, _ step: Double, _ n: Int) -> (index: Int, t: Double) {
            guard step > 0, v.isFinite else { return (0, 0) }
            let u = min(max((v - o) / step, 0), Double(n - 1))
            let i = min(Int(u.rounded(.down)), n - 2)
            return (i, u - Double(i))
        }
        let c = cell(x, origin.x, stepX, nx)
        let r = cell(y, origin.y, stepY, ny)
        let z00 = points[r.index][c.index] ?? 0
        let z01 = points[r.index][c.index + 1] ?? 0
        let z10 = points[r.index + 1][c.index] ?? 0
        let z11 = points[r.index + 1][c.index + 1] ?? 0
        let bottom = z00 * (1 - c.t) + z01 * c.t
        let top = z10 * (1 - c.t) + z11 * c.t
        return bottom * (1 - r.t) + top * r.t
    }

    // MARK: - Validity

    enum Issue: Equatable, Sendable {
        /// The map was probed on the other side of the board: never apply.
        case sideMismatch
        /// The machine's current work offset is not known yet.
        case wcoUnknown
        /// The map does not record where the board was when it was probed.
        case originUnknown
        /// The work origin moved on the board since probing (the board
        /// moved, or X0/Y0 was put elsewhere without re-zeroing there).
        case xyMoved(dx: Double, dy: Double)
        /// Z was re-zeroed since probing (a new bit, or a different spot).
        case zRezeroed(dz: Double)
        case incomplete
    }

    /// Everything that speaks against applying the map now; empty when it
    /// matches the program side and the board sits where it was probed.
    /// `currentDesignOrigin` is the machine position of design (0,0) now
    /// (`MachineController.currentDesignOrigin(side:)`).
    func validity(currentDesignOrigin: MachinePosition?, programSide: BoardSide) -> [Issue] {
        var issues: [Issue] = []
        if side != programSide { issues.append(.sideMismatch) }
        if !isComplete { issues.append(.incomplete) }
        guard let probedDesignOrigin else { return issues + [.originUnknown] }
        guard let currentDesignOrigin else { return issues + [.wcoUnknown] }
        // GRBL reports offsets to 0.001 mm. The board must sit where the grid
        // was probed; Z gets the repeatability of a touch-off (a re-probe at
        // the same spot lands within a few hundredths).
        let xyTolerance = 0.01
        let zTolerance = 0.03
        let dx = currentDesignOrigin.x - probedDesignOrigin.x
        let dy = currentDesignOrigin.y - probedDesignOrigin.y
        let dz = currentDesignOrigin.z - probedDesignOrigin.z
        if abs(dx) > xyTolerance || abs(dy) > xyTolerance { issues.append(.xyMoved(dx: dx, dy: dy)) }
        if abs(dz) > zTolerance { issues.append(.zRezeroed(dz: dz)) }
        return issues
    }

    // MARK: - Applying to a program

    /// Chord limits for arcs: 1° or 0.1 mm, whichever needs fewer chords (a
    /// 1° chord on a Ø1 mm drill helix would be 0.009 mm long; 0.1 mm chords
    /// keep the sagitta under 0.003 mm there, 1° chords do on large arcs).
    private static let chordAngle = Double.pi / 180
    private static let chordLength = 0.1

    /// Warps an absolute metric G0/G1/G2/G3 program (work coordinates) by
    /// the map; `frame` maps design → the program's frame, so every XY is
    /// taken through its inverse before interpolating.
    ///
    /// Every move whose end Z is at or below `applyBelowZ` gets the surface
    /// offset added to its Z, with its XY projection subdivided at the grid
    /// cell borders (where the bilinear surface creases) and into pieces no
    /// longer than half a cell. The motion word is preserved — G0 pieces stay
    /// rapids, a Z-only rapid becomes a single `G0 Z` — so a plunge clearance
    /// rapid is never turned into a feed move; `F` stays on the first piece
    /// of its line; arcs become G1 chords (the one mode change). Comments,
    /// blank lines and lines without axis words are copied verbatim, and a
    /// move whose Z is above the threshold (safe-height rapids) is untouched.
    /// The warp adds words only to lines that already move, so a feed move is
    /// never emitted before the program's first `F`.
    ///
    /// Throws for programs the warp cannot follow: G91, G20, G18/G19, G53,
    /// G28/G30, G92, canned cycles, G90.1, radius-format arcs, and lines
    /// that set an offset or probe (G10, G28.1/G30.1, G43/G43.1/G49, G38.x)
    /// — their axis words are not a move the surface could be added to.
    func apply(to text: String, applyBelowZ: Double, frame: CGAffineTransform = .identity) throws -> String {
        guard isComplete else { throw HeightMapError(line: 0, reason: "the height map is not complete") }
        let eps = 1e-9
        let maxPiece = max(min(stepX, stepY) / 2, 0.05)
        let toDesign = frame.inverted()
        func offset(_ px: Double, _ py: Double) -> Double {
            let d = CGPoint(x: px, y: py).applying(toDesign)
            return interpolate(x: d.x, y: d.y)
        }
        var out: [String] = []
        var mode = 0                     // modal motion G0–G3
        var x: Double?, y: Double?, z: Double?

        for (index, sub) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(sub)
            let chars = Array(line)
            let (words, comments) = Self.scan(chars)
            func fail(_ reason: String) -> HeightMapError { HeightMapError(line: index + 1, reason: reason) }

            var explicitMotion: Word?
            for w in words where w.letter == "G" {
                switch w.value {
                case 0, 1, 2, 3: mode = Int(w.value); explicitMotion = w
                case 91: throw fail("incremental coordinates (G91)")
                case 20: throw fail("inch units (G20)")
                case 18, 19: throw fail("arcs outside the XY plane (G\(Int(w.value)))")
                case 28, 30, 53, 92: throw fail("G\(Int(w.value)) moves to or redefines a position the program does not state")
                case 10, 28.1, 30.1, 43, 43.1, 49, 38.2, 38.3, 38.4, 38.5:
                    let name = w.value == w.value.rounded() ? "G\(Int(w.value))" : "G\(w.value)"
                    throw fail("\(name) sets an offset or probes")
                case 81...89: throw fail("canned drilling cycles (G8x)")
                case 90.1: throw fail("absolute arc centres (G90.1)")
                default: break
                }
            }
            func word(_ letter: Character) -> Word? { words.last { $0.letter == letter } }
            let xw = word("X"), yw = word("Y"), zw = word("Z")
            let iw = word("I"), jw = word("J")
            let isArc = mode >= 2
            if isArc, word("R") != nil { throw fail("radius-format arcs (R)") }
            let hasXY = xw != nil || yw != nil || (isArc && (iw != nil || jw != nil))
            guard hasXY || zw != nil else {
                out.append(line)
                continue
            }

            let tx = xw?.value ?? x, ty = yw?.value ?? y, tz = zw?.value ?? z
            defer { x = tx; y = ty; z = tz }
            // Above the threshold (or Z not yet known): untouched.
            guard let tz, tz <= applyBelowZ + eps else {
                out.append(line)
                continue
            }
            func motionText(_ replacing: String?) -> String {
                replacing ?? explicitMotion.map { String(chars[$0.start..<$0.end]) } ?? "G\(mode)"
            }
            func piece(_ px: Double, _ py: Double, _ pz: Double, motion: String) -> String {
                "\(motion) X\(Self.format(px)) Y\(Self.format(py)) Z\(Self.format(pz + offset(px, py)))"
            }

            // Z-only move: one line at the warped height.
            if !hasXY {
                let pz = tz + offset(tx ?? 0, ty ?? 0)
                out.append(contentsOf: Self.rebuild(chars, words: words, coordinates: "Z" + Self.format(pz),
                                                    motion: nil, comments: comments))
                continue
            }

            // The XY polyline to emit, excluding the start, with programmed Z.
            var polyline: [(x: Double, y: Double, z: Double)] = []
            let sz = z ?? tz
            if !isArc {
                let ex = tx ?? 0, ey = ty ?? 0
                if let sx = x, let sy = y {
                    for t in splitParameters(from: (sx, sy), to: (ex, ey), maxPiece: maxPiece, toDesign: toDesign) {
                        polyline.append((sx + (ex - sx) * t, sy + (ey - sy) * t, sz + (tz - sz) * t))
                    }
                } else {
                    // First XY move of the program: no path to subdivide.
                    polyline.append((ex, ey, tz))
                }
            } else {
                guard let sx = x, let sy = y, let ex = tx, let ey = ty else { throw fail("arc before the position is known") }
                let cx = sx + (iw?.value ?? 0), cy = sy + (jw?.value ?? 0)
                let r = hypot(sx - cx, sy - cy)
                guard r > eps else { throw fail("zero-radius arc") }
                let a0 = atan2(sy - cy, sx - cx)
                var sweep = atan2(ey - cy, ex - cx) - a0
                if mode == 3 { if sweep <= eps { sweep += 2 * .pi } } else { if sweep >= -eps { sweep -= 2 * .pi } }
                let byAngle = Int((abs(sweep) / Self.chordAngle).rounded(.up))
                let byLength = Int((abs(sweep) * r / Self.chordLength).rounded(.up))
                let chords = max(1, min(byAngle, byLength))
                var from = (sx, sy), fromZ = sz
                for s in 1...chords {
                    let last = s == chords
                    let a = a0 + sweep * Double(s) / Double(chords)
                    let to = last ? (ex, ey) : (cx + r * cos(a), cy + r * sin(a))
                    let toZ = last ? tz : sz + (tz - sz) * Double(s) / Double(chords)
                    for t in splitParameters(from: from, to: to, maxPiece: maxPiece, toDesign: toDesign) {
                        polyline.append((from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t,
                                         fromZ + (toZ - fromZ) * t))
                    }
                    from = to
                    fromZ = toZ
                }
            }

            let motion = motionText(isArc ? "G1" : nil)
            guard let first = polyline.first else { out.append(line); continue }
            let coordinates = "X\(Self.format(first.x)) Y\(Self.format(first.y)) "
                + "Z\(Self.format(first.z + offset(first.x, first.y)))"
            out.append(contentsOf: Self.rebuild(chars, words: words, coordinates: coordinates,
                                                motion: isArc ? "G1" : nil, comments: comments))
            for p in polyline.dropFirst() { out.append(piece(p.x, p.y, p.z, motion: motion)) }
        }
        return out.joined(separator: "\n")
    }

    /// Parameters in (0, 1] along the segment a→b (program coordinates)
    /// where it must be split: at every grid line it crosses, and so that
    /// no piece exceeds `maxPiece`. Grid lines are considered along their
    /// whole length, because outside the grid the clamped surface still
    /// creases at them. The crossings are found in design space (the frame
    /// is a translation or an axis mirror, so parameters and lengths carry
    /// over unchanged).
    private func splitParameters(from pa: (Double, Double), to pb: (Double, Double), maxPiece: Double,
                                 toDesign: CGAffineTransform) -> [Double] {
        let da = CGPoint(x: pa.0, y: pa.1).applying(toDesign), db = CGPoint(x: pb.0, y: pb.1).applying(toDesign)
        let a = (da.x, da.y), b = (db.x, db.y)
        let dx = b.0 - a.0, dy = b.1 - a.1
        let length = hypot(dx, dy)
        guard length > 1e-9, length.isFinite else { return [1] }
        var ts: [Double] = [1]
        let pieces = min(100_000, max(1, Int((length / maxPiece).rounded(.up))))
        for i in 1..<pieces { ts.append(Double(i) / Double(pieces)) }
        func crossings(_ start: Double, _ delta: Double, _ o: Double, _ step: Double, _ count: Int) {
            guard abs(delta) > 1e-9, step >= 0.01 else { return }
            let lo = min(start, start + delta), hi = max(start, start + delta)
            let kLo = (lo - o) / step, kHi = (hi - o) / step
            guard kLo.isFinite, kHi.isFinite, kHi >= -1, kLo <= Double(count) else { return }
            let first = max(0, Int(kLo.rounded(.up)))
            let last = min(count - 1, Int(kHi.rounded(.down)))
            guard first <= last else { return }
            for k in first...last {
                let g = o + Double(k) * step
                guard g > lo + 1e-9, g < hi - 1e-9 else { continue }
                ts.append((g - start) / delta)
            }
        }
        crossings(a.0, dx, origin.x, stepX, nx)
        crossings(a.1, dy, origin.y, stepY, ny)
        ts.sort()
        var result: [Double] = []
        for t in ts where t > 1e-9 && t <= 1 {
            if let previous = result.last, t - previous < 1e-9 { continue }
            result.append(t)
        }
        return result
    }

    private static func format(_ value: Double) -> String {
        let text = String(format: "%.4f", value)
        return text == "-0.0000" ? "0.0000" : text
    }

    // MARK: - Line parsing

    /// A letter–number word; `chars[start..<end]` is its text.
    private struct Word {
        let letter: Character
        let value: Double
        let start: Int
        let end: Int
    }

    /// Letter–number words outside comments, with exact values (so G91.1 is
    /// never mistaken for G91), and the comments — `(…)` groups and a `;`
    /// tail — as written.
    private static func scan(_ chars: [Character]) -> (words: [Word], comments: [String]) {
        var words: [Word] = []
        var comments: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" {
                var j = i + 1
                while j < chars.count, chars[j] != ")" { j += 1 }
                let end = min(j + 1, chars.count)
                comments.append(String(chars[i..<end]))
                i = end
                continue
            }
            if c == ";" {
                comments.append(String(chars[i...]))
                break
            }
            guard c.isLetter else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            let numberStart = j
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            if let value = Double(String(chars[numberStart..<j])) {
                words.append(Word(letter: Character(c.uppercased()), value: value, start: i, end: j))
                i = j
            } else {
                i += 1
            }
        }
        return (words, comments)
    }

    /// The first piece of a warped line: its words in their order with the
    /// X/Y/Z/I/J words replaced by `coordinates` (at the first one's place),
    /// the motion word replaced by `motion` when given, and the comments
    /// appended — or put on their own line before it when that would pass 79
    /// characters, GRBL's line limit being 80 with the newline.
    private static func rebuild(_ chars: [Character], words: [Word], coordinates: String,
                                motion: String?, comments: [String]) -> [String] {
        let axes: Set<Character> = ["X", "Y", "Z", "I", "J"]
        var parts: [String] = []
        var placed = false
        var hadMotion = false
        for w in words {
            if axes.contains(w.letter) {
                if !placed { parts.append(coordinates); placed = true }
                continue
            }
            if w.letter == "G", (0...3).contains(w.value) {
                hadMotion = true
                if let motion { parts.append(motion); continue }
            }
            parts.append(String(chars[w.start..<w.end]))
        }
        if !placed { parts.append(coordinates) }
        if let motion, !hadMotion { parts.insert(motion, at: 0) }
        let body = parts.joined(separator: " ")
        guard !comments.isEmpty else { return [body] }
        let comment = comments.joined(separator: " ")
        let full = body + " " + comment
        return full.count <= 79 ? [full] : [comment, body]
    }

    // MARK: - Persistence

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads a map file; a file of an older format (work coordinates, no
    /// `version`) is refused — its grid cannot be placed on the board.
    static func read(from url: URL) throws -> HeightMap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map = try decoder.decode(HeightMap.self, from: Data(contentsOf: url))
        guard map.version >= currentVersion else {
            throw HeightMapError(line: 0, reason: "\(url.lastPathComponent) is an older height map (work coordinates); probe a new one")
        }
        return map
    }

    private enum CodingKeys: String, CodingKey {
        case version, origin, size, nx, ny, zClear, zMaxDepth, feedFast, feedSlow, points, referenceZ
        case probedDesignOrigin, probedAt, side, firmwareVersion
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        origin = try c.decode(CGPoint.self, forKey: .origin)
        size = try c.decode(CGSize.self, forKey: .size)
        nx = try c.decode(Int.self, forKey: .nx)
        ny = try c.decode(Int.self, forKey: .ny)
        zClear = try c.decodeIfPresent(Double.self, forKey: .zClear) ?? 1
        zMaxDepth = try c.decodeIfPresent(Double.self, forKey: .zMaxDepth) ?? -2
        feedFast = try c.decodeIfPresent(Double.self, forKey: .feedFast) ?? 100
        feedSlow = try c.decodeIfPresent(Double.self, forKey: .feedSlow) ?? 20
        points = try c.decode([[Double?]].self, forKey: .points)
        referenceZ = try c.decodeIfPresent(Double.self, forKey: .referenceZ)
        probedDesignOrigin = try c.decodeIfPresent(MachinePosition.self, forKey: .probedDesignOrigin)
        probedAt = try c.decodeIfPresent(Date.self, forKey: .probedAt)
        side = try c.decode(BoardSide.self, forKey: .side)
        firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion)
    }

    /// `~/Library/Application Support/CNC G-Coder/HeightMaps/<sha256(projectKey)>-front.json`:
    /// never beside the user's files, keyed by the project path so a project
    /// finds its maps again without a pathname in the file name.
    static func storageURL(projectKey: String, side: BoardSide) -> URL {
        let digest = SHA256.hash(data: Data(projectKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CNC G-Coder", isDirectory: true)
            .appendingPathComponent("HeightMaps", isDirectory: true)
            .appendingPathComponent("\(digest)-\(side.rawValue).json")
    }
}
