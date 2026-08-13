import Foundation
import CoreGraphics

/// Generates a parameter-calibration test board as G-code: a grid of patches,
/// rows sweeping cut depth and columns sweeping XY feed. Every patch contains
/// three trace-survival tests (0.2 / 0.3 / 0.4 mm copper strips) and a pad —
/// both isolated exactly like production: multiple passes with 50% overlap
/// clearing the configured isolation width. Spreadsheet-style headers
/// (A B C… across the top, 1 2 3… down the left) identify patches against the
/// legend file after milling.
nonisolated enum TestBoardGenerator {

    struct Spec {
        var width: Double            // board size, mm
        var height: Double
        var rows: Int                // depth steps (user-selectable)
        var cols: Int                // feed steps (user-selectable)
        var depthFrom: Double        // row sweep (shallowest first), mm
        var depthTo: Double
        var feedFrom: Double         // column sweep, mm/min
        var feedTo: Double
        var tool: Double             // effective isolation tool diameter, mm
        var isolationWidth: Double   // cleared band width, like production
        var spindle: String
        var zsafe: Double
        var plungeFeed: Double
        /// Rapid down to this height above the board before feeding (0 = off),
        /// matching the plunge optimization applied to generated programs.
        var plungeClearance: Double = 0.3
    }

    static let traceWidths: [Double] = [0.2, 0.3, 0.4]
    static let maxRows = 12
    static let maxCols = 10          // column letters A…J

    // Layout constants (mm)
    private static let margin = 2.0
    private static let headerLeft = 5.0
    private static let headerTop = 4.5
    private static let minCellW = 8.5
    private static let minCellH = 8.0
    private static let columnLetters = Array("ABCDEFGHIJ")

    /// How many patches comfortably fit — the dialog's suggestion, not a limit.
    static func suggestedGrid(width: Double, height: Double) -> (rows: Int, cols: Int) {
        let cols = Int((width - margin * 2 - headerLeft) / 10.0)
        let rows = Int((height - margin * 2 - headerTop) / 9.0)
        return (min(max(rows, 0), maxRows), min(max(cols, 0), maxCols))
    }

    /// Cell size for a chosen grid; nil when the grid doesn't fit the board.
    static func cellSize(for spec: Spec) -> (w: Double, h: Double)? {
        guard spec.rows >= 2, spec.cols >= 2, spec.rows <= maxRows, spec.cols <= maxCols else { return nil }
        let w = (spec.width - margin * 2 - headerLeft) / Double(spec.cols)
        let h = (spec.height - margin * 2 - headerTop) / Double(spec.rows)
        guard w >= minCellW, h >= minCellH else { return nil }
        return (w, h)
    }

    /// Pass offsets (centerline distances from a copper edge) that clear
    /// `isolationWidth` of material using a `tool`-wide cutter at 50% overlap —
    /// the same scheme pcb2gcode uses for production isolation.
    private static func passOffsets(tool: Double, isolationWidth: Double) -> [Double] {
        let width = max(isolationWidth, tool)
        let first = tool / 2
        let last = width - tool / 2
        guard last > first + 1e-9 else { return [first] }
        let step = tool * 0.5
        let count = Int(ceil((last - first) / step))
        var offsets = (0...count).map { first + (last - first) * Double($0) / Double(count) }
        offsets[offsets.count - 1] = last
        return offsets
    }

    /// Returns (gcode, legend) or nil when the grid doesn't fit.
    static func generate(_ spec: Spec) -> (gcode: String, legend: String)? {
        guard let cell = cellSize(for: spec) else { return nil }
        let rows = spec.rows
        let cols = spec.cols

        func interpolate(_ from: Double, _ to: Double, _ index: Int, _ count: Int) -> Double {
            count <= 1 ? from : from + (to - from) * Double(index) / Double(count - 1)
        }
        let depths = (0..<rows).map { interpolate(spec.depthFrom, spec.depthTo, $0, rows) }
        let feeds = (0..<cols).map { interpolate(spec.feedFrom, spec.feedTo, $0, cols) }
        let labelDepth = depths[rows / 2]
        let labelFeed = feeds[cols / 2]
        let offsets = passOffsets(tool: spec.tool, isolationWidth: spec.isolationWidth)

        var g = GCodeBuilder(zsafe: spec.zsafe, plungeFeed: spec.plungeFeed,
                             plungeClearance: spec.plungeClearance)
        g.raw("( CNC G-Coder parameter test board )")
        g.raw("( \(Int(spec.width))x\(Int(spec.height)) mm, tool \(String(format: "%.2f", spec.tool)) mm, isolation \(String(format: "%.2f", spec.isolationWidth)) mm )")
        g.raw("( rows = cut depth, columns = XY feed; see the legend file )")
        g.raw("G94 ( mm/min feed )")
        g.raw("G21 ( metric )")
        g.raw("G90 ( absolute )")
        g.raw("S\(spec.spindle)")
        g.raw("M3 ( spindle on )")
        g.raw(String(format: "G0 Z%.3f", spec.zsafe))

        // Patches, row-major. Row 0 is the TOP row (like a spreadsheet).
        for r in 0..<rows {
            for c in 0..<cols {
                let depth = depths[r]
                let feed = feeds[c]
                let x0 = margin + headerLeft + Double(c) * cell.w + 0.5
                let yTop = spec.height - margin - headerTop - Double(r) * cell.h
                g.raw("( patch \(String(columnLetters[c]))\(r + 1): depth \(String(format: "%.3f", depth)) feed \(Int(feed)) )")

                // Trace-survival tests: each copper strip is isolated on both
                // sides with production-style multi-pass clearing. Passes on a
                // side are joined serpentine-fashion (the connecting step-over
                // lies inside the moat being cleared), so each side is a single
                // plunge instead of one per pass.
                let bandHeight = traceWidths.map { $0 / 2 + spec.isolationWidth }.max()! * 2
                let rowPitch = bandHeight + 0.6
                let xEnd = x0 + cell.w - 3.0
                for (k, tw) in traceWidths.enumerated() {
                    let cy = yTop - 1.2 - bandHeight / 2 - rowPitch * Double(k)
                    for sign in [1.0, -1.0] {
                        var pts: [CGPoint] = []
                        for (i, offset) in offsets.enumerated() {
                            let y = cy + sign * (tw / 2 + offset)
                            let xa = (i % 2 == 0) ? x0 : xEnd
                            let xb = (i % 2 == 0) ? xEnd : x0
                            pts.append(CGPoint(x: xa, y: y))
                            pts.append(CGPoint(x: xb, y: y))
                        }
                        g.polyline(pts, depth: depth, feed: feed)
                    }
                }

                // Pad: 1.5 mm copper island with a fully cleared isolation moat.
                // Concentric square passes joined at the corner (the diagonal
                // step-over lies inside the moat) — one plunge per pad.
                let pad = 1.5
                let padCenter = CGPoint(x: x0 + pad / 2 + spec.isolationWidth + 0.3,
                                        y: yTop - 1.2 - rowPitch * 3 - pad / 2 - spec.isolationWidth)
                var padPts: [CGPoint] = []
                for offset in offsets {
                    let half = pad / 2 + offset
                    padPts.append(CGPoint(x: padCenter.x - half, y: padCenter.y - half))
                    padPts.append(CGPoint(x: padCenter.x + half, y: padCenter.y - half))
                    padPts.append(CGPoint(x: padCenter.x + half, y: padCenter.y + half))
                    padPts.append(CGPoint(x: padCenter.x - half, y: padCenter.y + half))
                    padPts.append(CGPoint(x: padCenter.x - half, y: padCenter.y - half))
                }
                g.polyline(padPts, depth: depth, feed: feed)
            }
        }

        // Headers: column letters along the top, row numbers down the left,
        // engraved at mid-sweep depth/feed.
        let glyphHeight = 2.5
        g.raw("( headers )")
        for c in 0..<cols {
            let x = margin + headerLeft + Double(c) * cell.w + cell.w / 2 - glyphHeight * 0.3
            let y = spec.height - margin - 3.0
            g.text(String(columnLetters[c]), at: CGPoint(x: x, y: y),
                   height: glyphHeight, depth: labelDepth, feed: labelFeed)
        }
        for r in 0..<rows {
            let yTop = spec.height - margin - headerTop - Double(r) * cell.h
            let y = yTop - cell.h / 2 - glyphHeight / 2 + 1.0
            g.text("\(r + 1)", at: CGPoint(x: margin, y: y),
                   height: glyphHeight, depth: labelDepth, feed: labelFeed)
        }

        g.raw(String(format: "G0 Z%.3f", spec.zsafe))
        g.raw("M5 ( spindle off )")
        g.raw("M2 ( program end )")

        var legend = "CNC G-Coder — parameter test board legend\n"
        legend += "Board: \(Int(spec.width)) × \(Int(spec.height)) mm · tool ⌀\(String(format: "%.2f", spec.tool)) mm (effective) · isolation width \(String(format: "%.2f", spec.isolationWidth)) mm · spindle \(spec.spindle) rpm\n"
        legend += "Every patch, top to bottom: trace tests \(traceWidths.map { String(format: "%.1f", $0) }.joined(separator: " / ")) mm (fully isolated both sides), then a 1.5 mm pad with cleared moat.\n\n"
        legend += "Columns — XY feed (mm/min):\n"
        for c in 0..<cols { legend += "  \(String(columnLetters[c])) = \(Int(feeds[c]))\n" }
        legend += "\nRows — cut depth (mm):\n"
        for r in 0..<rows { legend += "  \(r + 1) = \(String(format: "%.3f", depths[r]))\n" }
        legend += "\nHeaders engraved at depth \(String(format: "%.3f", labelDepth)) / feed \(Int(labelFeed)).\n"
        legend += "After milling: pick the patch where the 0.2 mm trace survives cleanly and the moats are fully cleared — use its row depth and column feed in production. If only 0.3/0.4 mm survive, treat those as your minimum design trace width.\n"

        return (g.build(), legend)
    }

    // MARK: - G-code assembly

    private struct GCodeBuilder {
        let zsafe: Double
        let plungeFeed: Double
        let plungeClearance: Double
        private var lines: [String] = []

        init(zsafe: Double, plungeFeed: Double, plungeClearance: Double) {
            self.zsafe = zsafe
            self.plungeFeed = plungeFeed
            self.plungeClearance = plungeClearance
        }

        mutating func raw(_ line: String) {
            lines.append(line)
        }

        mutating func polyline(_ points: [CGPoint], depth: Double, feed: Double) {
            guard points.count >= 2 else { return }
            lines.append(String(format: "G0 Z%.3f", zsafe))
            lines.append(String(format: "G0 X%.3f Y%.3f", points[0].x, points[0].y))
            // Rapid through the air, feed only from the clearance height down.
            if plungeClearance > 0, plungeClearance < zsafe, depth < plungeClearance {
                lines.append(String(format: "G0 Z%.3f", plungeClearance))
            }
            lines.append(String(format: "G1 Z%.3f F%.0f", depth, plungeFeed))
            lines.append(String(format: "G1 F%.0f", feed))
            for p in points.dropFirst() {
                lines.append(String(format: "G1 X%.3f Y%.3f", p.x, p.y))
            }
        }

        mutating func text(_ string: String, at origin: CGPoint, height: Double, depth: Double, feed: Double) {
            var x = origin.x
            for ch in string.uppercased() {
                if let strokes = StrokeFont.glyphs[ch] {
                    for stroke in strokes {
                        let points = stroke.map {
                            CGPoint(x: x + $0.x * height, y: origin.y + $0.y * height)
                        }
                        polyline(points, depth: depth, feed: feed)
                    }
                }
                x += height * 0.85
            }
        }

        func build() -> String {
            lines.joined(separator: "\n") + "\n"
        }
    }
}

