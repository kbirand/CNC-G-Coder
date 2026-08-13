import Foundation
import CoreGraphics

/// Parses pcb2gcode output (.ngc, G90 absolute metric) into an ordered list of
/// toolpath moves with source line numbers, for rendering and playback.
nonisolated enum GCodeParser {

    /// Assumed rapid rate for time estimates of G0 moves (mm/min).
    static let assumedRapidFeed = 2000.0

    static func parse(fileURL: URL, layer: LayerKind) throws -> ParsedLayer {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var result = ParsedLayer(id: layer, fileURL: fileURL)

        var motion: Int?
        var absolute = true
        var unitScale = 1.0          // 25.4 while G20 (inches) is active
        var pos = (x: 0.0, y: 0.0, z: 0.0)
        var feed: Double?
        var time = 0.0
        var dist = 0.0
        var cutBounds = CGRect.null
        var allBounds = CGRect.null
        var zMin = Double.infinity
        var zMax = -Double.infinity

        var moves: [ToolpathMove] = []
        var drillHits: [CGPoint] = []

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        result.lineCount = lines.count

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1

            // Strip (…) comments and ;-to-end comments.
            var clean = ""
            clean.reserveCapacity(rawLine.count)
            var parenDepth = 0
            for ch in rawLine {
                if ch == "(" { parenDepth += 1; continue }
                if ch == ")" { parenDepth = max(0, parenDepth - 1); continue }
                if parenDepth > 0 { continue }
                if ch == ";" { break }
                clean.append(ch)
            }
            if clean.allSatisfy(\.isWhitespace) { continue }

            // Tokenize letter+number words (G0, X1.234, Z-0.06, F120, I…, J…).
            var words: [(letter: Character, value: Double)] = []
            var letter: Character?
            var number = ""
            func flushWord() {
                if let l = letter, let v = Double(number) { words.append((l, v)) }
                letter = nil
                number = ""
            }
            for ch in clean.uppercased() {
                if ch.isLetter {
                    flushWord()
                    letter = ch
                } else if ch.isNumber || ch == "." || ch == "-" || ch == "+" {
                    number.append(ch)
                } else if ch.isWhitespace {
                    continue
                } else {
                    flushWord()
                }
            }
            flushWord()

            var tx: Double?, ty: Double?, tz: Double?
            var arcI: Double?, arcJ: Double?
            var isG92 = false

            for w in words {
                switch w.letter {
                case "G":
                    // Match exact codes only: G91.1 (incremental ARC mode) and
                    // G92.1 (offset reset) must not be misread as G91/G92.
                    switch w.value {
                    case 0, 1, 2, 3: motion = Int(w.value)
                    case 20: unitScale = 25.4
                    case 21: unitScale = 1.0
                    case 90: absolute = true
                    case 91: absolute = false
                    case 92: isG92 = true
                    default: break
                    }
                case "X": tx = w.value * unitScale
                case "Y": ty = w.value * unitScale
                case "Z": tz = w.value * unitScale
                case "F": feed = w.value * unitScale
                case "I": arcI = w.value * unitScale
                case "J": arcJ = w.value * unitScale
                default: break
                }
            }

            if isG92 {
                // Coordinate system offset: reposition without motion.
                if let tx { pos.x = tx }
                if let ty { pos.y = ty }
                if let tz { pos.z = tz }
                continue
            }

            guard tx != nil || ty != nil || tz != nil, let m = motion, (0...3).contains(m) else { continue }

            func target(_ new: Double?, _ current: Double) -> Double {
                guard let new else { return current }
                return absolute ? new : current + new
            }
            let nx = target(tx, pos.x)
            let ny = target(ty, pos.y)
            let nz = target(tz, pos.z)

            // Arcs tessellate into segments; linear moves are one segment.
            var points: [(Double, Double, Double)] = []
            if m == 2 || m == 3, let arcI, let arcJ {
                let cx = pos.x + arcI
                let cy = pos.y + arcJ
                let radius = ((pos.x - cx) * (pos.x - cx) + (pos.y - cy) * (pos.y - cy)).squareRoot()
                let a0 = atan2(pos.y - cy, pos.x - cx)
                var a1 = atan2(ny - cy, nx - cx)
                if m == 2 {          // clockwise
                    if a1 >= a0 - 1e-12 { a1 -= 2 * .pi }
                } else {             // counter-clockwise
                    if a1 <= a0 + 1e-12 { a1 += 2 * .pi }
                }
                let sweep = a1 - a0
                let steps = max(2, Int(ceil(abs(sweep) / (5.0 * .pi / 180))))
                for s in 1...steps {
                    let t = Double(s) / Double(steps)
                    let a = a0 + sweep * t
                    points.append((cx + radius * cos(a), cy + radius * sin(a), pos.z + (nz - pos.z) * t))
                }
                points[points.count - 1] = (nx, ny, nz)
            } else {
                points.append((nx, ny, nz))
            }

            for (px, py, pz) in points {
                let dx = px - pos.x
                let dy = py - pos.y
                let dz = pz - pos.z
                let xyMoved = abs(dx) > 1e-9 || abs(dy) > 1e-9

                let kind: MoveKind
                if m == 0 {
                    kind = .rapid
                } else if !xyMoved && dz < -1e-9 && pz < -1e-9 {
                    kind = .plunge
                } else if max(pos.z, pz) < -1e-9 {
                    kind = .cut
                } else {
                    kind = .rapid
                }

                let length = (dx * dx + dy * dy + dz * dz).squareRoot()
                if length > 1e-12 {
                    let rate = (m == 0) ? assumedRapidFeed : (feed ?? assumedRapidFeed)
                    time += length / max(rate, 1) * 60
                    dist += length
                }

                let start = CGPoint(x: pos.x, y: pos.y)
                let end = CGPoint(x: px, y: py)
                moves.append(ToolpathMove(
                    start: start, end: end,
                    zStart: pos.z, zEnd: pz,
                    kind: kind,
                    feed: (m == 0) ? nil : feed,
                    sourceLine: lineNumber,
                    cumulativeTime: time,
                    cumulativeDistance: dist
                ))

                if kind == .plunge, layer.isDrill { drillHits.append(end) }

                let segment = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y),
                    width: abs(end.x - start.x), height: abs(end.y - start.y)
                )
                allBounds = allBounds.union(segment)
                if kind == .cut || kind == .plunge { cutBounds = cutBounds.union(segment) }
                zMin = min(zMin, min(pos.z, pz))
                zMax = max(zMax, max(pos.z, pz))

                pos = (px, py, pz)
            }
        }

        result.moves = moves
        result.drillHits = drillHits
        result.cutBounds = cutBounds.isNull ? nil : cutBounds
        result.allBounds = allBounds.isNull ? nil : allBounds
        result.zMin = zMin.isFinite ? zMin : 0
        result.zMax = zMax.isFinite ? zMax : 0
        result.totalTime = time
        result.totalDistance = dist
        return result
    }
}
