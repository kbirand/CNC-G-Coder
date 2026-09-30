import Foundation
import CoreGraphics

/// Identity of a drawn layer inside `LayerKind.custom`. Equality is by ID
/// only, so renaming or reordering a layer never loses the selection; the
/// rest is carried along for display and ordering.
nonisolated struct CustomLayerRef: Hashable, Sendable {
    let id: UUID
    var index: Int
    var name: String
    var back: Bool

    static func == (lhs: CustomLayerRef, rhs: CustomLayerRef) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A flattened outline: straight segments in design millimetres.
nonisolated struct Polyline: Sendable, Hashable {
    var points: [CGPoint]
    var closed: Bool

    var bounds: CGRect? {
        guard let first = points.first else { return nil }
        var r = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// Consecutive segments (the closing one included for closed outlines).
    var segments: [(CGPoint, CGPoint)] {
        guard points.count >= 2 else { return [] }
        var out: [(CGPoint, CGPoint)] = []
        for i in 1..<points.count { out.append((points[i - 1], points[i])) }
        if closed, points.count >= 3 { out.append((points[points.count - 1], points[0])) }
        return out
    }

    func applying(_ t: CGAffineTransform) -> Polyline {
        Polyline(points: points.map { $0.applying(t) }, closed: closed)
    }
}

/// Text appearance: an installed outline font (engraved along its contours)
/// or the built-in single-stroke font (engraved as one line per stroke).
nonisolated struct TextStyle: Codable, Hashable, Sendable {
    /// Font family name; empty = the built-in single-stroke font.
    var family: String = ""
    var bold = false
    var italic = false
    /// Extra space between glyphs, mm.
    var spacing: Double = 0

    var isStrokeFont: Bool { family.isEmpty }
}

/// What a drawn shape is. Coordinates are design millimetres (the Gerber
/// frame, Y up) — the same frame the project's programs are zeroed from, so
/// a drawing keeps its place on the board whatever origin is chosen later.
nonisolated enum ShapeGeometry: Codable, Hashable, Sendable {
    /// A polyline; `closed` joins the last point back to the first (polygon).
    case line(points: [CGPoint], closed: Bool)
    /// Axis-aligned before `rotation` (degrees, about the centre).
    case rect(origin: CGPoint, size: CGSize, cornerRadius: Double, rotation: Double)
    case circle(center: CGPoint, diameter: Double)
    /// `origin` is the start of the baseline; `height` the cap height, mm.
    case text(origin: CGPoint, string: String, height: Double, rotation: Double, style: TextStyle)

    var kindName: String {
        switch self {
        case .line(_, let closed): closed ? "Polygon" : "Line"
        case .rect: "Rectangle"
        case .circle: "Circle"
        case .text: "Text"
        }
    }

    var icon: String {
        switch self {
        case .line(_, let closed): closed ? "pentagon" : "line.diagonal"
        case .rect: "rectangle"
        case .circle: "circle"
        case .text: "textformat"
        }
    }

    /// Closed outlines can be cut inside/outside or pocketed.
    var isClosed: Bool {
        switch self {
        case .line(let points, let closed): closed && points.count >= 3
        case .rect, .circle, .text: true
        }
    }
}

/// One drawn object.
nonisolated struct DrawnShape: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var geometry: ShapeGeometry
    /// Width of the engraved line, mm. 0 = one pass of the tool; wider
    /// strokes are cleared with several overlapping passes.
    var strokeWidth: Double = 0
    /// Closed shapes only: clear the whole inside (pocket).
    var filled = false

    init(geometry: ShapeGeometry, strokeWidth: Double = 0, filled: Bool = false) {
        self.geometry = geometry
        self.strokeWidth = strokeWidth
        self.filled = filled
    }

    var name: String {
        switch geometry {
        case .text(_, let string, _, _, _): "“\(string.prefix(18))\(string.count > 18 ? "…" : "")”"
        default: geometry.kindName
        }
    }

    // MARK: Outline geometry

    /// The shape flattened into outlines (design mm). Curves are tessellated
    /// finely enough for milling (≤ 0.005 mm chord error at PCB sizes).
    func outlines() -> [Polyline] {
        switch geometry {
        case .line(let points, let closed):
            guard !points.isEmpty else { return [] }
            return [Polyline(points: points, closed: closed && points.count >= 3)]
        case .rect(let origin, let size, let radius, let rotation):
            return [ShapeMath.roundedRect(origin: origin, size: size, cornerRadius: radius, rotation: rotation)]
        case .circle(let center, let diameter):
            return [ShapeMath.circle(center: center, radius: max(diameter, 0) / 2)]
        case .text(let origin, let string, let height, let rotation, let style):
            return TextOutlines.outlines(string, style: style, height: height, origin: origin, rotation: rotation)
        }
    }

    var bounds: CGRect? {
        var r = CGRect.null
        for outline in outlines() { if let b = outline.bounds { r = r.union(b) } }
        return r.isNull ? nil : r
    }

    /// The point the shape is positioned by (inspector X/Y).
    var anchor: CGPoint {
        switch geometry {
        case .line(let points, _): points.first ?? .zero
        case .rect(let origin, _, _, _): origin
        case .circle(let center, _): center
        case .text(let origin, _, _, _, _): origin
        }
    }

    /// Points other shapes snap to: vertices, centres, corners, quadrants.
    func snapPoints() -> [CGPoint] {
        switch geometry {
        case .line(let points, _):
            var pts = points
            if let b = bounds { pts.append(CGPoint(x: b.midX, y: b.midY)) }
            return pts
        case .rect(let origin, let size, _, let rotation):
            let c = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            let corners = [
                origin, CGPoint(x: origin.x + size.width, y: origin.y),
                CGPoint(x: origin.x + size.width, y: origin.y + size.height), CGPoint(x: origin.x, y: origin.y + size.height),
                CGPoint(x: c.x, y: origin.y), CGPoint(x: origin.x + size.width, y: c.y),
                CGPoint(x: c.x, y: origin.y + size.height), CGPoint(x: origin.x, y: c.y)
            ]
            let t = ShapeMath.rotation(rotation, about: c)
            return corners.map { $0.applying(t) } + [c]
        case .circle(let center, let diameter):
            let r = diameter / 2
            return [center, CGPoint(x: center.x + r, y: center.y), CGPoint(x: center.x - r, y: center.y),
                    CGPoint(x: center.x, y: center.y + r), CGPoint(x: center.x, y: center.y - r)]
        case .text(let origin, _, _, _, _):
            var pts = [origin]
            if let b = bounds {
                pts += [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                        CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.midX, y: b.midY)]
            }
            return pts
        }
    }

    // MARK: Editing

    func moved(by delta: CGVector) -> DrawnShape {
        var copy = self
        switch geometry {
        case .line(let points, let closed):
            copy.geometry = .line(points: points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }, closed: closed)
        case .rect(let origin, let size, let radius, let rotation):
            copy.geometry = .rect(origin: CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy),
                                  size: size, cornerRadius: radius, rotation: rotation)
        case .circle(let center, let diameter):
            copy.geometry = .circle(center: CGPoint(x: center.x + delta.dx, y: center.y + delta.dy), diameter: diameter)
        case .text(let origin, let string, let height, let rotation, let style):
            copy.geometry = .text(origin: CGPoint(x: origin.x + delta.dx, y: origin.y + delta.dy),
                                  string: string, height: height, rotation: rotation, style: style)
        }
        return copy
    }

    /// Distance from a point to the nearest outline segment, and whether the
    /// point lies inside a closed outline — for click selection.
    func hit(_ point: CGPoint) -> (distance: Double, inside: Bool) {
        var best = Double.infinity
        var inside = false
        for outline in outlines() {
            for (a, b) in outline.segments {
                best = min(best, ShapeMath.distance(from: point, toSegment: a, b))
            }
            if outline.closed, ShapeMath.contains(outline, point) { inside.toggle() }   // even-odd: glyph holes
        }
        if case .text = geometry, let b = bounds, b.contains(point) { inside = true }
        return (best, inside)
    }
}

