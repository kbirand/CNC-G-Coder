import Foundation
import CoreGraphics

/// Generates a parameter-calibration test board as G-code: a grid of patches,
/// rows sweeping cut depth and columns sweeping XY feed. Every patch holds
/// three trace tests (0.2 / 0.3 / 0.4 mm): each trace runs between two probe
/// pads and is a closed copper island, ringed by production-style isolation
/// passes (50 % overlap, out to the isolation width). With a multimeter:
/// continuity pad-to-pad means the trace survived, no continuity from a pad
/// to the surrounding copper means the isolation is complete.
/// Spreadsheet-style headers (A B C… across the top, 1 2 3… down the left)
/// identify patches against the legend file after milling.
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
        /// The bit; a V-bit's width is worked out per row, at that row's depth.
        var tool: MachineTool
        var isolationWidth: Double   // cleared band width, like production
        var zsafe: Double
        /// Rapid down to this height above the board before feeding (0 = off),
        /// matching the plunge optimization applied to generated programs.
        var plungeClearance: Double = 0.3

        var depths: [Double] { (0..<rows).map { Self.interpolate(depthFrom, depthTo, $0, rows) } }
        var feeds: [Double] { (0..<cols).map { Self.interpolate(feedFrom, feedTo, $0, cols) } }
        /// Widest cut of the sweep (a V-bit at the deepest row).
        var widestCut: Double { depths.map { tool.effectiveDiameter(atDepth: $0) }.max() ?? 0 }

        private static func interpolate(_ from: Double, _ to: Double, _ index: Int, _ count: Int) -> Double {
            count <= 1 ? from : from + (to - from) * Double(index) / Double(count - 1)
        }
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
    /// Square probe pad at each end of a trace — room for a meter probe tip.
    static let probePad = 1.2
    /// Copper left between a cell's moat and the next cell's.
    private static let cellGutter = 0.25
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
        guard w >= minCellW, h >= minCellH, layout(spec, cell: (w, h)) != nil else { return nil }
        return (w, h)
    }

    /// Spacing between the islands and the moat width that fit a cell. The
    /// moat is the isolation width, narrowed only when the cell is too small
    /// for it (never below one full cut).
    private static func layout(_ spec: Spec, cell: (w: Double, h: Double)) -> (gap: Double, moat: Double)? {
        let cut = spec.widestCut
        guard cut > 0 else { return nil }
        // Islands must sit at least a cut apart, or the passes between them
        // could not clear the copper and they would stay connected.
        let gap = max(0.6, cut + 0.2)
        let stack = Double(traceWidths.count) * probePad + Double(traceWidths.count - 1) * gap
        let fitH = (cell.h - 2 * cellGutter - stack) / 2
        let fitW = (cell.w - 2 * cellGutter - 2 * probePad - 1.5) / 2   // keep ≥ 1.5 mm of bare trace
        let moat = min(max(spec.isolationWidth, cut), fitH, fitW)
        return moat >= cut ? (gap, moat) : nil
    }

    /// Distances from the copper edge of the centre of each isolation pass:
    /// the first pass touches the copper, the last reaches `moat`, 50 % overlap.
    private static func passOffsets(cut: Double, moat: Double) -> [Double] {
        let first = cut / 2
        let last = max(moat, cut) - cut / 2
        guard last > first + 1e-9 else { return [first] }
        let count = Int(ceil((last - first) / (cut * 0.5)))
        return (0...count).map { first + (last - first) * Double($0) / Double(count) }
    }

    /// One trace island: probe pad, trace, probe pad (counter-clockwise).
    private static func island(left: Double, right: Double, centerY cy: Double, trace: Double) -> Clipper.Path {
        let p = probePad, h = p / 2, t = trace / 2
        return [CGPoint(x: left, y: cy - h), CGPoint(x: left + p, y: cy - h), CGPoint(x: left + p, y: cy - t),
                CGPoint(x: right - p, y: cy - t), CGPoint(x: right - p, y: cy - h), CGPoint(x: right, y: cy - h),
                CGPoint(x: right, y: cy + h), CGPoint(x: right - p, y: cy + h), CGPoint(x: right - p, y: cy + t),
                CGPoint(x: left + p, y: cy + t), CGPoint(x: left + p, y: cy + h), CGPoint(x: left, y: cy + h)]
    }

    /// Returns (gcode, legend) or nil when the grid doesn't fit.
    static func generate(_ spec: Spec) -> (gcode: String, legend: String)? {
        guard let cell = cellSize(for: spec), let fit = layout(spec, cell: cell) else { return nil }
        let rows = spec.rows
        let cols = spec.cols
        let depths = spec.depths
        let feeds = spec.feeds
        let labelDepth = depths[rows / 2]
        let labelFeed = feeds[cols / 2]
        let plungeFeed = spec.tool.feedZ
        let spindle = String(format: "%.0f", spec.tool.spindle)

        var g = GCodeBuilder(zsafe: spec.zsafe, plungeFeed: plungeFeed,
                             plungeClearance: spec.plungeClearance)
        g.raw("( CNC G-Coder parameter test board )")
        g.raw("( \(Int(spec.width))x\(Int(spec.height)) mm, tool: \(spec.tool.name), isolation \(String(format: "%.2f", fit.moat)) mm )")
        g.raw("( rows = cut depth, columns = XY feed; see the legend file )")
        g.raw("G94 ( mm/min feed )")
        g.raw("G21 ( metric )")
        g.raw("G90 ( absolute )")
        g.raw("S\(spindle)")
        g.raw(spec.tool.spindleCCW ? "M4 ( spindle on, counter-clockwise )" : "M3 ( spindle on )")
        g.raw(String(format: "G0 Z%.3f", spec.zsafe))

        // Patches, row-major. Row 0 is the TOP row (like a spreadsheet).
        let stack = Double(traceWidths.count) * probePad + Double(traceWidths.count - 1) * fit.gap
        for r in 0..<rows {
            let depth = depths[r]
            let cut = spec.tool.effectiveDiameter(atDepth: depth)
            let offsets = passOffsets(cut: cut, moat: fit.moat)
            for c in 0..<cols {
                let feed = feeds[c]
                let cellLeft = margin + headerLeft + Double(c) * cell.w
                let cellTop = spec.height - margin - headerTop - Double(r) * cell.h
                g.raw("( patch \(String(columnLetters[c]))\(r + 1): depth \(String(format: "%.3f", depth)) feed \(Int(feed)) cut width \(String(format: "%.3f", cut)) )")

                let left = cellLeft + cellGutter + fit.moat
                let right = cellLeft + cell.w - cellGutter - fit.moat
                let firstY = cellTop - cell.h / 2 + stack / 2 - probePad / 2
                let islands = traceWidths.enumerated().map { k, tw in
                    island(left: left, right: right, centerY: firstY - Double(k) * (probePad + fit.gap), trace: tw)
                }
                // Closed rings, innermost first: each island ends up fully
                // enclosed by cut copper. Rings of neighbouring islands that
                // meet are merged, so the copper between them is cleared too.
                for offset in offsets {
                    for ring in Clipper.inflate(islands, by: offset, join: .round) where ring.count >= 3 {
                        g.polyline(ring + [ring[0]], depth: depth, feed: feed)
                    }
                }
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
        legend += "Board: \(Int(spec.width)) × \(Int(spec.height)) mm · tool: \(spec.tool.name) · isolation width \(String(format: "%.2f", fit.moat)) mm · spindle \(spindle) rpm\n"
        if fit.moat < spec.isolationWidth - 1e-9 {
            legend += String(format: "(Isolation narrowed from %.2f mm so the moats fit the patches.)\n", spec.isolationWidth)
        }
        legend += "Every patch, top to bottom: trace tests \(traceWidths.map { String(format: "%.1f", $0) }.joined(separator: " / ")) mm. Each trace runs between two \(String(format: "%.1f", probePad)) mm probe pads and is a closed island, ringed by isolation passes.\n\n"
        legend += "Columns — XY feed (mm/min):\n"
        for c in 0..<cols { legend += "  \(String(columnLetters[c])) = \(Int(feeds[c]))\n" }
        legend += "\nRows — cut depth (mm) and the width the tool cuts there:\n"
        for r in 0..<rows {
            legend += "  \(r + 1) = \(String(format: "%.3f", depths[r]))  (cut \(String(format: "%.3f", spec.tool.effectiveDiameter(atDepth: depths[r]))) mm)\n"
        }
        legend += "\nHeaders engraved at depth \(String(format: "%.3f", labelDepth)) / feed \(Int(labelFeed)).\n"
        legend += "\nChecking with a multimeter (continuity / beep mode):\n"
        legend += "  1. Pad to pad of one trace: must beep — the trace survived.\n"
        legend += "  2. Either pad to the copper around the patch: must NOT beep — the isolation is complete.\n"
        legend += "  3. A pad to a pad of the neighbouring trace: must NOT beep.\n"
        legend += "Use the patch where all three pass, the 0.2 mm trace is clean and the moats are fully cleared: its row depth and column feed are your production settings. If only 0.3/0.4 mm survive, treat that as your minimum design trace width.\n"

        return (g.build(), legend)
    }

    // MARK: - Hole fit test

    struct HoleFitSpec {
        /// Nominal hole sizes, one row each (row 1 at the bottom), mm.
        var diameters: [Double]
        /// Added to every nominal size, one column each (A at the left), mm.
        var offsets: [Double]
        /// The hole mill; its diameter, depth, pass depth, feeds and spindle are used.
        var tool: MachineTool
        var zsafe: Double
        var plungeClearance: Double = 0.3

        static let maxRows = 8
        static let maxCols = 10

        var cut: Double { tool.effectiveDiameter(atDepth: tool.cutDepth) }
        /// Centre-to-centre spacing: the largest hole plus 3 mm of material.
        var pitch: Double { max((diameters.max() ?? 0) + (offsets.max() ?? 0), cut) + 3 }
        static let margin = 3.0
        var size: (w: Double, h: Double) {
            (2 * Self.margin + Double(offsets.count) * pitch,
             2 * Self.margin + Double(diameters.count) * pitch + cut + 2)
        }

        /// Why the spec cannot be cut, or nil.
        var problem: String? {
            if diameters.isEmpty || offsets.isEmpty { return "Enter at least one hole size and one variant." }
            if diameters.count > Self.maxRows || offsets.count > Self.maxCols {
                return "At most \(Self.maxRows) hole sizes × \(Self.maxCols) variants."
            }
            if tool.shape == .vBit { return "A V-bit cannot mill round holes — pick a flat end mill or corn bit." }
            if cut <= 0 { return "The bit needs a diameter." }
            if tool.cutDepth >= 0 { return "The bit's depth must be below the surface (negative)." }
            if diameters.contains(where: { $0 + (offsets.max() ?? 0) < cut - 1e-6 }) {
                return String(format: "Every hole must be at least the bit's size (%.2f mm) in some variant.", cut)
            }
            return nil
        }
    }

    /// Milled holes in a grid — rows are nominal sizes, columns add a
    /// clearance — cut the way production mills holes: a helix down from the
    /// surface in passes of the bit's pass depth, then one clean-up circle at
    /// full depth. Fit a pin in each to find the size to design for.
    static func holeFitTest(_ spec: HoleFitSpec) -> (gcode: String, legend: String)? {
        guard spec.problem == nil else { return nil }
        let t = spec.cut
        let depth = -abs(spec.tool.cutDepth)
        let step = spec.tool.depthPerPass > 0 ? min(spec.tool.depthPerPass, -depth) : -depth
        let turns = max(1, Int(ceil(-depth / step - 1e-9)))
        let pitch = spec.pitch
        let m = HoleFitSpec.margin
        let size = spec.size
        func f(_ v: Double) -> String { String(format: "%.4f", v) }
        func mm(_ v: Double) -> String { String(format: "%.2f", v) }
        func variant(_ o: Double) -> String { o == 0 ? "±0" : String(format: "%+.2f", o) }

        var g: [String] = [
            "( CNC G-Coder hole fit test )",
            "( \(spec.tool.name): \(mm(t)) mm, depth \(mm(depth)) mm in \(turns) helix turn\(turns == 1 ? "" : "s"), feed \(Int(spec.tool.feedXY)) mm/min )",
            "( Board \(Int(ceil(size.w))) x \(Int(ceil(size.h))) mm. Zero X/Y at its lower-left corner, Z0 on the surface. )",
            "( Rows = nominal size, row 1 at the bottom; columns = variant, A at the left; see the legend. )",
            "G21 G90 G94",
            String(format: "G0 Z%.3f", spec.zsafe),
            String(format: "%@ S%.0f", spec.tool.spindleCCW ? "M4" : "M3", spec.tool.spindle)
        ]
        if spec.tool.dwell > 0 { g.append(String(format: "G4 P%.1f", spec.tool.dwell)) }

        func plungeTo(_ z: Double) {
            if spec.plungeClearance > 0, spec.plungeClearance < spec.zsafe {
                g.append(String(format: "G0 Z%.3f", spec.plungeClearance))
            }
            g.append("G1 Z\(f(z)) F\(Int(spec.tool.feedZ))")
        }

        var table: [[String]] = []
        for (r, nominal) in spec.diameters.enumerated() {
            var row: [String] = []
            for (c, offset) in spec.offsets.enumerated() {
                let d = nominal + offset
                let label = "\(String(columnLetters[c]))\(r + 1)"
                let cx = m + pitch / 2 + Double(c) * pitch
                let cy = m + pitch / 2 + Double(r) * pitch
                guard d >= t - 1e-6 else {
                    g.append("( \(label): \(mm(d)) mm skipped, smaller than the bit )")
                    row.append("  —  ")
                    continue
                }
                row.append(mm(d))
                let radius = (d - t) / 2
                g.append("( \(label): \(mm(d)) mm = \(mm(nominal)) \(variant(offset)) )")
                g.append(String(format: "G0 Z%.3f", spec.zsafe))
                g.append("G0 X\(f(cx + radius)) Y\(f(cy))")
                if radius < 0.005 {
                    // The bit's own size: a straight plunge.
                    plungeTo(depth)
                } else {
                    plungeTo(0)
                    g.append("G1 F\(Int(spec.tool.feedXY))")
                    for k in 1...turns {
                        let z = depth * Double(k) / Double(turns)
                        g.append("G2 X\(f(cx + radius)) Y\(f(cy)) Z\(f(z)) I\(f(-radius)) J0.0000")
                    }
                    g.append("G2 X\(f(cx + radius)) Y\(f(cy)) I\(f(-radius)) J0.0000 ( clean-up at full depth )")
                    g.append("G1 X\(f(cx)) Y\(f(cy)) ( off the wall before retracting )")
                }
                g.append(String(format: "G0 Z%.3f", spec.zsafe))
            }
            table.append(row)
        }

        // Orientation mark: one plunge above the top-left hole.
        let markX = m + pitch / 2
        let markY = m + Double(spec.diameters.count) * pitch + t / 2 + 1
        g.append("( orientation mark: top-left )")
        g.append("G0 X\(f(markX)) Y\(f(markY))")
        plungeTo(depth)
        g.append(String(format: "G0 Z%.3f", spec.zsafe))
        g += ["M5", "G0 X0 Y0", "M2"]

        var legend = "CNC G-Coder — hole fit test legend\n"
        legend += "Bit: \(spec.tool.name), \(mm(t)) mm · depth \(mm(depth)) mm · feed \(Int(spec.tool.feedXY)) mm/min · spindle \(Int(spec.tool.spindle)) rpm\n"
        legend += "Board: \(Int(ceil(size.w))) × \(Int(ceil(size.h))) mm, X/Y zero at its lower-left corner. The single hole at the top-left marks the orientation.\n\n"
        legend += "Hole diameters (mm). Rows = nominal size (row 1 at the bottom), columns = variant (A at the left):\n\n"
        legend += String(repeating: " ", count: 12) + spec.offsets.enumerated().map { c, o in
            "\(String(columnLetters[c])) \(variant(o))".padding(toLength: 9, withPad: " ", startingAt: 0)
        }.joined() + "\n"
        for (r, row) in table.enumerated().reversed() {
            legend += String(format: "  %d  %6.2f  ", r + 1, spec.diameters[r])
            legend += row.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined() + "\n"
        }
        legend += "\nTry the pin in each hole of its row. Pick the variant with the fit you want — push-in, sliding or loose — and design that hole at nominal + variant. "
        legend += "The variant you find comes from this bit and machine, so it carries over to other hole sizes milled with the same bit.\n"
        return (g.joined(separator: "\n") + "\n", legend)
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
