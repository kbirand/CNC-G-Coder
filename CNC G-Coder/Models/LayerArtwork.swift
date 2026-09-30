import Foundation
import CoreGraphics

/// The editable contents of an imported layer file — a Gerber image or an
/// Excellon drill file — as objects that can be selected, moved, resized and
/// deleted (see LayerFileEditor). Positions are design millimetres (the
/// Gerber frame, Y up), the frame drawn layers use too.
nonisolated enum LayerArtwork: Hashable, Sendable {
    case gerber(GerberImage)
    case drill(ExcellonImage)

    var objectIDs: [UUID] {
        switch self {
        case .gerber(let image): image.objects.map(\.id)
        case .drill(let image): image.holes.map(\.id)
        }
    }

    var objectCount: Int { objectIDs.count }

    func bounds(of ids: Set<UUID>) -> CGRect? {
        var r = CGRect.null
        switch self {
        case .gerber(let image):
            for object in image.objects where ids.contains(object.id) {
                if let b = image.bounds(of: object) { r = r.union(b) }
            }
        case .drill(let image):
            for hole in image.holes where ids.contains(hole.id) { r = r.union(image.bounds(of: hole)) }
        }
        return r.isNull ? nil : r
    }

    /// The topmost object under a point (within `tolerance` of it).
    func hitTest(_ p: CGPoint, tolerance: Double) -> UUID? {
        switch self {
        case .gerber(let image): image.hitTest(p, tolerance: tolerance)
        case .drill(let image): image.hitTest(p, tolerance: tolerance)
        }
    }

    /// Objects inside `rect` (enclosed entirely, or merely touched).
    func objects(in rect: CGRect, enclose: Bool) -> Set<UUID> {
        var hits = Set<UUID>()
        switch self {
        case .gerber(let image):
            for object in image.objects {
                guard let b = image.bounds(of: object) else { continue }
                if enclose ? rect.contains(b) : rect.intersects(b) { hits.insert(object.id) }
            }
        case .drill(let image):
            for hole in image.holes {
                let b = image.bounds(of: hole)
                if enclose ? rect.contains(b) : rect.intersects(b) { hits.insert(hole.id) }
            }
        }
        return hits
    }

    /// Everything of the same kind and size as the given objects: tracks of
    /// the same width, pads with the same aperture, holes of the same tool.
    func similar(to ids: Set<UUID>) -> Set<UUID> {
        switch self {
        case .gerber(let image):
            let keys = Set(image.objects.filter { ids.contains($0.id) }.map(\.similarityKey))
            return Set(image.objects.filter { keys.contains($0.similarityKey) }.map(\.id))
        case .drill(let image):
            let tools = Set(image.holes.filter { ids.contains($0.id) }.map(\.tool))
            return Set(image.holes.filter { tools.contains($0.tool) }.map(\.id))
        }
    }

    func moving(_ ids: Set<UUID>, by delta: CGVector) -> LayerArtwork {
        switch self {
        case .gerber(var image):
            for i in image.objects.indices where ids.contains(image.objects[i].id) {
                image.objects[i] = image.objects[i].moved(by: delta)
            }
            return .gerber(image)
        case .drill(var image):
            for i in image.holes.indices where ids.contains(image.holes[i].id) {
                image.holes[i] = image.holes[i].moved(by: delta)
            }
            return .drill(image)
        }
    }

    func removing(_ ids: Set<UUID>) -> LayerArtwork {
        switch self {
        case .gerber(var image):
            image.objects.removeAll { ids.contains($0.id) }
            return .gerber(image)
        case .drill(var image):
            image.holes.removeAll { ids.contains($0.id) }
            return .drill(image)
        }
    }

    /// The point an object is positioned by (inspector X/Y).
    func anchor(of id: UUID) -> CGPoint? {
        switch self {
        case .gerber(let image): image.objects.first { $0.id == id }?.anchor
        case .drill(let image): image.holes.first { $0.id == id }?.at
        }
    }
}

// MARK: - Gerber

