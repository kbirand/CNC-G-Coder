import SwiftUI

// The height map as the preview shows it (Candle-style): which map is drawn
// for the shown board side, whether it is being probed right now, and the
// surface colouring shared by the 2D canvas and the 3D scene.

/// A grid point of a height map.
nonisolated struct HeightMapIndex: Equatable, Hashable, Sendable {
    var row: Int
    var col: Int
}

/// What the preview overlays for the shown side: the live map while probing
/// (filling in point by point), otherwise the stored one.
struct HeightMapOverlay {
    var map: HeightMap
    var side: BoardSide
    /// Design → the side's program frame: the grid is drawn through it.
    var frame: CGAffineTransform
    /// A probe run is in progress and `map` is its live target.
    var probing: Bool
    /// While probing: the grid point the probe is at or heading for; nil
    /// when the reference at X0/Y0 is being probed (`probingReference`) or
    /// every point is in.
    var currentPoint: HeightMapIndex?
    var probingReference: Bool

    /// One line for the canvas legend.
    var legend: String {
        if probing {
            if probingReference { return "Probing the reference at X0/Y0" }
            return "Probing \(min(map.probedCount + 1, map.totalCount)) / \(map.totalCount)"
        }
        var text = "Height map: \(map.nx)×\(map.ny)"
        if let range = HeightMapSurface.range(map) {
            text += String(format: " · min %+.3f · max %+.3f mm", range.low, range.high)
        } else {
            text += " · not probed"
        }
        return text
    }
}

extension AppModel {
    /// The board side the height-map tab and the overlays work on: the side
    /// of the program shown in the preview, else the loaded machine
    /// program's, else the front. Each side has its own map because the
    /// board is flipped between them.
    var shownBoardSide: BoardSide {
        player.displayedKind?.boardSide ?? machine.streamer.program?.kind.boardSide ?? .front
    }

    /// The map to show for `side`: the probe run's live target while one is
    /// in progress, otherwise the stored map.
    func displayedHeightMap(side: BoardSide) -> HeightMap? {
        let streamer = machine.streamer
        if streamer.state == .probing, let live = streamer.heightMapTarget, live.side == side { return live }
        return heightMaps[side]
    }

    /// The overlay the preview draws, or nil when none is due. Shown when
    /// the View Options toggle is on, the Machine panel is on its Height Map
    /// tab, a probe run is in progress, or the loaded machine program was
    /// prepared with a map — and there is a map for the shown side.
    func heightMapOverlay(toggle: Bool, inspectorTab: String) -> HeightMapOverlay? {
        // The View Options toggle is the one switch: probing and the Height
        // Map tab turn it on for the user (see HeightMapTab / probe start),
        // they never override it, so turning it off always hides the map.
        _ = inspectorTab
        guard toggle else { return nil }
        let streamer = machine.streamer
        let probing = streamer.state == .probing
        let side = shownBoardSide
        guard let map = displayedHeightMap(side: side) else { return nil }
        let live = probing && streamer.heightMapTarget?.side == side
        return HeightMapOverlay(map: map, side: side, frame: heightMapFrame(side: side), probing: live,
                                currentPoint: live ? HeightMapSurface.nextProbe(map) : nil,
                                probingReference: live && map.referenceZ == nil)
    }
}

