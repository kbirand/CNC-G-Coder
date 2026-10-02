import Foundation

/// Backlash compensation as a G-code post-process, for machines that lose a
/// fixed amount of travel whenever an axis reverses (a screw bearing with end
/// play, a worn nut). GRBL/FluidNC have no setting for it, so the program
/// itself carries the correction.
///
/// Each compensated axis is tracked in the direction it last moved. Coming
/// in from + is the reference: positions reached moving + are written as
/// designed, positions reached moving − are written `play` lower (the table
/// stops `play` short of where the screw puts it). On every reversal a short
/// take-up move of that axis alone is inserted first — the screw turns
/// through the play while the table stays put — so the cut itself keeps its
/// exact geometry. Arcs are split at their X/Y extremes, where they reverse.
/// The program's first rapid is approached from below on each compensated
/// axis so the play starts out in a known state.
nonisolated enum BacklashCompensation {

    struct Settings: Equatable, Sendable {
        var x: Double
        var y: Double

        var isActive: Bool { x > 0 || y > 0 }

        static let xKey = "machine.backlashX"
        static let yKey = "machine.backlashY"
        /// Larger values are typing mistakes, not play.
        static let maxPlay = 2.0

        /// The values in Machine setup. Play belongs to the machine, so it is
        /// stored app-wide and never saved into projects.
        static var current: Settings {
            func read(_ key: String) -> Double {
                let text = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
                guard let v = Double(text), v.isFinite else { return 0 }
                return min(max(v, 0), maxPlay)
            }
            return Settings(x: read(xKey), y: read(yKey))
        }

        var summary: String {
            [("X", x), ("Y", y)].filter { $0.1 > 0 }
                .map { String(format: "%@ %.3f mm", $0.0, $0.1) }
                .joined(separator: ", ")
        }
    }

    struct Failure: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { "line \(line): \(reason)" }
    }

    /// How far below the first rapid's target it is approached from.
    static let leadIn = 1.0

    // MARK: - Files

    /// Compensates every file in place; returns the log text.
    static func apply(_ s: Settings, files: [URL]) -> String {
        guard s.isActive else { return "" }
        var log = ""
        var takeUps = 0
        var done = 0
        for file in files {
            do {
                takeUps += try apply(s, file: file)
                done += 1
            } catch {
                log += "WARNING: backlash compensation NOT applied to \(file.lastPathComponent) (\(error.localizedDescription)) — it will cut with the machine's play.\n"
            }
        }
        if done > 0 {
            log += "Backlash compensation (\(s.summary)): \(done) program\(done == 1 ? "" : "s"), \(takeUps) take-up move\(takeUps == 1 ? "" : "s") inserted.\n"
        }
        return log
    }

    /// Compensates one file in place; returns the number of take-up moves.
    @discardableResult
    static func apply(_ s: Settings, file: URL) throws -> Int {
        let text = try String(contentsOf: file, encoding: .utf8)
        let result = try apply(s, to: text)
        try result.text.write(to: file, atomically: true, encoding: .utf8)
        return result.takeUps
    }

    // MARK: - Program text

    static func apply(_ s: Settings, to text: String) throws -> (text: String, takeUps: Int) {
        let play = [s.x, s.y]
        guard s.isActive else { return (text, 0) }
        let eps = 1e-6
        var out: [String] = [String(format: "( Backlash compensation: %@ )", s.summary)]
        var takeUps = 0
        var mode = 0                         // modal motion: G0–G3
        var pos: [Double?] = [nil, nil]      // commanded X, Y, as designed
        var z: Double?
        var dir = [0, 0]                     // last direction per axis: +1 / −1, 0 = unknown

        func offset(_ axis: Int) -> Double { dir[axis] < 0 ? -play[axis] : 0 }
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        let names = ["X", "Y"]

        /// Takes up the play on every axis whose direction changes; returns
        /// whether a move was inserted.
        func reverse(to newDir: [Int], rapid: Bool) -> Bool {
            var words: [String] = []
            for a in 0..<2 where play[a] > 0 && dir[a] != 0 && newDir[a] != 0 && newDir[a] != dir[a] {
                dir[a] = newDir[a]
                if let p = pos[a] { words.append(names[a] + f(p + offset(a))) }
            }
            for a in 0..<2 where dir[a] == 0 && newDir[a] != 0 { dir[a] = newDir[a] }
            guard !words.isEmpty else { return false }
            out.append((rapid ? "G0 " : "G1 ") + words.joined(separator: " ") + " ( backlash take-up )")
            takeUps += 1
            return true
        }

        for (index, sub) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(sub)
            let words = parse(line)
            func fail(_ reason: String) -> Failure { Failure(line: index + 1, reason: reason) }

            var explicitMotion = false
            for w in words where w.letter == "G" {
                switch w.value {
                case 0, 1, 2, 3: mode = Int(w.value); explicitMotion = true
                case 91: throw fail("incremental coordinates (G91)")
                case 20: throw fail("inch units (G20)")
                case 18, 19: throw fail("arcs outside the XY plane (G\(Int(w.value)))")
                case 28, 30, 53, 92: throw fail("G\(Int(w.value)) moves to or redefines a position the program does not state")
                case 81...89: throw fail("canned drilling cycles (G8x)")
                case 90.1: throw fail("absolute arc centres (G90.1)")
                default: break
                }
            }
            func word(_ letter: Character) -> Word? { words.last { $0.letter == letter } }
            let xw = word("X"), yw = word("Y"), zw = word("Z")
            let iw = word("I"), jw = word("J")
            if word("R") != nil, mode >= 2 { throw fail("radius-format arcs (R)") }

            // Not an XY move: unchanged.
            let isArc = mode >= 2 && (xw != nil || yw != nil || iw != nil || jw != nil)
            guard isArc || xw != nil || yw != nil else {
                out.append(line)
                if let zw { z = zw.value }
                continue
            }

            if !isArc {
                let target = [xw?.value ?? pos[0], yw?.value ?? pos[1]]
                var newDir = dir
                var leadInWords: [String] = []
                for a in 0..<2 where play[a] > 0 {
                    guard let t = target[a] else { continue }
                    if let p = pos[a] {
                        if t - p > eps { newDir[a] = 1 } else if t - p < -eps { newDir[a] = -1 }
                    } else if dir[a] == 0 {
                        // First move on this axis: come in from below so the
                        // play is taken up in +, the reference direction.
                        if mode == 0 { leadInWords.append(names[a] + f(t - Self.leadIn)) }
                        dir[a] = 1
                        newDir[a] = 1
                    }
                }
                if !leadInWords.isEmpty { out.append("G0 " + leadInWords.joined(separator: " ") + " ( backlash lead-in )") }
                let inserted = reverse(to: newDir, rapid: mode == 0) || !leadInWords.isEmpty

                var edits: [(Range<Int>, String)] = []
                for (a, w) in [(0, xw), (1, yw)] {
                    if let w, offset(a) != 0 { edits.append((w.range, f(w.value + offset(a)))) }
                }
                let rewritten = replacing(edits, in: line)
                out.append(inserted && !explicitMotion ? "G\(mode) " + rewritten : rewritten)
                pos = target
                if let zw { z = zw.value }
                continue
            }

            // Arc: split where it reverses in X or Y.
            guard let sx = pos[0], let sy = pos[1] else { throw fail("arc before the position is known") }
            let cx = sx + (iw?.value ?? 0), cy = sy + (jw?.value ?? 0)
            let ex = xw?.value ?? sx, ey = yw?.value ?? sy
            let r = hypot(sx - cx, sy - cy)
            guard r > eps else { throw fail("zero-radius arc") }
            let a0 = atan2(sy - cy, sx - cx)
            var sweep = atan2(ey - cy, ex - cx) - a0
            if mode == 3 { if sweep <= eps { sweep += 2 * .pi } } else { if sweep >= -eps { sweep -= 2 * .pi } }
            let quarter = Double.pi / 2
            let lo = min(a0, a0 + sweep), hi = max(a0, a0 + sweep)
            var cuts: [Double] = []
            var k = (lo / quarter).rounded(.up)
            while k * quarter < hi - eps {
                if k * quarter > lo + eps { cuts.append(k * quarter) }
                k += 1
            }
            if sweep < 0 { cuts.reverse() }
            let angles = [a0] + cuts + [a0 + sweep]

            let startZ = z
            let endZ = zw?.value ?? z
            var pieces: [String] = []
            var changed = !cuts.isEmpty || dir.indices.contains { offset($0) != 0 }
            var firstPiece = true
            for p in 0..<(angles.count - 1) {
                let mid = (angles[p] + angles[p + 1]) / 2
                let sign = sweep > 0 ? 1.0 : -1.0
                let velocity = [-sin(mid) * sign, cos(mid) * sign]
                var newDir = dir
                for a in 0..<2 where play[a] > 0 {
                    if velocity[a] > eps { newDir[a] = 1 } else if velocity[a] < -eps { newDir[a] = -1 }
                }
                let before = out.count
                if reverse(to: newDir, rapid: false) {
                    changed = true
                    // Take-ups go between the arc's pieces, in order.
                    pieces.append(contentsOf: out[before...])
                    out.removeSubrange(before...)
                }
                let last = p == angles.count - 2
                let px = last ? ex : cx + r * cos(angles[p + 1])
                let py = last ? ey : cy + r * sin(angles[p + 1])
                let qx = pos[0]!, qy = pos[1]!
                var piece = "G\(mode) X\(f(px + offset(0))) Y\(f(py + offset(1)))"
                if zw != nil, let startZ, let endZ {
                    piece += " Z\(f(startZ + (endZ - startZ) * (angles[p + 1] - a0) / sweep))"
                }
                piece += " I\(f(cx - qx)) J\(f(cy - qy))"
                if firstPiece, let fw = word("F") { piece += " F" + String(Array(line)[fw.range]) }
                if firstPiece, let comment = comment(of: line) { piece += " " + comment }
                pieces.append(piece)
                firstPiece = false
                pos = [px, py]
            }
            out.append(contentsOf: changed ? pieces : [line])
            pos = [ex, ey]
            if let zw { z = zw.value }
        }
        return (out.joined(separator: "\n"), takeUps)
    }

    // MARK: - Parsing

    private struct Word {
        let letter: Character
        let value: Double
        /// Where the number's text sits in the line, in characters.
        let range: Range<Int>
    }

    /// Letter–number words outside comments, with exact values (so G91.1 is
    /// never mistaken for G91).
    private static func parse(_ line: String) -> [Word] {
        let chars = Array(line)
        var words: [Word] = []
        var inComment = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { inComment = true }
            if c == ")" { inComment = false; i += 1; continue }
            if c == ";" && !inComment { break }
            guard !inComment, c.isLetter else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            let start = j
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            if let value = Double(String(chars[start..<j])) {
                words.append(Word(letter: Character(c.uppercased()), value: value, range: start..<j))
                i = j
            } else {
                i += 1
            }
        }
        return words
    }

    /// The line with each range's text replaced.
    private static func replacing(_ edits: [(Range<Int>, String)], in line: String) -> String {
        guard !edits.isEmpty else { return line }
        var chars = Array(line)
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            chars.replaceSubrange(range, with: Array(text))
        }
        return String(chars)
    }

    private static func comment(of line: String) -> String? {
        guard let open = line.firstIndex(of: "(") else { return nil }
        return String(line[open...])
    }

    // MARK: - Test cut

    /// The axis test, cut with `tool` at its own depth, feeds and spindle: a
    /// 50 mm square and a Ø30 circle for scale, and per axis one straight
    /// line cut in two halves reached from opposite directions — a step
    /// between the halves is that axis's play. Cut with the compensation on,
    /// straight lines mean the value is right.
    static func testProgram(tool: MachineTool, safeZ: Double) -> String {
        let d = String(format: "%.3f", -abs(tool.cutDepth))
        let fr = String(format: "%.0f", tool.feedXY)
        let pf = String(format: "%.0f", tool.feedZ)
        let zs = String(format: "%.3f", max(safeZ, 1))
        func plunge() -> [String] { ["G0 Z0.3", "G1 Z\(d) F\(pf)"] }
        var g: [String] = [
            "( Backlash test cut — CNC G-Coder )",
            "( Tool: \(tool.name), depth \(d) mm, feed \(fr) mm/min )",
            "( Zero X/Y at the lower-left of a free 75 x 75 mm area, Z0 on the surface. )",
            "( Line at Y60: left half reached moving +Y, right half moving -Y. A step at X8 = Y play. )",
            "( Line at X60: lower half reached moving +X, upper half moving -X. A step at Y8 = X play. )",
            "( Square 50 x 50 and circle D30: measure both directions; they should match. )",
            "G21 G90 G94", "G0 Z\(zs)",
            String(format: "%@ S%.0f", tool.spindleCCW ? "M4" : "M3", tool.spindle)
        ]
        if tool.dwell > 0 { g.append(String(format: "G4 P%.1f", tool.dwell)) }
        g += ["( square )", "G0 X0 Y0"]
        g += plunge()
        g += ["G1 X50 Y0 F\(fr)", "G1 X50 Y50", "G1 X0 Y50", "G1 X0 Y0", "G0 Z\(zs)",
              "( circle )", "G0 X10 Y25"]
        g += plunge()
        g += ["G2 X10 Y25 I15 J0 F\(fr)", "G0 Z\(zs)",
              "( X play: lower half from the left )", "G0 X55 Y0", "G0 X60"]
        g += plunge()
        g += ["G1 Y8 F\(fr)", "G0 Z\(zs)", "( upper half from the right )", "G0 X65 Y8", "G0 X60"]
        g += plunge()
        g += ["G1 Y16 F\(fr)", "G0 Z\(zs)",
              "( Y play: left half from below )", "G0 X0 Y55", "G0 Y60"]
        g += plunge()
        g += ["G1 X8 F\(fr)", "G0 Z\(zs)", "( right half from above )", "G0 X8 Y65", "G0 Y60"]
        g += plunge()
        g += ["G1 X16 F\(fr)", "G0 Z\(zs)", "M5", "G0 X0 Y0", "M2"]
        return g.joined(separator: "\n") + "\n"
    }
}