/// A Gerber aperture (D-code). Parameters stay in the file's own units, as
/// aperture macros — kept verbatim — are written in them too.
nonisolated struct GerberAperture: Hashable, Sendable {
    var code: Int
    /// "C", "R", "O", "P" or the name of an aperture macro.
    var template: String
    var params: [Double]

    enum Shape { case circle, rectangle, obround, polygon, macro }

    var shape: Shape {
        switch template {
        case "C": .circle
        case "R": .rectangle
        case "O": .obround
        case "P": .polygon
        default: .macro
        }
    }

    var isStandard: Bool { shape != .macro }

    /// Width × height in file units (standard apertures only).
    var size: CGSize? {
        switch shape {
        case .circle, .polygon: params.first.map { CGSize(width: $0, height: $0) }
        case .rectangle, .obround: params.count >= 2 ? CGSize(width: params[0], height: params[1]) : nil
        case .macro: nil
        }
    }

    /// Returns a copy resized to width × height (file units). Circles and
    /// polygons take the width as their diameter; any hole is kept.
    func resized(width: Double, height: Double) -> GerberAperture {
        var copy = self
        switch shape {
        case .circle, .polygon:
            if copy.params.isEmpty { copy.params = [width] } else { copy.params[0] = width }
        case .rectangle, .obround:
            while copy.params.count < 2 { copy.params.append(0) }
            copy.params[0] = width
            copy.params[1] = height
        case .macro:
            break
        }
        return copy
    }

    /// Same shape and size (the D-code aside).
    func matches(_ other: GerberAperture) -> Bool {
        template == other.template && params.count == other.params.count
            && zip(params, other.params).allSatisfy { abs($0 - $1) < 1e-7 }
    }

    /// Outlines of the flashed shape centred on the origin, design mm.
    func outlines(unit: Double, macros: [GerberMacro]) -> [Polyline] {
        let p = params.map { $0 * unit }
        switch shape {
        case .circle:
            return [ShapeMath.circle(center: .zero, radius: max(p.first ?? 0, 0) / 2)]
        case .rectangle:
            guard p.count >= 2 else { return [] }
            return [ShapeMath.roundedRect(origin: CGPoint(x: -p[0] / 2, y: -p[1] / 2),
                                          size: CGSize(width: p[0], height: p[1]), cornerRadius: 0, rotation: 0)]
        case .obround:
            guard p.count >= 2 else { return [] }
            return [ShapeMath.roundedRect(origin: CGPoint(x: -p[0] / 2, y: -p[1] / 2),
                                          size: CGSize(width: p[0], height: p[1]),
                                          cornerRadius: min(p[0], p[1]) / 2, rotation: 0)]
        case .polygon:
            guard let d = p.first, p.count >= 2 else { return [] }
            let n = max(3, Int(params[1]))
            let rotation = (params.count >= 3 ? params[2] : 0) * .pi / 180
            let pts = (0..<n).map { k -> CGPoint in
                let a = rotation + 2 * .pi * Double(k) / Double(n)
                return CGPoint(x: d / 2 * cos(a), y: d / 2 * sin(a))
            }
            return [Polyline(points: pts, closed: true)]
        case .macro:
            return macros.first { $0.name == template }?.outlines(params: params, unit: unit) ?? []
        }
    }

    /// Stroke width when the aperture draws a track, design mm.
    func strokeWidth(unit: Double, macros: [GerberMacro]) -> Double {
        if let size { return min(size.width, size.height) * unit }
        var r = CGRect.null
        for outline in outlines(unit: unit, macros: macros) { if let b = outline.bounds { r = r.union(b) } }
        return r.isNull ? 0 : min(r.width, r.height)
    }

    /// "Round 0.5", "Rect 3 × 3", "MACRO1".
    func title(units: UnitSystem, unit: Double) -> String {
        func l(_ v: Double) -> String { units.length(v * unit, decimals: units.lengthDecimals + 1) }
        switch shape {
        case .circle: return "Round ⌀\(l(params.first ?? 0))"
        case .rectangle: return params.count >= 2 ? "Rect \(l(params[0])) × \(l(params[1]))" : "Rect"
        case .obround: return params.count >= 2 ? "Oval \(l(params[0])) × \(l(params[1]))" : "Oval"
        case .polygon: return "Polygon ⌀\(l(params.first ?? 0))"
        case .macro: return "Macro \(template)"
        }
    }
}

