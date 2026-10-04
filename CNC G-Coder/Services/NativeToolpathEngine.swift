import Foundation
import CoreGraphics

/// The in-app alternative to pcb2gcode: reads the Gerber and Excellon files
/// itself (LayerFileFormats), builds the copper geometry with Clipper2 and
/// writes one program per layer — named, laid out and commented the way
/// pcb2gcode writes them, so every later step (dwells, pecks, plunge
/// clearance, extra cut, spindle direction, origins, the preview) treats
/// both engines' programs alike.
///
/// Coordinates are those pcb2gcode writes before zeroing: the Gerber frame
/// for the front, mirrored about the mirror axis for the back.
nonisolated enum NativeToolpathEngine {

    struct Result: Sendable {
        var outputs: [GeneratedOutput] = []
        var log = ""
        var succeeded = true
    }

    static func run(_ p: ParameterSnapshot, files: DetectedFiles, outputDir: URL) -> Result {
        var result = Result()
        let board = files.outline.flatMap { try? GerberFile.read($0) }.map(boardPolygons) ?? []

        func write(_ layer: LayerKind, _ text: String?, tool: String?) {
            guard let text else { return }
            let url = Pcb2GcodeService.outputURL(for: layer, in: outputDir)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                result.outputs.append(GeneratedOutput(layer: layer, url: url, toolDiameter: tool.flatMap(Double.init)))
            } catch {
                result.log += "ERROR writing \(url.lastPathComponent): \(error.localizedDescription)\n"
                result.succeeded = false
            }
        }
        func read(_ url: URL) -> GerberImage? {
            do { return try GerberFile.read(url) } catch {
                result.log += "ERROR reading \(url.lastPathComponent): \(error.localizedDescription)\n"
                result.succeeded = false
                return nil
            }
        }

        // Copper isolation.
        for (slot, layer) in [(LayerSlot.front, LayerKind.front), (.back, .back)] {
            guard let url = files[slot], let image = read(url) else { continue }
            let started = Date()
            let paths = isolation(copper: copper(image), board: board,
                                  diameter: num(p.millDiameter), width: num(p.isolationWidth),
                                  overlap: num(p.millOverlap), inward: false)
            write(layer, millProgram(paths, layer: layer, p: p, group: .iso,
                                     depth: num(p.zWork), depthPerPass: num(p.millInfeed),
                                     feed: p.millFeed, vertFeed: p.millVertFeed, speed: p.millSpeed,
                                     note: "mill diameter \(p.millDiameter)mm"), tool: p.millDiameter)
            result.log += "Native: \(layer.displayName) — \(paths.count) paths (\(elapsed(started))).\n"
        }

        // Board outline.
        if files.outline != nil, !board.isEmpty {
            write(.outline, outlineProgram(board, p: p), tool: p.cutterDiameter)
            result.log += "Native: Outline — \(board.count) contour\(board.count == 1 ? "" : "s").\n"
        } else if files.outline != nil {
            result.log += "WARNING: native engine found no closed contour in the board outline.\n"
        }

        // Drilling (and milled holes).
        for (index, url) in files.drills.enumerated() {
            let stem = url.deletingPathExtension().lastPathComponent
            let image: ExcellonImage
            do { image = try ExcellonFile.read(url) } catch {
                result.log += "ERROR reading \(url.lastPathComponent): \(error.localizedDescription)\n"
                result.succeeded = false
                continue
            }
            let (drill, milled, log) = drillPrograms(image, p: p)
            write(.drill(index: index, name: stem), drill, tool: nil)
            if p.drillMillLarge { write(.millDrill(index: index, name: stem), milled, tool: p.holeMillDiameter) }
            result.log += log
        }

        // Mask and legend: the tool clears the inside of each shape.
        func inward(_ slot: LayerSlot, _ layer: LayerKind, group: ParametersStore.MotionGroup,
                    tool: String, width: String, overlap: String, depth: String,
                    feed: String, vertFeed: String, speed: String) {
            guard let url = files[slot], let image = read(url) else { return }
            let paths = isolation(copper: copper(image), board: [], diameter: num(tool), width: num(width),
                                  overlap: num(overlap), inward: true)
            write(layer, millProgram(paths, layer: layer, p: p, group: group, depth: num(depth),
                                     depthPerPass: 0, feed: feed, vertFeed: vertFeed, speed: speed,
                                     note: "mill diameter \(tool)mm"), tool: tool)
            result.log += "Native: \(layer.displayName) — \(paths.count) paths.\n"
        }
        if p.maskMode == "gcode" {
            inward(.topMask, .maskTop, group: .mask, tool: p.maskTool, width: p.maskClearWidth, overlap: p.maskOverlap,
                   depth: p.maskDepth, feed: p.maskFeed, vertFeed: p.maskVertFeed, speed: p.maskSpeed)
            inward(.bottomMask, .maskBottom, group: .mask, tool: p.maskTool, width: p.maskClearWidth, overlap: p.maskOverlap,
                   depth: p.maskDepth, feed: p.maskFeed, vertFeed: p.maskVertFeed, speed: p.maskSpeed)
        }
        if p.silkMode == "gcode" {
            inward(.topSilk, .silkTop, group: .silk, tool: p.silkTool, width: p.silkClearWidth, overlap: p.silkOverlap,
                   depth: p.silkDepth, feed: p.silkFeed, vertFeed: p.silkVertFeed, speed: p.silkSpeed)
            inward(.bottomSilk, .silkBottom, group: .silk, tool: p.silkTool, width: p.silkClearWidth, overlap: p.silkOverlap,
                   depth: p.silkDepth, feed: p.silkFeed, vertFeed: p.silkVertFeed, speed: p.silkSpeed)
        }
        return result
    }

    // MARK: - Geometry

    /// Everything a Gerber image covers, as polygons (design mm): dark
    /// objects added and clear ones cut away in file order.
    static func copper(_ image: GerberImage) -> Clipper.Paths {
        var result: Clipper.Paths = []
        var index = 0
        let objects = image.objects
        while index < objects.count {
            // One run of objects with the same polarity at a time.
            let dark = objects[index].dark
            var shapes: Clipper.Paths = []
            var strokes: [String: (width: Double, square: Bool, lines: Clipper.Paths)] = [:]
            while index < objects.count, objects[index].dark == dark {
                let object = objects[index]
                index += 1
                switch object.kind {
                case .track(let a, let path):
                    let width = image.trackWidth(aperture: a)
                    let square = image.apertures[a]?.shape == .rectangle
                    let key = "\(width)|\(square)"
                    strokes[key, default: (width, square, [])].lines.append(path.flattened())
                case .flash(let a, let at):
                    shapes += image.flashOutlines(aperture: a, at: at).filter { $0.points.count >= 3 }.map(\.points)
                case .region(let contours):
                    shapes += Clipper.union(contours.map { $0.flattened() }, fill: .evenOdd)
                }
            }
            for (_, stroke) in strokes where stroke.width > 0 {
                shapes += Clipper.inflate(stroke.lines, by: stroke.width / 2, join: .round,
                                          end: stroke.square ? .square : .round)
            }
            let group = Clipper.union(shapes)
            result = dark ? Clipper.union(result + group) : Clipper.difference(result, group)
        }
        return result
    }

    /// The board: the region enclosed by the outline's centre lines (as
    /// pcb2gcode's --fill-outline takes it), cutouts inside as holes.
    static func boardPolygons(_ image: GerberImage) -> Clipper.Paths {
        var pieces = image.objects.compactMap { object -> [CGPoint]? in
            if case .track(_, let path) = object.kind { return path.flattened() }
            if case .region(let contours) = object.kind { return contours.first?.flattened() }
            return nil
        }.filter { $0.count >= 2 }
        // Chain pieces end to end into closed loops.
        var loops: Clipper.Paths = []
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.01 }
        while !pieces.isEmpty {
            var loop = pieces.removeFirst()
            var extended = true
            while extended, !near(loop.first!, loop.last!) {
                extended = false
                for (i, piece) in pieces.enumerated() {
                    if near(loop.last!, piece.first!) { loop += piece.dropFirst() }
                    else if near(loop.last!, piece.last!) { loop += piece.reversed().dropFirst() }
                    else if near(loop.first!, piece.last!) { loop = piece + loop.dropFirst() }
                    else if near(loop.first!, piece.first!) { loop = piece.reversed() + loop.dropFirst() }
                    else { continue }
                    pieces.remove(at: i)
                    extended = true
                    break
                }
            }
            if loop.count >= 3, near(loop.first!, loop.last!) { loops.append(Array(loop.dropLast())) }
        }
        return Clipper.union(loops, fill: .evenOdd)
    }

    /// Isolation passes around the copper (outward), or clearing passes
    /// inside the shapes (inward, for mask and legend). As many passes as
    /// the width needs with the overlap (ParametersStore.passes), spread
    /// evenly so the first grazes the copper (d/2 away) and the last clears
    /// exactly the width — as pcb2gcode does. Clipped to the board.
    static func isolation(copper: Clipper.Paths, board: Clipper.Paths, diameter d: Double, width: Double,
                          overlap: Double, inward: Bool) -> Clipper.Paths {
        guard d > 0, !copper.isEmpty else { return [] }
        let w = max(width, d)
        let passes = ParametersStore.passes(width: w, diameter: d, overlapPercent: overlap)
        let step = passes > 1 ? (w - d) / Double(passes - 1) : 0
        var rings: Clipper.Paths = []
        for i in 0..<passes {
            let offset = d / 2 + Double(i) * step
            let ring = Clipper.inflate(copper, by: inward ? -offset : offset)
            if ring.isEmpty { break }
            rings += ring.map { $0 + [$0[0]] }   // closed
        }
        guard !board.isEmpty else { return rings }
        // Keep only what runs over the board (pcb2gcode masks with the outline).
        return Clipper.clipLines(rings, to: board)
    }

    // MARK: - Programs

    private static func num(_ s: String) -> Double { Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private static func f(_ v: Double) -> String { String(format: "%.5f", abs(v) < 5e-6 ? 0 : v) }
    private static func elapsed(_ since: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(since)) }

    private static func header(_ out: inout [String], speed: String) {
        out += ["( CNC G-Coder native engine )",
                "G94 ( Millimeters per minute feed rate. )",
                "G21 ( Units == Millimeters. )",
                "G90 ( Absolute coordinates. )",
                "G00 S\(speed) ( RPM spindle speed. )"]
    }

    private static func toolChange(_ out: inout [String], zChange: Double, number: Int, message: String) {
        out += ["G00 Z\(f(zChange)) (Retract to tool change height)",
                "T\(number)",
                "M5 (Spindle stop.)",
                "G04 P1.00000 (Wait for spindle to stop)",
                "(MSG, \(message))",
                "M6 (Tool change.)",
                "M0 (Temporary machine stop.)",
                "M3 ( Spindle on clockwise. )",
                "G04 P1.00000 (Wait for spindle to get up to speed)"]
    }

    private static func footer(_ out: inout [String], zChange: Double) {
        out += ["G00 Z\(f(zChange)) ( All done -- retract )",
                "M5 ( Spindle off. )",
                "G04 P1.00000",
                "M9 ( Coolant off. )",
                "M2 ( Program end. )"]
    }

    /// Design → program coordinates before zeroing (pcb2gcode's mirror).
    private static func toProgram(_ layer: LayerKind, _ p: ParameterSnapshot) -> CGAffineTransform {
        CustomLayerGenerator.ProgramFrame(frame: nil, mirrorAxis: num(p.mirrorAxis), mirrorYAxis: p.mirrorYAxis)
            .designToProgram(back: layer.isBackSide)
    }

    /// Paths in a short order: each next one is the nearest, closed ones
    /// entered at their nearest point; oriented for the milling direction.
    static func ordered(_ paths: Clipper.Paths, climb: Bool?) -> Clipper.Paths {
        var remaining = paths.filter { $0.count >= 2 }
        var out: Clipper.Paths = []
        var cursor = CGPoint.zero
        while !remaining.isEmpty {
            var best = (index: 0, point: 0, distance: Double.infinity)
            for (i, path) in remaining.enumerated() {
                let closed = path.count > 2 && hypot(path[0].x - path.last!.x, path[0].y - path.last!.y) < 1e-6
                let candidates = closed ? Array(path.indices.dropLast()) : [0, path.count - 1]
                for k in candidates {
                    let d = hypot(path[k].x - cursor.x, path[k].y - cursor.y)
                    if d < best.distance { best = (i, k, d) }
                }
            }
            var path = remaining.remove(at: best.index)
            let closed = path.count > 2 && hypot(path[0].x - path.last!.x, path[0].y - path.last!.y) < 1e-6
            if closed {
                var ring = Array(path.dropLast())
                // Clipper rings run with the material on their left; climb
                // milling (M3) wants it on the right.
                if let climb {
                    let ccw = Clipper.area(ring) > 0
                    if climb == ccw { ring.reverse() }
                }
                let start = ring.firstIndex(of: path[best.point]) ?? 0
                ring = Array(ring[start...] + ring[..<start])
                path = ring + [ring[0]]
            } else if best.point != 0 {
                path.reverse()
            }
            out.append(path)
            cursor = path.last!
        }
        return out
    }

    private static func millProgram(_ paths: Clipper.Paths, layer: LayerKind, p: ParameterSnapshot,
                                     group: ParametersStore.MotionGroup,
                                     depth: Double, depthPerPass: Double,
                                     feed: String, vertFeed: String, speed: String, note: String) -> String? {
        guard !paths.isEmpty else { return nil }
        let t = toProgram(layer, p)
        let zSafe = num(p.zSafe(group)), zChange = num(p.zChange(group))
        let direction = p.millDirection(group)
        // Mirroring reverses every ring, so decide the direction after it.
        let climb: Bool? = direction == "climb" ? true : (direction == "conventional" ? false : nil)
        let programPaths = ordered(paths.map { $0.map { $0.applying(t) } },
                                   climb: climb.map { p.spindleCCW(group) ? !$0 : $0 })
        let levels = CustomLayerGenerator.depths(cutDepth: depth, depthPerPass: depthPerPass)

        var out: [String] = []
        header(&out, speed: speed)
        out.append("G01 F\(feed) ( Feedrate. )")
        toolChange(&out, zChange: zChange, number: 1, message: "Change tool bit to \(note)")
        for path in programPaths {
            guard let start = path.first else { continue }
            let closed = path.count > 2 && start == path.last!
            out.append("G00 Z\(f(zSafe)) ( retract )")
            out.append("G00 X\(f(start.x)) Y\(f(start.y)) ( rapid move to begin. )")
            for (level, z) in levels.enumerated() {
                if levels.count > 1 { out.append("( Mill infeed pass \(level + 1)/\(levels.count) )") }
                out.append("G01 Z\(f(z)) F\(vertFeed) ( plunge. )")
                out.append("G01 F\(feed)")
                let route: [CGPoint] = closed || level % 2 == 0 ? Array(path.dropFirst()) : Array(path.reversed().dropFirst())
                for q in route { out.append("G01 X\(f(q.x)) Y\(f(q.y))") }
            }
            out.append("G00 Z\(f(zSafe)) ( retract )")
            out.append("")
        }
        footer(&out, zChange: zChange)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Outline

    private static func outlineProgram(_ board: Clipper.Paths, p: ParameterSnapshot) -> String? {
        let d = num(p.cutterDiameter)
        guard d > 0 else { return nil }
        // The cutter runs outside the board: the board's contour grown by d/2.
        let rings = Clipper.inflate(board, by: d / 2).filter { $0.count >= 3 }
        guard !rings.isEmpty else { return nil }
        let t = toProgram(.outline, p)
        let zSafe = num(p.zSafe(.cut)), zChange = num(p.zChange(.cut))
        let total = abs(num(p.zCut)), infeed = num(p.cutInfeed)
        let count = infeed > 0 ? max(1, Int(ceil(total / infeed - 1e-9))) : 1
        let levels = (1...count).map { -total * Double($0) / Double(count) }
        let bridgeWidth = num(p.bridgeWidth), zBridge = num(p.zBridge)
        let bridgeCount = Int(p.bridgeCount.trimmingCharacters(in: .whitespaces)) ?? 0

        var out: [String] = []
        header(&out, speed: p.cutSpeed)
        out.append("G01 F\(p.cutFeed) ( Feedrate. )")
        toolChange(&out, zChange: zChange, number: 1, message: "Change tool bit to cutter diameter \(f(d))mm")
        // Outer contours (counter-clockwise in the design frame) get the
        // bridges; cutouts inside the board do not. Cutouts first.
        let tagged = rings.map { (ring: $0.map { $0.applying(t) } + [$0[0].applying(t)], outer: Clipper.area($0) > 0) }
            .sorted { !$0.outer && $1.outer }
        for (ring, outer) in tagged {
            let path = outer && bridgeCount > 0 && bridgeWidth > 0
                ? withBridges(ring, count: bridgeCount, length: bridgeWidth + d) : ring.map { ($0, false) }
            out.append("G00 Z\(f(zSafe)) ( retract )")
            out.append("G00 X\(f(path[0].0.x)) Y\(f(path[0].0.y)) ( rapid move to begin. )")
            for z in levels {
                out.append("G01 Z\(f(z)) F\(p.cutVertFeed) ( plunge. )")
                out.append("G01 F\(p.cutFeed)")
                var raised = false
                for (q, bridge) in path.dropFirst() {
                    // A bridge segment: over the tab at bridge height, then back down.
                    if bridge, z < zBridge, !raised { out.append("G00 Z\(f(zBridge))"); raised = true }
                    if !bridge, raised { out.append("G01 Z\(f(z)) F\(p.cutVertFeed)"); out.append("G01 F\(p.cutFeed)"); raised = false }
                    out.append("G01 X\(f(q.x)) Y\(f(q.y))")
                }
                if raised { out.append("G01 Z\(f(z)) F\(p.cutVertFeed)"); out.append("G01 F\(p.cutFeed)") }
            }
            out.append("G00 Z\(f(zSafe)) ( retract )")
            out.append("")
        }
        footer(&out, zChange: zChange)
        return out.joined(separator: "\n") + "\n"
    }

    /// The closed ring with `count` bridges of `length` centred on its
    /// longest straight segments (as pcb2gcode places them). Each point is
    /// flagged when the move reaching it crosses a bridge.
    private static func withBridges(_ ring: [CGPoint], count: Int, length: Double) -> [(CGPoint, Bool)] {
        let segments = (1..<ring.count).map { (index: $0, length: hypot(ring[$0].x - ring[$0 - 1].x, ring[$0].y - ring[$0 - 1].y)) }
        let chosen = Set(segments.filter { $0.length >= length }.sorted { $0.length > $1.length }.prefix(count).map(\.index))
        var out: [(CGPoint, Bool)] = [(ring[0], false)]
        for i in 1..<ring.count {
            let a = ring[i - 1], b = ring[i]
            if chosen.contains(i) {
                let l = hypot(b.x - a.x, b.y - a.y)
                let t0 = (l - length) / 2 / l, t1 = (l + length) / 2 / l
                out.append((CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0), false))
                out.append((CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1), true))
            }
            out.append((b, false))
        }
        return out
    }

    // MARK: Drilling

    /// The drill program and, with hole milling on, the milled-holes program.
    private static func drillPrograms(_ image: ExcellonImage, p: ParameterSnapshot) -> (String?, String?, String) {
        var log = ""
        // Bits on hand: "0.8mm:-0.1mm:+0.1mm" → (bit, lowest, highest hole).
        let bits: [(bit: Double, low: Double, high: Double)] = p.drillBits.compactMap { spec in
            let parts = spec.split(separator: ":").map { Double($0.replacingOccurrences(of: "mm", with: "")) ?? .nan }
            guard parts.count == 3, !parts.contains(where: \.isNaN) else { return nil }
            return (parts[0], parts[0] + parts[1], parts[0] + parts[2])
        }
        let millFrom = p.drillMillLarge ? num(p.drillMillFrom) : .infinity
        var drilled: [Double: [CGPoint]] = [:]
        var milled: [(CGPoint, Double)] = []
        let t = toProgram(.drill(index: 0, name: ""), p)
        let allowance = num(p.drillHoleAllowance)
        for hole in image.holes {
            let designed = image.diameter(hole.tool)
            guard designed >= 0.01 else { continue }
            let size = designed + allowance
            let at = hole.at.applying(t)
            if size >= millFrom - 1e-6 { milled.append((at, size)); continue }
            let bit = bits.filter { size >= $0.low - 1e-6 && size <= $0.high + 1e-6 }
                .min { abs($0.bit - size) < abs($1.bit - size) }?.bit ?? size
            drilled[(bit * 1e4).rounded() / 1e4, default: []].append(at)
            if hole.slotEnd != nil { log += "Native: slot at \(f(hole.at.x)), \(f(hole.at.y)) drilled as a hole.\n" }
        }

        let zSafe = num(p.zSafe(.drill)), zChange = num(p.zChange(.drill)), zDrill = num(p.zDrill)
        var drill: String?
        if !drilled.isEmpty {
            let sizes = drilled.keys.sorted()
            var out = ["( CNC G-Coder native engine )",
                       "( This file uses \(sizes.count) drill bit size\(sizes.count == 1 ? "" : "s"). )",
                       "( Bit sizes: " + sizes.map { "[\(ParametersStore.format($0))mm]" }.joined(separator: " ") + " )",
                       "G94 (Millimeters per minute feed rate.)", "G21 (Units == Millimeters.)",
                       "G90 (Absolute coordinates.)", "G00 S\(p.drillSpeed) (RPM spindle speed.)"]
            for (i, size) in sizes.enumerated() {
                out += ["G00 Z\(f(zChange)) (Retract)", "T\(i + 1)", "M5 (Spindle stop.)", "G04 P1.00000",
                        "(MSG, Change tool bit to drill size \(ParametersStore.format(size))mm)",
                        "M6 (Tool change.)", "M0 (Temporary machine stop.)", "M3 (Spindle on clockwise.)",
                        "G0 Z\(f(zSafe))", "G04 P1.00000", "G1 F\(p.drillFeed)"]
                for q in nearestOrder(drilled[size]!) {
                    out += ["G0 X\(f(q.x)) Y\(f(q.y))", "G1 Z\(f(zDrill))", "G1 Z\(f(zSafe))"]
                }
            }
            footer(&out, zChange: zChange)
            drill = out.joined(separator: "\n") + "\n"
        }

        var mill: String?
        if !milled.isEmpty {
            let cutter = num(p.holeMillDiameter), depth = abs(num(p.holeMillDepth))
            let infeed = max(num(p.holeMillInfeed), 0.01)
            let count = max(1, Int(ceil(depth / infeed - 1e-9)))
            let step = depth / Double(count)
            var out: [String] = []
            header(&out, speed: p.holeMillSpeed)
            toolChange(&out, zChange: zChange, number: 1, message: "Change tool bit to cutter diameter \(f(cutter))mm")
            let order = nearestOrder(milled.map(\.0))
            for q in order {
                guard let size = milled.first(where: { $0.0 == q })?.1 else { continue }
                let r = (size - cutter) / 2
                out.append("G00 Z\(f(zSafe))")
                if r <= 1e-3 {
                    out += ["G0 X\(f(q.x)) Y\(f(q.y))", "G1 Z\(f(-depth)) F\(p.holeMillVertFeed)", "G1 Z\(f(zSafe))"]
                    continue
                }
                // A helix: full circles, each a pass deeper, then one flat at the bottom.
                out += ["G0 X\(f(q.x + r)) Y\(f(q.y))", "G1 Z\(f(step)) F\(p.holeMillVertFeed)", "G1 F\(p.holeMillFeed)"]
                for k in 0...count {
                    out.append("G2 X\(f(q.x + r)) Y\(f(q.y)) Z\(f(-step * Double(k))) I\(f(-r)) J0.00000")
                }
                out.append("G2 X\(f(q.x + r)) Y\(f(q.y)) I\(f(-r)) J0.00000")
                out.append("G1 Z\(f(zSafe)) F\(p.holeMillVertFeed)")
            }
            footer(&out, zChange: zChange)
            mill = out.joined(separator: "\n") + "\n"
        }
        return (drill, mill, log)
    }

    private static func nearestOrder(_ points: [CGPoint]) -> [CGPoint] {
        var remaining = points
        var out: [CGPoint] = []
        var cursor = CGPoint.zero
        while !remaining.isEmpty {
            let i = remaining.indices.min { hypot(remaining[$0].x - cursor.x, remaining[$0].y - cursor.y)
                                            < hypot(remaining[$1].x - cursor.x, remaining[$1].y - cursor.y) }!
            cursor = remaining.remove(at: i)
            out.append(cursor)
        }
        return out
    }
}
