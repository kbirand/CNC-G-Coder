import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Runs both toolpath engines on the same files and settings and measures
/// how their programs differ — the evidence for choosing between them.
/// Dev hook: `-debugProjectFolder <gerbers> -debugCompareEngines <report dir>`.
///
/// Per program: the area the tool sweeps (cut moves widened to the tool),
/// how much of it both engines share, safety (tool centre closer to copper
/// than half the tool; outside a mask/legend opening), hole sets, and an
/// overlay image. Origins are not zeroed, so both are in the Gerber frame.
nonisolated enum EngineComparison {

    struct LayerReport: Sendable {
        var name: String
        var lines: (Int, Int) = (0, 0)
        var time: (Double, Double) = (0, 0)
        var cutLength: (Double, Double) = (0, 0)
        var swept: (Double, Double) = (0, 0)
        var shared = 0.0
        /// mm of tool-centre path in the forbidden band, per engine.
        var unsafeLength: (Double, Double)? = nil
        var holes: String?
        var note = ""
        /// Where unsafe samples lie (first few), for the report.
        var unsafeAt: [String] = []
        var iou: Double { let u = swept.0 + swept.1 - shared; return u > 0 ? shared / u : 1 }
    }

    static func run(pcb2gcode: URL?, params base: ParameterSnapshot, files: DetectedFiles, reportDir: URL) async -> String {
        var p = base
        p.zeroStart = false
        let fm = FileManager.default
        try? fm.removeItem(at: reportDir)
        try? fm.createDirectory(at: reportDir, withIntermediateDirectories: true)

        var results: [String: (Pcb2GcodeService.BatchResult, Double)] = [:]
        for engine in ["pcb2gcode", "native"] {
            var q = p
            q.engine = engine
            let started = Date()
            let batch = await Pcb2GcodeService.runBatch(pcb2gcode: engine == "native" ? nil : pcb2gcode, params: q,
                                                        files: files, outputDir: reportDir.appendingPathComponent(engine))
            results[engine] = (batch, Date().timeIntervalSince(started))
            try? batch.log.write(to: reportDir.appendingPathComponent("\(engine).log"), atomically: true, encoding: .utf8)
        }
        guard let (a, ta) = results["pcb2gcode"], let (b, tb) = results["native"] else { return "no results" }

        let kinds = Set(a.outputs.map(\.layer) + b.outputs.map(\.layer)).sorted()
        var reports: [LayerReport] = []
        for kind in kinds {
            var r = LayerReport(name: kind.displayName)
            let oa = a.outputs.first { $0.layer == kind }, ob = b.outputs.first { $0.layer == kind }
            guard let oa, let ob else {
                r.note = oa == nil ? "only native produced this program" : "only pcb2gcode produced this program"
                reports.append(r)
                continue
            }
            guard let la = try? GCodeParser.parse(fileURL: oa.url, layer: kind),
                  let lb = try? GCodeParser.parse(fileURL: ob.url, layer: kind) else { continue }
            r.lines = (la.lineCount, lb.lineCount)
            r.time = (la.totalTime, lb.totalTime)
            let ca = cutLines(la), cb = cutLines(lb)
            r.cutLength = (length(ca), length(cb))
            let tool = oa.toolDiameter ?? ob.toolDiameter ?? 0.2

            if kind.isDrill {
                r.holes = compareHoles(la, lb, oa.url, ob.url)
            } else {
                let sa = sweep(ca, tool), sb = sweep(cb, tool)
                r.swept = (Clipper.area(sa), Clipper.area(sb))
                r.shared = Clipper.area(Clipper.intersection(sa, sb))
                difference(only: (Clipper.difference(sa, sb), Clipper.difference(sb, sa)),
                           source: sourceGeometry(kind, files: files, p: p)?.0,
                           to: reportDir.appendingPathComponent(kind.fileSlug + "-difference.png"))
                // Safety against the source geometry: the length of tool-centre
                // path inside the forbidden band — closer to copper than half the
                // tool, or (mask, legend) outside the opening shrunk by it.
                if let (copper, inward) = sourceGeometry(kind, files: files, p: p) {
                    let allowed = 0.005   // 5 µm: below the geometry's own rounding
                    let band = Clipper.inflate(copper, by: inward ? -(tool / 2 - allowed) : tool / 2 - allowed)
                    func unsafe(_ lines: Clipper.Paths) -> Clipper.Paths {
                        inward ? Clipper.boolean(.difference, openSubject: lines, clip: band).open
                               : Clipper.clipLines(lines, to: band)
                    }
                    let ua = unsafe(ca), ub = unsafe(cb)
                    r.unsafeLength = (length(ua), length(ub))
                    for (engine, pieces) in [("pcb2gcode", ua), ("native", ub)] {
                        var spots: [CGPoint] = []
                        for piece in pieces {
                            guard let q = piece.first, !spots.contains(where: { hypot($0.x - q.x, $0.y - q.y) < 1 }) else { continue }
                            spots.append(q)
                        }
                        for q in spots.prefix(6) {
                            // How far the tool edge reaches into the shape there.
                            var depth = 0.0
                            for e in stride(from: allowed, through: tool / 2, by: 0.002) {
                                let deeper = Clipper.inflate(copper, by: inward ? -(tool / 2 - e) : tool / 2 - e)
                                let hit = unsafeAt(q, deeper, inward: inward)
                                if !hit { break }
                                depth = e
                            }
                            r.unsafeAt.append("\(engine): X\(String(format: "%.3f", q.x)) Y\(String(format: "%.3f", q.y)) — tool edge ≈\(String(format: "%.3f", depth)) mm into the shape")
                        }
                    }
                }
                overlay(kind, a: ca, b: cb, tool: tool, source: sourceGeometry(kind, files: files, p: p)?.0,
                        to: reportDir.appendingPathComponent(kind.fileSlug + ".png"))
            }
            reports.append(r)
        }

        let text = markdown(reports, times: (ta, tb), p: p)
        try? text.write(to: reportDir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        return text
    }

    // MARK: - Measures

    /// Chains of cut moves (below the surface, moving in XY), in program mm.
    static func cutLines(_ layer: ParsedLayer) -> Clipper.Paths {
        var lines: Clipper.Paths = []
        var current: [CGPoint] = []
        for move in layer.moves {
            let horizontal = hypot(move.end.x - move.start.x, move.end.y - move.start.y) > 1e-6
            if move.kind == .cut, horizontal {
                if current.last.map({ hypot($0.x - move.start.x, $0.y - move.start.y) > 1e-6 }) ?? true {
                    if current.count > 1 { lines.append(current) }
                    current = [move.start]
                }
                current.append(move.end)
            } else if !(move.kind == .cut && !horizontal) {
                if current.count > 1 { lines.append(current) }
                current = []
            }
        }
        if current.count > 1 { lines.append(current) }
        return lines
    }

    static func length(_ lines: Clipper.Paths) -> Double {
        lines.reduce(0) { total, line in
            total + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }

    /// The material a tool of diameter `d` removes along the lines.
    static func sweep(_ lines: Clipper.Paths, _ d: Double) -> Clipper.Paths {
        Clipper.union(Clipper.inflate(lines, by: d / 2, join: .round, end: .round, arcTolerance: 0.005))
    }

    /// Whether a point lies in the forbidden band (a tiny line through it
    /// clipped by Clipper, so large pours cost nothing extra).
    static func unsafeAt(_ q: CGPoint, _ band: Clipper.Paths, inward: Bool) -> Bool {
        let probe: Clipper.Paths = [[q, CGPoint(x: q.x + 0.0005, y: q.y)]]
        let within = !Clipper.clipLines(probe, to: band).isEmpty
        return inward ? !within : within
    }

    static func box(_ ring: Clipper.Path) -> CGRect {
        var r = CGRect.null
        for p in ring { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Even-odd point-in-polygon over a set of rings (with their boxes).
    static func inside(_ p: CGPoint, _ rings: Clipper.Paths, _ boxes: [CGRect]) -> Bool {
        var inside = false
        for (index, ring) in rings.enumerated() where ring.count >= 3 {
            let b = boxes[index]
            guard p.x >= b.minX, p.x <= b.maxX, p.y >= b.minY, p.y <= b.maxY else { continue }
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
        }
        return inside
    }

    /// The layer's own shapes in program coordinates, and whether the tool
    /// works inside them (mask, legend) rather than around them (copper).
    static func sourceGeometry(_ kind: LayerKind, files: DetectedFiles, p: ParameterSnapshot) -> (Clipper.Paths, Bool)? {
        let slot: LayerSlot
        let inward: Bool
        switch kind {
        case .front: slot = .front; inward = false
        case .back: slot = .back; inward = false
        case .maskTop: slot = .topMask; inward = true
        case .maskBottom: slot = .bottomMask; inward = true
        case .silkTop: slot = .topSilk; inward = true
        case .silkBottom: slot = .bottomSilk; inward = true
        default: return nil
        }
        guard let url = files[slot], let image = try? GerberFile.read(url) else { return nil }
        let t = CustomLayerGenerator.ProgramFrame(frame: nil, mirrorAxis: Double(p.mirrorAxis) ?? 0,
                                                  mirrorYAxis: p.mirrorYAxis).designToProgram(back: kind.isBackSide)
        return (NativeToolpathEngine.copper(image).map { $0.map { $0.applying(t) } }, inward)
    }

    static func compareHoles(_ a: ParsedLayer, _ b: ParsedLayer, _ ua: URL, _ ub: URL) -> String {
        func key(_ p: CGPoint) -> String { String(format: "%.3f,%.3f", p.x, p.y) }
        let ha = Set(a.drillHits.map(key)), hb = Set(b.drillHits.map(key))
        func bits(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n")
                .first { $0.contains("Bit sizes:") }.map { $0.replacingOccurrences(of: "( Bit sizes: ", with: "").replacingOccurrences(of: " )", with: "") } ?? "?"
        }
        return "holes \(ha.count) / \(hb.count), same positions: \(ha == hb ? "yes" : "no (\(ha.symmetricDifference(hb).count) differ)"); bits \(bits(ua)) / \(bits(ub))"
    }

    // MARK: - Output

    static func markdown(_ reports: [LayerReport], times: (Double, Double), p: ParameterSnapshot) -> String {
        func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v) }
        func m(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        var out = ["# pcb2gcode vs native engine", "",
                   "Generation time: pcb2gcode \(f(times.0, 2)) s, native \(f(times.1, 2)) s.",
                   "Isolation: tool \(p.millDiameter) mm, width \(p.isolationWidth) mm, overlap \(p.millOverlap) %.", "",
                   "| Program | Est. time (p2g / native) | Cut length mm | Swept area mm² | Shared (IoU) | Path too close to copper (p2g / native) |",
                   "|---|---|---|---|---|---|"]
        for r in reports {
            if !r.note.isEmpty { out.append("| \(r.name) | — | — | — | — | \(r.note) |"); continue }
            if let holes = r.holes {
                out.append("| \(r.name) | \(m(r.time.0)) / \(m(r.time.1)) | — | — | — | \(holes) |")
                continue
            }
            let unsafe = r.unsafeLength.map { "\(f($0.0, 3)) / \(f($0.1, 3)) mm" } ?? "—"
            out.append("| \(r.name) | \(m(r.time.0)) / \(m(r.time.1)) | \(f(r.cutLength.0, 0)) / \(f(r.cutLength.1, 0)) | "
                       + "\(f(r.swept.0)) / \(f(r.swept.1)) | \(f(r.iou * 100, 1)) % | \(unsafe) |")
        }
        for r in reports where !r.unsafeAt.isEmpty {
            out.append("")
            out.append("Unsafe spots — \(r.name):")
            out += r.unsafeAt.map { "- \($0)" }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Only what one engine cuts and the other does not: pcb2gcode-only
    /// orange, native-only blue, over the source shapes in grey.
    static func difference(only: (Clipper.Paths, Clipper.Paths), source: Clipper.Paths?, to url: URL) {
        var bounds = CGRect.null
        for line in only.0 + only.1 + (source ?? []) { for p in line { bounds = bounds.union(CGRect(origin: p, size: .zero)) } }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        bounds = bounds.insetBy(dx: -1, dy: -1)
        let scale = min(2400 / bounds.width, 2400 / bounds.height)
        guard let ctx = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        func fill(_ paths: Clipper.Paths, _ color: CGColor) {
            for path in paths {
                guard let first = path.first else { continue }
                ctx.move(to: first)
                for p in path.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
            }
            ctx.setFillColor(color)
            ctx.fillPath(using: .evenOdd)
        }
        if let source { fill(source, CGColor(gray: 0.35, alpha: 1)) }
        fill(only.0, CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        fill(only.1, CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Source shapes grey, pcb2gcode's sweep orange, native's blue (overlap reads purple).
    static func overlay(_ kind: LayerKind, a: Clipper.Paths, b: Clipper.Paths, tool: Double,
                        source: Clipper.Paths?, to url: URL) {
        var bounds = CGRect.null
        for line in a + b + (source ?? []) { for p in line { bounds = bounds.union(CGRect(origin: p, size: .zero)) } }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
        bounds = bounds.insetBy(dx: -1, dy: -1)
        let scale = min(2400 / bounds.width, 2400 / bounds.height)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        func add(_ paths: Clipper.Paths, closed: Bool) {
            for path in paths {
                guard let first = path.first else { continue }
                ctx.move(to: first)
                for p in path.dropFirst() { ctx.addLine(to: p) }
                if closed { ctx.closePath() }
            }
        }
        if let source {
            add(source, closed: true)
            ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
            ctx.fillPath(using: .evenOdd)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(tool, 0.02))
        ctx.setBlendMode(.screen)
        add(a, closed: false)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.45, blue: 0, alpha: 0.85))
        ctx.strokePath()
        add(b, closed: false)
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.45, blue: 1, alpha: 0.85))
        ctx.strokePath()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