/// An aperture macro: its primitive blocks, kept as written.
nonisolated struct GerberMacro: Hashable, Sendable {
    var name: String
    var blocks: [String]

    /// The dark primitives, instantiated with an aperture's parameters.
    /// Display and hit testing only — the file keeps the macro as written.
    func outlines(params: [Double], unit: Double) -> [Polyline] {
        var vars: [Int: Double] = [:]
        for (i, v) in params.enumerated() { vars[i + 1] = v }
        var out: [Polyline] = []
        for block in blocks {
            let text = block.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("0") && (text.count == 1 || text.dropFirst().first == " ") { continue }   // comment
            if text.hasPrefix("$"), let eq = text.firstIndex(of: "=") {
                if let n = Int(text[text.index(after: text.startIndex)..<eq]) {
                    vars[n] = MacroExpression.evaluate(String(text[text.index(after: eq)...]), vars) ?? 0
                }
                continue
            }
            let fields = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let code = Int(fields.first ?? "") else { continue }
            let m = fields.dropFirst().map { MacroExpression.evaluate($0, vars) ?? 0 }
            func at(_ i: Int) -> Double { i < m.count ? m[i] : 0 }
            func rot(_ polys: [Polyline], _ degrees: Double) -> [Polyline] {
                let t = ShapeMath.rotation(degrees, about: .zero)
                return polys.map { $0.applying(t) }
            }
            var shapes: [Polyline] = []
            var exposure = 1.0
            switch code {
            case 1:   // circle: exposure, diameter, cx, cy[, rotation]
                exposure = at(0)
                shapes = rot([ShapeMath.circle(center: CGPoint(x: at(2) * unit, y: at(3) * unit), radius: at(1) * unit / 2)], at(4))
            case 2, 20:   // vector line: exposure, width, sx, sy, ex, ey, rotation
                exposure = at(0)
                let w = at(1) * unit / 2
                let s = CGPoint(x: at(2) * unit, y: at(3) * unit), e = CGPoint(x: at(4) * unit, y: at(5) * unit)
                let len = max(ShapeMath.distance(s, e), 1e-9)
                let nx = -(e.y - s.y) / len * w, ny = (e.x - s.x) / len * w
                shapes = rot([Polyline(points: [CGPoint(x: s.x + nx, y: s.y + ny), CGPoint(x: e.x + nx, y: e.y + ny),
                                                CGPoint(x: e.x - nx, y: e.y - ny), CGPoint(x: s.x - nx, y: s.y - ny)],
                                       closed: true)], at(6))
            case 21:   // centre line: exposure, width, height, cx, cy, rotation
                exposure = at(0)
                let w = at(1) * unit, h = at(2) * unit
                shapes = rot([ShapeMath.roundedRect(origin: CGPoint(x: at(3) * unit - w / 2, y: at(4) * unit - h / 2),
                                                    size: CGSize(width: w, height: h), cornerRadius: 0, rotation: 0)], at(5))
            case 22:   // lower-left line: exposure, width, height, x, y, rotation
                exposure = at(0)
                shapes = rot([ShapeMath.roundedRect(origin: CGPoint(x: at(3) * unit, y: at(4) * unit),
                                                    size: CGSize(width: at(1) * unit, height: at(2) * unit),
                                                    cornerRadius: 0, rotation: 0)], at(5))
            case 4:   // outline: exposure, n, x0, y0, … xn, yn, rotation
                exposure = at(0)
                let n = Int(at(1))
                var pts: [CGPoint] = []
                for k in 0...max(n, 0) { pts.append(CGPoint(x: at(2 + 2 * k) * unit, y: at(3 + 2 * k) * unit)) }
                if pts.count > 1, let f = pts.first, let l = pts.last, ShapeMath.distance(f, l) < 1e-9 { pts.removeLast() }
                shapes = rot([Polyline(points: pts, closed: true)], at(4 + 2 * n))
            case 5:   // polygon: exposure, vertices, cx, cy, diameter, rotation
                exposure = at(0)
                let n = max(3, Int(at(1)))
                let c = CGPoint(x: at(2) * unit, y: at(3) * unit), r = at(4) * unit / 2
                let pts = (0..<n).map { k -> CGPoint in
                    let a = 2 * .pi * Double(k) / Double(n)
                    return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                }
                shapes = rot([Polyline(points: pts, closed: true)], at(5))
            case 6:   // moiré: the outer ring is close enough to show
                shapes = rot([ShapeMath.circle(center: CGPoint(x: at(0) * unit, y: at(1) * unit), radius: at(2) * unit / 2)], at(8))
            case 7:   // thermal: cx, cy, outer, inner, gap, rotation — shown as a ring
                let c = CGPoint(x: at(0) * unit, y: at(1) * unit)
                shapes = rot([ShapeMath.circle(center: c, radius: at(2) * unit / 2),
                              ShapeMath.circle(center: c, radius: at(3) * unit / 2)], at(5))
            default:
                continue
            }
            if exposure != 0 { out += shapes }
        }
        return out
    }
}