/// Minimal single-stroke vector font (unit box: x 0…0.6, y 0…1).
nonisolated enum StrokeFont {
    static let glyphs: [Character: [[CGPoint]]] = [
        "0": [rect],
        "1": [[p(0.3, 0), p(0.3, 1)], [p(0.1, 0.8), p(0.3, 1)]],
        "2": [[p(0, 1), p(0.6, 1), p(0.6, 0.5), p(0, 0.5), p(0, 0), p(0.6, 0)]],
        "3": [[p(0, 1), p(0.6, 1), p(0.6, 0), p(0, 0)], [p(0.15, 0.5), p(0.6, 0.5)]],
        "4": [[p(0, 1), p(0, 0.5), p(0.6, 0.5)], [p(0.6, 1), p(0.6, 0)]],
        "5": [[p(0.6, 1), p(0, 1), p(0, 0.5), p(0.6, 0.5), p(0.6, 0), p(0, 0)]],
        "6": [[p(0.6, 1), p(0, 1), p(0, 0), p(0.6, 0), p(0.6, 0.5), p(0, 0.5)]],
        "7": [[p(0, 1), p(0.6, 1), p(0.3, 0)]],
        "8": [rect, [p(0, 0.5), p(0.6, 0.5)]],
        "9": [[p(0, 0), p(0.6, 0), p(0.6, 1), p(0, 1), p(0, 0.5), p(0.6, 0.5)]],
        "A": [[p(0, 0), p(0.3, 1), p(0.6, 0)], [p(0.15, 0.4), p(0.45, 0.4)]],
        "B": [[p(0, 0), p(0, 1), p(0.5, 1), p(0.6, 0.8), p(0.5, 0.55), p(0, 0.55)],
              [p(0.5, 0.55), p(0.6, 0.3), p(0.5, 0), p(0, 0)]],
        "C": [[p(0.6, 1), p(0, 1), p(0, 0), p(0.6, 0)]],
        "D": [[p(0, 0), p(0, 1), p(0.4, 1), p(0.6, 0.75), p(0.6, 0.25), p(0.4, 0), p(0, 0)]],
        "E": [[p(0.6, 1), p(0, 1), p(0, 0), p(0.6, 0)], [p(0, 0.5), p(0.45, 0.5)]],
        "F": [[p(0, 0), p(0, 1), p(0.6, 1)], [p(0, 0.5), p(0.45, 0.5)]],
        "G": [[p(0.6, 1), p(0, 1), p(0, 0), p(0.6, 0), p(0.6, 0.4), p(0.35, 0.4)]],
        "H": [[p(0, 0), p(0, 1)], [p(0.6, 0), p(0.6, 1)], [p(0, 0.5), p(0.6, 0.5)]],
        "I": [[p(0.3, 0), p(0.3, 1)], [p(0.1, 1), p(0.5, 1)], [p(0.1, 0), p(0.5, 0)]],
        "J": [[p(0.6, 1), p(0.6, 0.15), p(0.45, 0), p(0.15, 0), p(0, 0.15)]]
    ]

    private static let rect: [CGPoint] = [p(0, 0), p(0.6, 0), p(0.6, 1), p(0, 1), p(0, 0)]

    private static func p(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