/// The interpolated surface between probed points, for drawing — Candle's
/// wireframe "interpolation grid": `interpolationX` × `interpolationY`
/// lines over the border, every segment coloured by the bilinear height at
/// its midpoint. Cells whose four corners are probed carry the surface;
/// the others lie flat at Z 0 in the neutral colour, so the whole
/// rectangle is visible before and during probing and fills in cell by
/// cell. (`HeightMap.interpolate` is the machining interpolation — it is 0
/// until the map is complete and clamps outside the grid; this is display
/// only.)
nonisolated enum HeightMapSurface {
    /// UserDefaults keys of the interpolation grid line counts.
    static let interpolationXKey = "machine.heightMap.interpX"
    static let interpolationYKey = "machine.heightMap.interpY"
    static let interpolationDefault = 20
    static let interpolationRange = 4...60

    /// A line count within `interpolationRange` (0 = not set → the default).
    static func clampedLines(_ value: Int) -> Int {
        value == 0 ? interpolationDefault : min(max(value, interpolationRange.lowerBound), interpolationRange.upperBound)
    }

    /// A segment of the interpolation grid: its ends and the height at its
    /// midpoint (nil over an unprobed cell: flat, neutral colour).
    struct Segment {
        var a: CGPoint
        var b: CGPoint
        var z: Double?
    }

    /// The bilinear display height at a point: inside the cell containing
    /// it (clamped onto the grid), nil unless that cell's corners are all
    /// probed.
    static func displayZ(_ map: HeightMap, x: Double, y: Double) -> Double? {
        guard map.nx >= 2, map.ny >= 2, map.stepX > 0, map.stepY > 0 else { return nil }
        func cell(_ v: Double, _ o: Double, _ step: Double, _ n: Int) -> (index: Int, t: Double) {
            let u = min(max((v - o) / step, 0), Double(n - 1))
            let i = min(Int(u.rounded(.down)), n - 2)
            return (i, u - Double(i))
        }
        let c = cell(x, map.origin.x, map.stepX, map.nx)
        let r = cell(y, map.origin.y, map.stepY, map.ny)
        guard let corners = corners(map, row: r.index, col: c.index) else { return nil }
        return bilinear(corners, u: c.t, v: r.t)
    }

    /// The wireframe: `linesX` lines parallel to Y and `linesY` lines
    /// parallel to X across the border, each split at the crossings with
    /// the other family, so every segment can take its own colour.
    static func wireframe(_ map: HeightMap, linesX: Int, linesY: Int) -> [Segment] {
        let nx = clampedLines(linesX), ny = clampedLines(linesY)
        guard map.size.width > 0, map.size.height > 0 else { return [] }
        var segments: [Segment] = []
        segments.reserveCapacity(nx * (ny - 1) + ny * (nx - 1))
        func x(_ i: Int) -> Double { map.origin.x + map.size.width * Double(i) / Double(nx - 1) }
        func y(_ j: Int) -> Double { map.origin.y + map.size.height * Double(j) / Double(ny - 1) }
        for i in 0..<nx {
            for j in 0..<(ny - 1) {
                let a = CGPoint(x: x(i), y: y(j)), b = CGPoint(x: x(i), y: y(j + 1))
                segments.append(Segment(a: a, b: b, z: displayZ(map, x: a.x, y: (a.y + b.y) / 2)))
            }
        }
        for j in 0..<ny {
            for i in 0..<(nx - 1) {
                let a = CGPoint(x: x(i), y: y(j)), b = CGPoint(x: x(i + 1), y: y(j))
                segments.append(Segment(a: a, b: b, z: displayZ(map, x: (a.x + b.x) / 2, y: a.y)))
            }
        }
        return segments
    }

    /// The neutral colour of the grid where nothing is probed yet (or the
    /// map has no spread).
    static let neutral = Color.teal
    static let neutralRGB = SIMD3<Float>(0.35, 0.78, 0.80)

    /// Whether the map's values span enough to colour by height.
    static func hasSpread(_ range: (low: Double, high: Double)?) -> Bool {
        guard let range else { return false }
        return range.high - range.low > 1e-6
    }

    /// Lowest and highest probed value; nil before the first point.
    static func range(_ map: HeightMap) -> (low: Double, high: Double)? {
        let values = map.points.flatMap { $0 }.compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, high)
    }

    /// 0 (lowest) … 1 (highest) within `range`; 0.5 for a flat map.
    static func unit(_ z: Double, in range: (low: Double, high: Double)) -> Double {
        let span = range.high - range.low
        guard span > 1e-6 else { return 0.5 }
        return min(max((z - range.low) / span, 0), 1)
    }

    /// Blue (0) through green and yellow to red (1), like Candle's surface.
    static func color(unit t: Double) -> Color {
        Color(hue: 0.66 * (1 - t), saturation: 0.85, brightness: 0.95)
    }

    /// The same colour as RGB components, for vertex colours.
    static func rgb(unit t: Double) -> SIMD3<Float> {
        hsb(hue: 0.66 * (1 - t), saturation: 0.85, brightness: 0.95)
    }

    private static func hsb(hue: Double, saturation s: Double, brightness v: Double) -> SIMD3<Float> {
        let h = (hue - hue.rounded(.down)) * 6
        let i = Int(h.rounded(.down))
        let f = h - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return SIMD3(Float(r), Float(g), Float(b))
    }

    /// The probed value at a grid point, nil when not probed (or the table
    /// does not have that shape).
    static func value(_ map: HeightMap, at index: HeightMapIndex) -> Double? {
        guard map.points.indices.contains(index.row), map.points[index.row].indices.contains(index.col) else { return nil }
        return map.points[index.row][index.col]
    }

    /// The four corners of cell (row, col) — rows `row`/`row+1`, columns
    /// `col`/`col+1` — when all are probed.
    static func corners(_ map: HeightMap, row: Int, col: Int) -> (z00: Double, z01: Double, z10: Double, z11: Double)? {
        guard let z00 = value(map, at: HeightMapIndex(row: row, col: col)),
              let z01 = value(map, at: HeightMapIndex(row: row, col: col + 1)),
              let z10 = value(map, at: HeightMapIndex(row: row + 1, col: col)),
              let z11 = value(map, at: HeightMapIndex(row: row + 1, col: col + 1)) else { return nil }
        return (z00, z01, z10, z11)
    }

    /// Bilinear height at fractions (u along X, v along Y) of a cell.
    static func bilinear(_ c: (z00: Double, z01: Double, z10: Double, z11: Double), u: Double, v: Double) -> Double {
        let bottom = c.z00 * (1 - u) + c.z01 * u
        let top = c.z10 * (1 - u) + c.z11 * u
        return bottom * (1 - v) + top * v
    }

    /// The grid point the probe run is at or heading for: the points come
    /// in `probeOrder()`, so it is the one after the last recorded. Nil
    /// before the reference is in and once every point is.
    static func nextProbe(_ map: HeightMap) -> HeightMapIndex? {
        guard map.referenceZ != nil else { return nil }
        let order = map.probeOrder()
        let count = map.probedCount
        guard order.indices.contains(count) else { return nil }
        return HeightMapIndex(row: order[count].row, col: order[count].col)
    }

    /// The last recorded point and its value.
    static func lastProbed(_ map: HeightMap) -> (index: HeightMapIndex, z: Double)? {
        let order = map.probeOrder()
        for p in order.reversed() {
            let index = HeightMapIndex(row: p.row, col: p.col)
            if let z = value(map, at: index) { return (index, z) }
        }
        return nil
    }

    /// Number of colour bins the 2D wireframe is bucketed into: one path
    /// per bin keeps the per-frame cost to a few strokes.
    static let colorBins = 24

    /// The wireframe as stroked paths bucketed by colour (the rainbow ramp
    /// by height, or everything in `neutral` while the map has no spread).
    /// World mm in the map's own frame.
    static func wireframePaths(_ map: HeightMap, linesX: Int, linesY: Int) -> [(path: Path, color: Color)] {
        let range = range(map)
        let coloured = hasSpread(range)
        var bins = Array(repeating: Path(), count: colorBins)
        var flat = Path()
        for segment in wireframe(map, linesX: linesX, linesY: linesY) {
            if coloured, let range, let z = segment.z {
                let bin = min(colorBins - 1, Int(unit(z, in: range) * Double(colorBins)))
                bins[bin].move(to: segment.a)
                bins[bin].addLine(to: segment.b)
            } else {
                flat.move(to: segment.a)
                flat.addLine(to: segment.b)
            }
        }
        var result: [(path: Path, color: Color)] = []
        if !flat.isEmpty { result.append((flat, neutral)) }
        for (index, path) in bins.enumerated() where !path.isEmpty {
            result.append((path, color(unit: (Double(index) + 0.5) / Double(colorBins))))
        }
        return result
    }
}