/// Arithmetic in aperture macros: + − x (or X) / and parentheses over
/// numbers and $n variables.
nonisolated enum MacroExpression {
    static func evaluate(_ text: String, _ vars: [Int: Double]) -> Double? {
        var parser = Parser(chars: Array(text.replacingOccurrences(of: " ", with: "")), vars: vars)
        let value = parser.sum()
        return parser.index == parser.chars.count ? value : nil
    }

    private struct Parser {
        let chars: [Character]
        let vars: [Int: Double]
        var index = 0

        mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]
                index += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func product() -> Double? {
            guard var value = factor() else { return nil }
            while index < chars.count, "xX/".contains(chars[index]) {
                let op = chars[index]
                index += 1
                guard let rhs = factor() else { return nil }
                value = op == "/" ? (rhs == 0 ? 0 : value / rhs) : value * rhs
            }
            return value
        }

        mutating func factor() -> Double? {
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c == "-" || c == "+" {
                index += 1
                return factor().map { c == "-" ? -$0 : $0 }
            }
            if c == "(" {
                index += 1
                let value = sum()
                if index < chars.count, chars[index] == ")" { index += 1 }
                return value
            }
            if c == "$" {
                index += 1
                let start = index
                while index < chars.count, chars[index].isNumber { index += 1 }
                return Int(String(chars[start..<index])).map { vars[$0] ?? 0 }
            }
            let start = index
            while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
            return Double(String(chars[start..<index]))
        }
    }
}

/// One piece of a Gerber path.
nonisolated enum GerberSegment: Hashable, Sendable {
    case line(to: CGPoint)
    case arc(to: CGPoint, center: CGPoint, clockwise: Bool)

    var end: CGPoint {
        switch self {
        case .line(let to), .arc(let to, _, _): to
        }
    }

    func moved(by d: CGVector) -> GerberSegment {
        switch self {
        case .line(let to): .line(to: to + d)
        case .arc(let to, let center, let cw): .arc(to: to + d, center: center + d, clockwise: cw)
        }
    }

    /// The segment flattened, from `start` (excluded) to its end.
    func points(from start: CGPoint) -> [CGPoint] {
        switch self {
        case .line(let to):
            return [to]
        case .arc(let to, let c, let cw):
            let r0 = ShapeMath.distance(start, c), r1 = ShapeMath.distance(to, c)
            let a0 = atan2(start.y - c.y, start.x - c.x)
            var sweep = GerberSegment.sweep(from: start, to: to, center: c, clockwise: cw)
            if cw { sweep = -sweep }
            let steps = ShapeMath.arcSteps(radius: max(r0, r1), angle: sweep)
            return (1...steps).map { s in
                let f = Double(s) / Double(steps)
                let a = a0 + sweep * f
                let r = r0 + (r1 - r0) * f
                return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            }
        }
    }

    /// Angle swept (0, 2π] going round `center` in the given direction; a
    /// closed arc (start = end) is a full circle.
    static func sweep(from s: CGPoint, to e: CGPoint, center c: CGPoint, clockwise: Bool) -> Double {
        let a0 = atan2(s.y - c.y, s.x - c.x), a1 = atan2(e.y - c.y, e.x - c.x)
        var d = clockwise ? a0 - a1 : a1 - a0
        while d <= 1e-9 { d += 2 * .pi }
        while d > 2 * .pi + 1e-9 { d -= 2 * .pi }
        return d
    }
}

nonisolated struct GerberPath: Hashable, Sendable {
    var start: CGPoint
    var segments: [GerberSegment] = []

    var end: CGPoint { segments.last?.end ?? start }

    func flattened() -> [CGPoint] {
        var pts = [start]
        var cursor = start
        for segment in segments {
            pts += segment.points(from: cursor)
            cursor = segment.end
        }
        return pts
    }

    func moved(by d: CGVector) -> GerberPath {
        GerberPath(start: start + d, segments: segments.map { $0.moved(by: d) })
    }
}