/// A hand-drawn layer: shapes plus the tool that machines them. One layer
/// becomes one program, like every other layer.
nonisolated struct CustomLayer: Codable, Hashable, Identifiable, Sendable {

    /// How the tool follows each shape.
    enum Operation: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The tool centre follows the drawn line (stroke width clears more).
        case engrave
        /// Closed shapes: the tool runs outside the outline, so the part inside
        /// comes out at the drawn size (cutouts, islands).
        case outside
        /// Closed shapes: the tool runs inside the outline, so the hole comes
        /// out at the drawn size.
        case inside

        var id: String { rawValue }
        var title: String {
            switch self {
            case .engrave: "Engrave centreline"
            case .outside: "Cut outside"
            case .inside: "Cut inside"
            }
        }
    }

    var id = UUID()
    var name: String
    /// Machined after flipping the board (mirrored like back copper).
    var back = false
    var operation: Operation = .engrave
    var shapes: [DrawnShape] = []

    // Tool — copied from the library, then editable (like every settings group).
    var toolID: String = ""
    var toolDiameter: Double = 0.2
    var cutDepth: Double = -0.1
    /// 0 = full depth in one pass.
    var depthPerPass: Double = 0
    var feedXY: Double = 200
    var feedZ: Double = 60
    var spindle: Double = 12000
    var dwell: Double = 1
    /// Overlap between neighbouring clearing passes, percent.
    var overlap: Double = 40

    init(name: String) { self.name = name }

    var isEmpty: Bool { shapes.isEmpty }

    /// The layer's slug and display identity for the rest of the app.
    func ref(index: Int) -> CustomLayerRef {
        CustomLayerRef(id: id, index: index, name: name, back: back)
    }

    var bounds: CGRect? {
        var r = CGRect.null
        for shape in shapes { if let b = shape.bounds { r = r.union(b) } }
        return r.isNull ? nil : r
    }

    /// Nil when every value is usable for generation, else what is wrong.
    var validationError: String? {
        if !(toolDiameter > 0) { return "Tool diameter must be positive" }
        if !(cutDepth < 0) { return "Cut depth must be below 0" }
        if depthPerPass < 0 { return "Depth per pass cannot be negative" }
        if !(feedXY > 0) || !(feedZ > 0) { return "Feeds must be positive" }
        if spindle < 0 || dwell < 0 { return "Spindle and dwell cannot be negative" }
        if overlap < 0 || overlap >= 100 { return "Overlap must be 0–99 %" }
        return nil
    }

    // Decoded field by field so project files survive fields added later.
    private enum CodingKeys: String, CodingKey {
        case id, name, back, operation, shapes, toolID, toolDiameter, cutDepth, depthPerPass
        case feedXY, feedZ, spindle, dwell, overlap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = CustomLayer(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Custom layer"
        back = try c.decodeIfPresent(Bool.self, forKey: .back) ?? false
        operation = (try? c.decodeIfPresent(Operation.self, forKey: .operation)) ?? .engrave
        shapes = (try? c.decodeIfPresent([DrawnShape].self, forKey: .shapes)) ?? []
        toolID = try c.decodeIfPresent(String.self, forKey: .toolID) ?? ""
        func d(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        toolDiameter = d(.toolDiameter, base.toolDiameter)
        cutDepth = d(.cutDepth, base.cutDepth)
        depthPerPass = d(.depthPerPass, base.depthPerPass)
        feedXY = d(.feedXY, base.feedXY)
        feedZ = d(.feedZ, base.feedZ)
        spindle = d(.spindle, base.spindle)
        dwell = d(.dwell, base.dwell)
        overlap = d(.overlap, base.overlap)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(back, forKey: .back)
        try c.encode(operation, forKey: .operation)
        try c.encode(shapes, forKey: .shapes)
        try c.encode(toolID, forKey: .toolID)
        try c.encode(toolDiameter, forKey: .toolDiameter)
        try c.encode(cutDepth, forKey: .cutDepth)
        try c.encode(depthPerPass, forKey: .depthPerPass)
        try c.encode(feedXY, forKey: .feedXY)
        try c.encode(feedZ, forKey: .feedZ)
        try c.encode(spindle, forKey: .spindle)
        try c.encode(dwell, forKey: .dwell)
        try c.encode(overlap, forKey: .overlap)
    }
}

extension Array where Element == CustomLayer {
    /// `LayerKind` for every layer, in list order.
    var refs: [CustomLayerRef] { enumerated().map { $1.ref(index: $0) } }

    func ref(id: UUID) -> CustomLayerRef? {
        guard let i = firstIndex(where: { $0.id == id }) else { return nil }
        return self[i].ref(index: i)
    }

    /// Changes whenever anything that affects the programs changes.
    var signature: String {
        var hasher = Hasher()
        hasher.combine(self)
        return String(hasher.finalize())
    }

    var hasShapes: Bool { contains { !$0.isEmpty } }
}
