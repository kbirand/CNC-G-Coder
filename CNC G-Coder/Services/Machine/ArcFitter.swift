import Foundation

/// Replaces chains of short G1 segments that lie on a circle by one G2/G3
/// arc each. pcb2gcode writes every round pad pocket, ring and corner as a
/// polyline of ~0.07 mm chords (130 lines for a 2 mm pad); the controller
/// has to receive a line every 20 ms to hold the feed through them, and a
/// starved planner stops and starts at every chord — the circles crawl next
/// to the squares. An arc is one line and the controller segments it from
/// memory.
///
/// Honest fitting: a run of chords becomes an arc only when every original
/// vertex lies within `tolerance` of the fitted circle AND the circle bulges
/// away from every chord by no more than `tolerance` (the sagitta), so the
/// cut never leaves the path pcb2gcode designed by more than that. The
/// circle passes through the arc's first and last vertex exactly, so the
/// end point stays and Grbl's radius check (start/end radius within
/// 0.005 mm, error 33) always passes. Arcs are kept to ≤ 180°. Runs end at
/// any Z change, feed change, rapid, comment or non-motion word. Programs
/// in G91 or G20 are returned unchanged.
///
/// Applied to the streamed copy only (`ProgramOptions.fitArcs`, Settings →
/// Machine), never to the files on disk, so the same program can be sent
/// both ways for comparison. Foundation only: compiles standalone for tests.
nonisolated enum ArcFitter {

    struct Result: Sendable {
        var text: String
        /// Arcs written.
        var arcs: Int
        /// G1 lines those arcs replaced.
        var linesReplaced: Int
        var linesBefore: Int
        var linesAfter: Int
    }

    /// Max distance of any original vertex from the arc, and max sagitta.
    static let defaultTolerance = 0.005
    /// A shorter run is not worth an arc.
    static let minimumSegments = 4
    static let minimumRadius = 0.05
    static let maximumRadius = 1000.0
    static let maximumSweep = Double.pi + 1e-9

    private struct Point { var x: Double; var y: Double }

    private struct Line {
        var text: String
        var isCandidate = false      // a G1 XY move with nothing else on it
        var point = Point(x: 0, y: 0)
        var feedWord: String?        // "F200.00000" when the line carries one
    }

    static func fit(_ text: String, tolerance: Double = defaultTolerance) -> Result {
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [Line] = []
        lines.reserveCapacity(raw.count)

        // Pass 1: modal scan — which lines are plain G1 XY moves.
        var motion: Int? = nil
        var x = 0.0, y = 0.0
        var haveX = false, haveY = false
        var absolute = true, metric = true
        for line in raw {
            var entry = Line(text: line)
            let (words, comment) = scan(line)
            var lineMotion: Int? = nil
            var other = false
            var nx: Double? = nil, ny: Double? = nil, nz: Double? = nil
            var feed: String? = nil
            for w in words {
                switch w.letter {
                case "G":
                    switch w.value {
                    case 0, 1, 2, 3: lineMotion = Int(w.value)
                    case 90: absolute = true
                    case 91: absolute = false
                    case 21: metric = true
                    case 20: metric = false
                    default: other = true
                    }
                case "X": nx = w.value
                case "Y": ny = w.value
                case "Z": nz = w.value
                case "F": feed = w.text
                default: other = true
                }
            }
            if !absolute || !metric {
                return Result(text: text, arcs: 0, linesReplaced: 0, linesBefore: raw.count, linesAfter: raw.count)
            }
            if let lineMotion { motion = lineMotion }
            let movesXY = nx != nil || ny != nil
            if let nx { x = nx; haveX = true }
            if let ny { y = ny; haveY = true }
            let effective = movesXY ? (lineMotion ?? motion) : lineMotion
            if effective == 1, movesXY, nz == nil, !other, !comment, haveX, haveY,
               !(lineMotion == nil && words.contains { $0.letter == "G" }) {
                entry.isCandidate = true
                entry.point = Point(x: x, y: y)
                entry.feedWord = feed
            }
            lines.append(entry)
        }

        // Pass 2: runs of candidates, each fitted greedily.
        var out: [String] = []
        out.reserveCapacity(raw.count)
        var arcs = 0, replaced = 0
        var i = 0
        var current = Point(x: 0, y: 0)   // position before line i (candidates only matter after XY is known)
        var position: Point? = nil
        func track(_ line: String) {
            // Keep the start point for the next run: any line with X/Y words.
            let (words, _) = scan(line)
            var p = position ?? Point(x: 0, y: 0)
            var moved = false
            for w in words {
                if w.letter == "X" { p.x = w.value; moved = true }
                if w.letter == "Y" { p.y = w.value; moved = true }
            }
            if moved { position = p }
        }
        while i < lines.count {
            guard lines[i].isCandidate, let start = position else {
                out.append(lines[i].text)
                track(lines[i].text)
                i += 1
                continue
            }
            // A run: consecutive candidates; a feed word is allowed on the first line only.
            var j = i
            while j < lines.count, lines[j].isCandidate, j == i || lines[j].feedWord == nil { j += 1 }
            let run = Array(lines[i..<j])
            let points = [start] + run.map(\.point)
            current = start
            var feedPending = run[0].feedWord
            var k = 0   // index into points: the arc/segment starts at points[k]
            while k < points.count - 1 {
                if let arc = longestArc(points, from: k, tolerance: tolerance) {
                    var line = format(arc: arc, from: points[k], to: points[arc.end])
                    if let f = feedPending { line += " " + f; feedPending = nil }
                    out.append(line)
                    arcs += 1
                    replaced += arc.end - k
                    k = arc.end
                } else {
                    var line = run[k].text
                    if feedPending != nil, k > 0 {
                        // The first line (with the feed) was consumed by nothing: it is emitted as itself.
                        line = run[k].text
                    }
                    if k == 0 { feedPending = nil }   // the original first line carries its own F
                    out.append(line)
                    k += 1
                }
            }
            position = points[points.count - 1]
            _ = current
            i = j
        }
        let result = out.joined(separator: "\n")
        return Result(text: result, arcs: arcs, linesReplaced: replaced, linesBefore: raw.count, linesAfter: out.count)
    }

    // MARK: - Fitting

    private struct Arc {
        var end: Int            // index of the last point on the arc
        var center: Point
        var clockwise: Bool
    }

    /// The longest arc starting at `points[from]` that passes the tolerance,
    /// or nil when fewer than `minimumSegments` chords fit.
    private static func longestArc(_ points: [Point], from: Int, tolerance: Double) -> Arc? {
        var best: Arc? = nil
        var end = from + minimumSegments
        while end < points.count {
            guard let arc = check(points, from: from, to: end, tolerance: tolerance) else { break }
            best = arc
            end += 1
        }
        return best
    }

    private static func check(_ points: [Point], from a: Int, to b: Int, tolerance: Double) -> Arc? {
        let mid = (a + b) / 2
        guard let center = circumcenter(points[a], points[mid], points[b]) else { return nil }
        let r = hypot(points[a].x - center.x, points[a].y - center.y)
        guard r >= minimumRadius, r <= maximumRadius else { return nil }
        // Direction from the first turn.
        let cross = (points[mid].x - points[a].x) * (points[b].y - points[mid].y)
                  - (points[mid].y - points[a].y) * (points[b].x - points[mid].x)
        guard abs(cross) > 1e-12 else { return nil }
        let clockwise = cross < 0
        // Every vertex on the circle, angles progressing one way, sweep ≤ 180°,
        // and each chord's sagitta within tolerance.
        var previousAngle = atan2(points[a].y - center.y, points[a].x - center.x)
        var sweep = 0.0
        for k in (a + 1)...b {
            let p = points[k]
            let rk = hypot(p.x - center.x, p.y - center.y)
            guard abs(rk - r) <= tolerance else { return nil }
            let angle = atan2(p.y - center.y, p.x - center.x)
            var delta = angle - previousAngle
            if clockwise { delta = -delta }
            while delta < 0 { delta += 2 * .pi }
            while delta >= 2 * .pi { delta -= 2 * .pi }
            guard delta > 1e-9, delta < .pi else { return nil }   // forward, never a reversal
            let sagitta = r * (1 - cos(delta / 2))
            guard sagitta <= tolerance else { return nil }
            sweep += delta
            guard sweep <= maximumSweep else { return nil }
            previousAngle = angle
        }
        return Arc(end: b, center: center, clockwise: clockwise)
    }

    private static func circumcenter(_ a: Point, _ b: Point, _ c: Point) -> Point? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-12 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        return Point(x: ux, y: uy)
    }

    private static func format(arc: Arc, from start: Point, to end: Point) -> String {
        let i = arc.center.x - start.x, j = arc.center.y - start.y
        return "\(arc.clockwise ? "G02" : "G03") X\(number(end.x)) Y\(number(end.y)) I\(number(i)) J\(number(j))"
    }

    private static func number(_ v: Double) -> String {
        var s = String(format: "%.5f", v)
        if s == "-0.00000" { s = "0.00000" }
        return s
    }

    // MARK: - Scanning

    private struct Word { var letter: Character; var value: Double; var text: String }

    /// Words of a line and whether it carries a comment.
    private static func scan(_ line: String) -> (words: [Word], comment: Bool) {
        var words: [Word] = []
        var comment = false
        var body = ""
        var depth = 0
        for ch in line {
            if ch == "(" { depth += 1; comment = true; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth > 0 { continue }
            if ch == ";" { comment = true; break }
            body.append(ch)
        }
        var letter: Character? = nil
        var digits = ""
        func flush() {
            if let l = letter, let v = Double(digits) { words.append(Word(letter: l, value: v, text: "\(l)\(digits)")) }
            letter = nil; digits = ""
        }
        for ch in body {
            if ch.isLetter {
                flush()
                letter = Character(ch.uppercased())
            } else if ch.isNumber || ch == "." || ch == "-" || ch == "+" {
                digits.append(ch)
            } else if ch == " " || ch == "\t" {
                continue
            } else {
                flush()
                // Anything else (a '%', '*', '/') makes the line non-trivial.
                words.append(Word(letter: "?", value: 0, text: String(ch)))
            }
        }
        flush()
        return (words, comment)
    }
}