/// One drawn thing in a Gerber image.
nonisolated struct GerberObject: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A trace: the aperture swept along a path (D01 draws).
        case track(aperture: Int, path: GerberPath)
        /// A pad: the aperture stamped once (D03).
        case flash(aperture: Int, at: CGPoint)
        /// A filled area (G36/G37): pours, custom pad shapes.
        case region(contours: [GerberPath])
    }

    var id = UUID()
    var kind: Kind
    /// False = clear polarity (%LPC): erases what was drawn before it.
    var dark = true

    var aperture: Int? {
        switch kind {
        case .track(let a, _), .flash(let a, _): a
        case .region: nil
        }
    }

    var isTrack: Bool { if case .track = kind { return true } else { return false } }
    var isFlash: Bool { if case .flash = kind { return true } else { return false } }

    var anchor: CGPoint {
        switch kind {
        case .track(_, let path): path.start
        case .flash(_, let at): at
        case .region(let contours): contours.first?.start ?? .zero
        }
    }

    fileprivate var similarityKey: String {
        switch kind {
        case .track(let a, _): "t\(a)"
        case .flash(let a, _): "f\(a)"
        case .region: "r"
        }
    }

    func moved(by d: CGVector) -> GerberObject {
        var copy = self
        switch kind {
        case .track(let a, let path): copy.kind = .track(aperture: a, path: path.moved(by: d))
        case .flash(let a, let at): copy.kind = .flash(aperture: a, at: at + d)
        case .region(let contours): copy.kind = .region(contours: contours.map { $0.moved(by: d) })
        }
        return copy
    }
}

nonisolated struct GerberImage: Hashable, Sendable {
    var inches = false
    /// G04 comments from the top of the file (the generator's notes).
    var comments: [String] = []
    /// Extended commands kept as written (%…*% bodies, e.g. "TF.FileFunction,Copper,L1,Top").
    var header: [String] = []
    var macros: [GerberMacro] = []
    var apertures: [Int: GerberAperture] = [:]
    var objects: [GerberObject] = []

    /// File units → mm.
    var unit: Double { inches ? 25.4 : 1 }

    // MARK: Geometry (design mm)

    /// Flash outlines placed on the pad.
    func flashOutlines(aperture code: Int, at p: CGPoint) -> [Polyline] {
        guard let aperture = apertures[code] else { return [ShapeMath.circle(center: p, radius: 0.1)] }
        let t = CGAffineTransform(translationX: p.x, y: p.y)
        return aperture.outlines(unit: unit, macros: macros).map { $0.applying(t) }
    }

    func trackWidth(aperture code: Int) -> Double {
        apertures[code]?.strokeWidth(unit: unit, macros: macros) ?? 0
    }

    func bounds(of object: GerberObject) -> CGRect? {
        var r = CGRect.null
        switch object.kind {
        case .track(let a, let path):
            let w = trackWidth(aperture: a) / 2
            for p in path.flattened() { r = r.union(CGRect(x: p.x - w, y: p.y - w, width: 2 * w, height: 2 * w)) }
        case .flash(let a, let at):
            for outline in flashOutlines(aperture: a, at: at) { if let b = outline.bounds { r = r.union(b) } }
            if r.isNull { r = CGRect(origin: at, size: .zero) }
        case .region(let contours):
            for contour in contours {
                if let b = Polyline(points: contour.flattened(), closed: true).bounds { r = r.union(b) }
            }
        }
        return r.isNull ? nil : r
    }

    /// Topmost object under the point: a hit on the copper wins; failing
    /// that, the nearest edge within `tolerance`.
    func hitTest(_ p: CGPoint, tolerance: Double) -> UUID? {
        var nearest: (Double, UUID)?
        for object in objects.reversed() {
            guard let b = bounds(of: object), b.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { continue }
            let d = distance(from: p, to: object)
            if d <= 0 { return object.id }
            if d <= tolerance, d < (nearest?.0 ?? .infinity) { nearest = (d, object.id) }
        }
        return nearest?.1
    }

    /// Distance from a point to an object's copper (≤ 0 inside it).
    private func distance(from p: CGPoint, to object: GerberObject) -> Double {
        switch object.kind {
        case .track(let a, let path):
            let pts = path.flattened()
            let w = trackWidth(aperture: a) / 2
            guard pts.count > 1 else { return ShapeMath.distance(p, pts[0]) - w }
            var best = Double.infinity
            for i in 1..<pts.count { best = min(best, ShapeMath.distance(from: p, toSegment: pts[i - 1], pts[i])) }
            return best - w
        case .flash(let a, let at):
            let outlines = flashOutlines(aperture: a, at: at)
            if outlines.contains(where: { $0.closed && ShapeMath.contains($0, p) }) { return 0 }
            var best = Double.infinity
            for outline in outlines { for (s, e) in outline.segments { best = min(best, ShapeMath.distance(from: p, toSegment: s, e)) } }
            return best
        case .region(let contours):
            let polys = contours.map { Polyline(points: $0.flattened(), closed: true) }
            var inside = false
            for poly in polys where ShapeMath.contains(poly, p) { inside.toggle() }
            if inside { return 0 }
            var best = Double.infinity
            for poly in polys { for (s, e) in poly.segments { best = min(best, ShapeMath.distance(from: p, toSegment: s, e)) } }
            return best
        }
    }

    // MARK: Apertures

    /// An aperture of this shape and size, reusing an existing D-code when
    /// one matches; `new` is updated with the code to use.
    mutating func aperture(matching wanted: GerberAperture) -> Int {
        if let existing = apertures.values.sorted(by: { $0.code < $1.code }).first(where: { $0.matches(wanted) }) {
            return existing.code
        }
        let code = max(9, apertures.keys.max() ?? 9) + 1
        var added = wanted
        added.code = code
        apertures[code] = added
        return code
    }

    /// How many objects use each aperture.
    var apertureUse: [Int: (tracks: Int, pads: Int)] {
        var use: [Int: (tracks: Int, pads: Int)] = [:]
        for object in objects {
            switch object.kind {
            case .track(let a, _): use[a, default: (0, 0)].tracks += 1
            case .flash(let a, _): use[a, default: (0, 0)].pads += 1
            case .region: break
            }
        }
        return use
    }
}

