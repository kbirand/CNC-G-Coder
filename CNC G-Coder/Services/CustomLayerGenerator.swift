import Foundation
import CoreGraphics

/// Turns a drawn layer into a G-code program, in-app (no pcb2gcode). The
/// program follows the same conventions as the generated ones: metric G90,
/// spindle dwell in seconds, two-stage plunges through the plunge clearance,
/// and the project's origin — shapes are drawn in design coordinates and
/// mapped into the front or back program frame exactly as pcb2gcode's
/// outputs are (see ProjectFrame.designToFront / designToBack).
nonisolated enum CustomLayerGenerator {

    /// Where the programs' X0/Y0 is, per side, for mapping design coordinates.
    struct ProgramFrame: Sendable {
        var frame: ProjectFrame?
        /// Used only without a frame (zeroing off): the mirror pcb2gcode applies.
        var mirrorAxis: Double
        var mirrorYAxis: Bool

        init(frame: ProjectFrame?, mirrorAxis: Double, mirrorYAxis: Bool) {
            self.frame = frame
            self.mirrorAxis = mirrorAxis
            self.mirrorYAxis = mirrorYAxis
        }

        init(document: PreviewDocument?, mirrorAxis: Double, mirrorYAxis: Bool) {
            if let document {
                self.init(frame: document.frame, mirrorAxis: document.mirrorAxis, mirrorYAxis: document.mirrorYAxis)
            } else {
                self.init(frame: nil, mirrorAxis: mirrorAxis, mirrorYAxis: mirrorYAxis)
            }
        }

        /// Design (Gerber) coordinates → the program coordinates of one side.
        func designToProgram(back: Bool) -> CGAffineTransform {
            if let frame { return back ? frame.designToBack : frame.designToFront }
            guard back else { return .identity }
            return mirrorYAxis
                ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * mirrorAxis)
                : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * mirrorAxis, ty: 0)
        }
    }

    /// One tool pass: a path the tool centre follows, in design mm.
    struct Pass: Sendable {
        var path: Polyline
        var shapeID: UUID
    }

    // MARK: - Toolpath planning

    /// Every pass the layer needs, in machining order. Stroke widths wider
    /// than the tool become several overlapping passes; inside/outside cuts
    /// offset by half the tool so the drawn size is what comes out; filled
    /// shapes are pocketed inside-out before their outline passes.
    static func passes(for layer: CustomLayer) -> [Pass] {
        let d = max(layer.toolDiameter, 0.001)
        let step = max(d * (1 - min(max(layer.overlap, 0), 99) / 100), 0.02)
        var passes: [Pass] = []

        for var shape in layer.shapes {
            // Holes cut inside are enlarged by the hole tolerance.
            if layer.effectiveOperation == .inside, layer.holeTolerance != 0,
               case .circle(let center, let diameter) = shape.geometry {
                shape.geometry = .circle(center: center, diameter: max(diameter + layer.holeTolerance, 0.01))
            }
            let outlines = shape.outlines().map(ShapeMath.cleaned)
            // Glyphs (and any nested contour) have holes: a hole's "outside" is
            // the body of the letter, so offsets flip sign for them.
            let holes = holeFlags(outlines)
            for (index, outline) in outlines.enumerated() where !outline.points.isEmpty {
                let closed = outline.closed && outline.points.count >= 3
                let sign: Double = holes[index] ? -1 : 1
                let width = max(shape.strokeWidth, d)
                let operation = closed ? layer.effectiveOperation : .engrave

                // The band of material to clear, as offsets from the drawn line
                // (positive = outward / left), then the tool-centre offsets that
                // sweep it, finishing with the pass that touches the line.
                let band: (inner: Double, outer: Double) = switch operation {
                case .engrave: (-width / 2, width / 2)
                case .outside: (0, width)
                case .inside: (-width, 0)
                }
                let lo = band.inner + d / 2, hi = band.outer - d / 2

                if shape.filled, closed, !holes[index], !isText(shape) {
                    // Pocketed inside-out, ending on the ring half a tool in from
                    // the line — which an inside cut's own passes finish on, so
                    // there it is left to them instead of being cut twice.
                    var rings = ShapeMath.pocketRings(outline, toolDiameter: d, stepOver: step)
                    if operation == .inside, !rings.isEmpty { rings.removeLast() }
                    for ring in rings {
                        passes.append(Pass(path: ring, shapeID: shape.id))
                    }
                }
                var offsets: [Double]
                if hi - lo < 1e-6 {
                    offsets = [(lo + hi) / 2]
                } else {
                    let n = Int(ceil((hi - lo) / step - 1e-9))
                    offsets = (0...n).map { lo + (hi - lo) * Double($0) / Double(n) }
                }
                switch operation {
                case .outside: offsets.reverse()     // far passes first, the finishing pass last
                case .inside, .engrave: break
                }
                for offset in offsets {
                    let delta = offset * sign
                    if outline.points.count == 1 {
                        passes.append(Pass(path: outline, shapeID: shape.id))   // a dot: plunge only
                    } else if let path = ShapeMath.offset(outline, by: delta) {
                        passes.append(Pass(path: path, shapeID: shape.id))
                    }
                }
            }
        }
        return passes
    }

    private static func isText(_ shape: DrawnShape) -> Bool {
        if case .text = shape.geometry { return true }
        return false
    }

    /// Even-odd nesting: a contour inside an odd number of others is a hole.
    private static func holeFlags(_ outlines: [Polyline]) -> [Bool] {
        outlines.enumerated().map { index, outline in
            guard outline.closed, let sample = outline.points.first else { return false }
            var depth = 0
            for (other, candidate) in outlines.enumerated() where other != index && candidate.closed {
                if ShapeMath.contains(candidate, sample) { depth += 1 }
            }
            return depth % 2 == 1
        }
    }

    // MARK: - G-code

    /// Z levels the cut is taken in, deepest last.
    static func depths(cutDepth: Double, depthPerPass: Double) -> [Double] {
        let total = abs(cutDepth)
        guard depthPerPass > 1e-9, depthPerPass < total - 1e-9 else { return [cutDepth] }
        let n = Int(ceil(total / depthPerPass - 1e-9))
        return (1...n).map { max(cutDepth, -depthPerPass * Double($0)) }
    }

    /// The whole program for one layer, or nil when there is nothing to cut.
    static func gcode(for layer: CustomLayer, frame: ProgramFrame, zSafe machineSafe: Double, zChange: Double,
                      plungeClearance: Double) -> String? {
        if layer.type == .drill {
            return drillGcode(for: layer, frame: frame, zSafe: machineSafe, zChange: zChange, plungeClearance: plungeClearance)
        }
        let passes = passes(for: layer)
        guard !passes.isEmpty else { return nil }
        let zSafe = layer.travelZ > 0 ? layer.travelZ : machineSafe
        let zEnd = layer.endZ > 0 ? layer.endZ : zChange
        let toProgram = frame.designToProgram(back: layer.back)
        let clearance = plungeClearance > 0 && plungeClearance < zSafe ? plungeClearance : 0
        let levels = depths(cutDepth: layer.cutDepth, depthPerPass: layer.depthPerPass)
        func f(_ v: Double) -> String { String(format: "%.4f", abs(v) < 5e-5 ? 0 : v) }

        var g: [String] = []
        g.append("( CNC G-Coder custom layer: \(layer.name) )")
        g.append("( \(layer.type.title.lowercased()) · \(layer.back ? "back" : "front") side · \(layer.effectiveOperation.title.lowercased()) · tool \(ParametersStore.format(layer.toolDiameter)) mm · depth \(ParametersStore.format(layer.cutDepth)) mm )")
        g.append("( \(layer.shapes.count) shape\(layer.shapes.count == 1 ? "" : "s"), \(passes.count) pass\(passes.count == 1 ? "" : "es") )")
        g.append("G94 ( mm/min feed )")
        g.append("G21 ( metric )")
        g.append("G90 ( absolute )")
        g.append("S\(Int(layer.spindle.rounded()))")
        g.append(layer.spindleCCW ? "M4 ( spindle on counter-clockwise )" : "M3 ( spindle on )")
        if layer.dwell > 0 { g.append("G4 P\(ParametersStore.format(layer.dwell))") }
        g.append("G0 Z\(f(zSafe))")

        for pass in passes {
            let pts = pass.path.points.map { $0.applying(toProgram) }
            guard let start = pts.first else { continue }
            let closed = pass.path.closed && pts.count >= 3
            g.append("G0 X\(f(start.x)) Y\(f(start.y))")
            if clearance > 0 { g.append("G0 Z\(f(clearance))") }
            for (level, depth) in levels.enumerated() {
                g.append("G1 Z\(f(depth)) F\(ParametersStore.format(layer.feedZ))")
                guard pts.count >= 2 else { continue }
                g.append("G1 F\(ParametersStore.format(layer.feedXY))")
                // Closed loops repeat at each depth from their start; open
                // paths run back and forth, so no retract between levels.
                let route: [CGPoint] = closed
                    ? Array(pts.dropFirst()) + [start]
                    : (level % 2 == 0 ? Array(pts.dropFirst()) : Array(pts.reversed().dropFirst()))
                for p in route { g.append("G1 X\(f(p.x)) Y\(f(p.y))") }
                // Extra cut: a closed loop runs on past its start at the last depth.
                if closed, level == levels.count - 1, layer.extraCut > 0 {
                    for p in extraCut(pts, length: layer.extraCut) { g.append("G1 X\(f(p.x)) Y\(f(p.y)) ( extra cut )") }
                }
            }
            if clearance > 0 {
                g.append("G1 Z\(f(clearance)) F\(ParametersStore.format(layer.feedZ))")
                g.append("G0 Z\(f(zSafe))")
            } else {
                g.append("G1 Z\(f(zSafe)) F\(ParametersStore.format(layer.feedZ))")
            }
        }

        if zEnd > zSafe + 1e-9 { g.append("G0 Z\(f(zEnd)) ( end height )") }
        g.append("M5 ( spindle off )")
        if layer.dwell > 0 { g.append("G4 P\(ParametersStore.format(layer.dwell))") }
        g.append("M2 ( program end )")
        return g.joined(separator: "\n") + "\n"
    }

    /// Drill layers: the centre of every circle, nearest-neighbour ordered.
    static func drillPoints(for layer: CustomLayer) -> [CGPoint] {
        var remaining: [CGPoint] = layer.shapes.compactMap {
            if case .circle(let center, _) = $0.geometry { return center }
            return nil
        }
        var out: [CGPoint] = []
        var cursor = CGPoint.zero
        while let i = remaining.indices.min(by: { ShapeMath.distance(remaining[$0], cursor) < ShapeMath.distance(remaining[$1], cursor) }) {
            cursor = remaining.remove(at: i)
            out.append(cursor)
        }
        return out
    }

    /// A drill layer's program: one plunge per circle, pecking by Depth per
    /// pass (out to the plunge clearance between pecks to clear chips).
    private static func drillGcode(for layer: CustomLayer, frame: ProgramFrame, zSafe machineSafe: Double,
                                   zChange: Double, plungeClearance: Double) -> String? {
        let points = drillPoints(for: layer).map { $0.applying(frame.designToProgram(back: layer.back)) }
        guard !points.isEmpty else { return nil }
        let zSafe = layer.travelZ > 0 ? layer.travelZ : machineSafe
        let zEnd = layer.endZ > 0 ? layer.endZ : zChange
        let clearance = plungeClearance > 0 && plungeClearance < zSafe ? plungeClearance : 0
        let levels = depths(cutDepth: layer.cutDepth, depthPerPass: layer.depthPerPass)
        let feed = ParametersStore.format(layer.feedZ)
        func f(_ v: Double) -> String { String(format: "%.4f", abs(v) < 5e-5 ? 0 : v) }
        let skipped = layer.shapes.count - points.count

        var g: [String] = []
        g.append("( CNC G-Coder custom layer: \(layer.name) )")
        g.append("( drill · \(layer.back ? "back" : "front") side · drill \(ParametersStore.format(layer.toolDiameter)) mm · depth \(ParametersStore.format(layer.cutDepth)) mm )")
        g.append("( \(points.count) hole\(points.count == 1 ? "" : "s")\(skipped > 0 ? ", \(skipped) non-circle shape\(skipped == 1 ? "" : "s") ignored" : "") )")
        g.append("G94 ( mm/min feed )")
        g.append("G21 ( metric )")
        g.append("G90 ( absolute )")
        g.append("S\(Int(layer.spindle.rounded()))")
        g.append(layer.spindleCCW ? "M4 ( spindle on counter-clockwise )" : "M3 ( spindle on )")
        if layer.dwell > 0 { g.append("G4 P\(ParametersStore.format(layer.dwell))") }
        g.append("G0 Z\(f(zSafe))")
        for p in points {
            g.append("G0 X\(f(p.x)) Y\(f(p.y))")
            if clearance > 0 { g.append("G0 Z\(f(clearance))") }
            for (i, depth) in levels.enumerated() {
                if i > 0 {
                    // Back down to just above the previous peck, then feed on.
                    g.append("G0 Z\(f(min(levels[i - 1] + 0.2, max(clearance, 0))))")
                }
                g.append("G1 Z\(f(depth)) F\(feed)")
                if i < levels.count - 1 { g.append("G0 Z\(f(max(clearance, 0.5)))") }
            }
            g.append("G0 Z\(f(zSafe))")
        }
        if zEnd > zSafe + 1e-9 { g.append("G0 Z\(f(zEnd)) ( end height )") }
        g.append("M5 ( spindle off )")
        if layer.dwell > 0 { g.append("G4 P\(ParametersStore.format(layer.dwell))") }
        g.append("M2 ( program end )")
        return g.joined(separator: "\n") + "\n"
    }

    /// Points continuing a closed loop past its start for `length` mm.
    static func extraCut(_ loop: [CGPoint], length: Double) -> [CGPoint] {
        var out: [CGPoint] = []
        var remaining = length
        guard var cursor = loop.first else { return out }
        for next in Array(loop.dropFirst()) + [loop[0]] {
            let d = ShapeMath.distance(cursor, next)
            guard d > 1e-9 else { continue }
            if d >= remaining {
                let t = remaining / d
                out.append(CGPoint(x: cursor.x + (next.x - cursor.x) * t, y: cursor.y + (next.y - cursor.y) * t))
                return out
            }
            out.append(next)
            remaining -= d
            cursor = next
        }
        return out
    }

    /// The origin frame of a project that has ONLY drawn layers. With Gerbers,
    /// Pcb2GcodeService.normalizeOrigins measures the project from their
    /// programs; without any there is no board to zero on, and the drawing
    /// must stay where it was drawn — a circle drawn at X1 Y−1 is cut at
    /// X1 Y−1. So X0 Y0 is the drawing sheet's own origin, unless the origin
    /// was moved to a custom point (dragging the marker, Set Origin). The
    /// corner / centre modes are NOT applied here: tied to the drawing's
    /// extent, they would shift everything each time a shape is added.
    /// Nil with zeroing off — the programs then keep the drawing's coordinates.
    static func frame(layers: [CustomLayer], params p: ParameterSnapshot) -> ProjectFrame? {
        guard p.zeroStart else { return nil }
        var rect = CGRect.null
        for layer in layers { if let b = layer.bounds { rect = rect.union(b) } }
        // Nothing drawn yet: the frame still exists (the editor places the
        // first shape through it). The mapping does not depend on the extent
        // — the origin is a fixed design point — so an empty one will do.
        if rect.isNull { rect = .zero }
        var fixed = p
        if fixed.originMode != "custom" {
            fixed.originMode = "custom"
            fixed.originX = "0"
            fixed.originY = "0"
        }
        let origin = Pcb2GcodeService.origins(fixed, rect: rect)
        return ProjectFrame(rect: rect, frontOrigin: origin.front, backOrigin: origin.back, mirrorYAxis: p.mirrorYAxis)
    }

    /// Writes every non-empty layer's program into `outputDir`, named like
    /// the other programs (LayerKind.fileSlug), and returns what was written.
    static func write(layers: [CustomLayer], params p: ParameterSnapshot, frame: ProjectFrame?,
                      outputDir: URL) -> (outputs: [GeneratedOutput], log: String) {
        var outputs: [GeneratedOutput] = []
        var log = ""
        let programFrame = ProgramFrame(frame: frame, mirrorAxis: Double(p.mirrorAxis) ?? 0, mirrorYAxis: p.mirrorYAxis)
        let zSafe = Double(p.zSafe) ?? 3
        let clearance = Double(p.plungeClearance) ?? 0
        let zChange = Double(p.zChange) ?? zSafe
        for (index, layer) in layers.enumerated() where !layer.isEmpty {
            let kind = LayerKind.custom(layer.ref(index: index))
            if let problem = layer.validationError {
                log += "WARNING: custom layer \"\(layer.name)\" skipped — \(problem).\n"
                continue
            }
            guard let text = gcode(for: layer, frame: programFrame, zSafe: zSafe, zChange: zChange,
                                   plungeClearance: clearance) else {
                log += "Custom layer \"\(layer.name)\": nothing to cut.\n"
                continue
            }
            let url = Pcb2GcodeService.outputURL(for: kind, in: outputDir)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                outputs.append(GeneratedOutput(layer: kind, url: url, toolDiameter: layer.toolDiameter))
                let count = text.split(separator: "\n").count
                log += "Custom layer \"\(layer.name)\": \(layer.shapes.count) shape\(layer.shapes.count == 1 ? "" : "s") → \(url.lastPathComponent) (\(count) lines).\n"
            } catch {
                log += "ERROR writing \(url.lastPathComponent): \(error.localizedDescription)\n"
            }
        }
        return (outputs, log)
    }
}