// MARK: - Excellon

nonisolated struct ExcellonHole: Hashable, Identifiable, Sendable {
    var id = UUID()
    var tool: Int
    var at: CGPoint
    /// G85 slot: routed from `at` to here.
    var slotEnd: CGPoint?

    func moved(by d: CGVector) -> ExcellonHole {
        var copy = self
        copy.at = at + d
        copy.slotEnd = slotEnd.map { $0 + d }
        return copy
    }
}

nonisolated struct ExcellonImage: Hashable, Sendable {
    /// Header comments (";…" lines), kept for provenance.
    var comments: [String] = []
    /// Tool number → hole diameter, mm.
    var tools: [Int: Double] = [:]
    var holes: [ExcellonHole] = []

    func diameter(_ tool: Int) -> Double { tools[tool] ?? 0 }

    func bounds(of hole: ExcellonHole) -> CGRect {
        let r = max(diameter(hole.tool), 0.05) / 2
        var b = CGRect(x: hole.at.x - r, y: hole.at.y - r, width: 2 * r, height: 2 * r)
        if let end = hole.slotEnd { b = b.union(CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)) }
        return b
    }

    func hitTest(_ p: CGPoint, tolerance: Double) -> UUID? {
        var best: (Double, UUID)?
        for hole in holes.reversed() {
            let r = max(diameter(hole.tool), 0.05) / 2
            let d = (hole.slotEnd.map { ShapeMath.distance(from: p, toSegment: hole.at, $0) }
                     ?? ShapeMath.distance(p, hole.at)) - r
            if d <= 0 { return hole.id }
            if d <= tolerance, d < (best?.0 ?? .infinity) { best = (d, hole.id) }
        }
        return best?.1
    }

    /// The tool drilling holes of this diameter, added when there is none.
    mutating func tool(forDiameter d: Double) -> Int {
        if let existing = tools.sorted(by: { $0.key < $1.key }).first(where: { abs($0.value - d) < 1e-6 }) {
            return existing.key
        }
        let number = (tools.keys.max() ?? 0) + 1
        tools[number] = d
        return number
    }

    var toolUse: [Int: Int] {
        var use: [Int: Int] = [:]
        for hole in holes { use[hole.tool, default: 0] += 1 }
        return use
    }
}

nonisolated func + (p: CGPoint, d: CGVector) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
