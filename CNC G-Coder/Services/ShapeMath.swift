import Foundation
import CoreGraphics

/// Plane geometry for the shape editor and the custom-layer generator:
/// tessellation of the primitive shapes, hit testing, and offsetting of
/// outlines (which is how stroke widths, inside/outside cuts and pockets are
/// turned into tool passes). Everything is in design millimetres.
nonisolated enum ShapeMath {

    /// Largest chord error when curves are flattened, mm.
    static let chordTolerance = 0.004

    // MARK: - Primitives

    static func rotation(_ degrees: Double, about center: CGPoint) -> CGAffineTransform {
        guard degrees != 0 else { return .identity }
        return CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
    }

    /// Number of segments for an arc of `radius` sweeping `angle` radians.
    static func arcSteps(radius: Double, angle: Double) -> Int {
        guard radius > chordTolerance else { return 1 }
        let step = 2 * acos(max(0, 1 - chordTolerance / radius))
        return max(2, Int(ceil(abs(angle) / max(step, 0.017))))   // never coarser than 1°
    }

    static func arcPoints(center: CGPoint, radius: Double, from a0: Double, to a1: Double,
                          includeStart: Bool) -> [CGPoint] {
        let steps = arcSteps(radius: radius, angle: a1 - a0)
        var pts: [CGPoint] = []
        for s in (includeStart ? 0 : 1)...steps {
            let a = a0 + (a1 - a0) * Double(s) / Double(steps)
            pts.append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
        }
        return pts
    }

    static func circle(center: CGPoint, radius: Double) -> Polyline {
        guard radius > 0 else { return Polyline(points: [center], closed: false) }
        let steps = max(24, arcSteps(radius: radius, angle: 2 * .pi))
        var pts: [CGPoint] = []
        pts.reserveCapacity(steps)
        for s in 0..<steps {
            let a = 2 * .pi * Double(s) / Double(steps)
            pts.append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
        }
        return Polyline(points: pts, closed: true)
    }

    /// Counter-clockwise rectangle from its lower-left corner, corners rounded
    /// by `cornerRadius` (clamped to half the shorter side), rotated about the centre.
    static func roundedRect(origin: CGPoint, size: CGSize, cornerRadius: Double, rotation: Double) -> Polyline {
        let w = abs(size.width), h = abs(size.height)
        let o = CGPoint(x: min(origin.x, origin.x + size.width), y: min(origin.y, origin.y + size.height))
        let r = min(max(cornerRadius, 0), min(w, h) / 2)
        var pts: [CGPoint] = []
        if r <= chordTolerance {
            pts = [o, CGPoint(x: o.x + w, y: o.y), CGPoint(x: o.x + w, y: o.y + h), CGPoint(x: o.x, y: o.y + h)]
        } else {
            let corners: [(CGPoint, Double)] = [
                (CGPoint(x: o.x + w - r, y: o.y + r), -Double.pi / 2),
                (CGPoint(x: o.x + w - r, y: o.y + h - r), 0),
                (CGPoint(x: o.x + r, y: o.y + h - r), Double.pi / 2),
                (CGPoint(x: o.x + r, y: o.y + r), Double.pi)
            ]
            for (c, a0) in corners {
                pts += arcPoints(center: c, radius: r, from: a0, to: a0 + .pi / 2, includeStart: true)
            }
        }
        let t = ShapeMath.rotation(rotation, about: CGPoint(x: o.x + w / 2, y: o.y + h / 2))
        return Polyline(points: pts.map { $0.applying(t) }, closed: true)
    }

    // MARK: - Measures

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-18 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// Signed area: positive for counter-clockwise outlines.
    static func signedArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Even-odd point-in-polygon.
    static func contains(_ outline: Polyline, _ p: CGPoint) -> Bool {
        let pts = outline.points
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func length(_ outline: Polyline) -> Double {
        outline.segments.reduce(0) { $0 + distance($1.0, $1.1) }
    }

    // MARK: - Offsetting

    /// Drops repeated points (and, for closed outlines, a repeated last point).
    static func cleaned(_ outline: Polyline) -> Polyline {
        var pts: [CGPoint] = []
        for p in outline.points where pts.last.map({ distance($0, p) > 1e-7 }) ?? true { pts.append(p) }
        if outline.closed, pts.count > 1, let f = pts.first, let l = pts.last, distance(f, l) <= 1e-7 { pts.removeLast() }
        return Polyline(points: pts, closed: outline.closed)
    }

    /// Offsets an outline by `delta` millimetres. Closed outlines: positive
    /// moves outward, negative inward, whatever their winding. Open polylines:
    /// positive is to the left of the direction of travel. Joins are rounded
    /// where the offset opens a gap and intersected where it overlaps — the
    /// shape a round cutter of that radius would actually produce.
    /// Nil when the result collapses (an inward offset past the shape's core).
    static func offset(_ input: Polyline, by delta: Double) -> Polyline? {
        var outline = cleaned(input)
        guard abs(delta) > 1e-9 else { return outline }
        if outline.closed {
            guard outline.points.count >= 3 else { return nil }
            if signedArea(outline.points) < 0 { outline.points.reverse() }   // CCW: outward = right side
        } else {
            guard outline.points.count >= 2 else { return nil }
        }
        let pts = outline.points
        let n = pts.count
        let edgeCount = outline.closed ? n : n - 1
        // For a CCW closed outline, outward is the right-hand normal; for an
        // open polyline "left" is requested, so flip the sign.
        let d = outline.closed ? delta : -delta

        var edges: [Edge] = []
        edges.reserveCapacity(edgeCount)
        for i in 0..<edgeCount {
            let p = pts[i], q = pts[(i + 1) % n]
            let dx = q.x - p.x, dy = q.y - p.y
            let len = hypot(dx, dy)
            let ux = dx / len, uy = dy / len
            let nx = uy * d, ny = -ux * d       // right-hand normal × d
            edges.append(Edge(a: CGPoint(x: p.x + nx, y: p.y + ny), b: CGPoint(x: q.x + nx, y: q.y + ny),
                              dir: CGPoint(x: ux, y: uy), end: q))
        }
        guard edges.count >= (outline.closed ? 3 : 1) else { return nil }

        var out: [CGPoint] = []
        // Where each offset edge effectively starts and ends after its joins:
        // an edge whose direction reverses has been swallowed by the offset.
        var edgeStart = edges.map(\.a)
        var edgeEnd = edges.map(\.b)
        if !outline.closed { out.append(edges[0].a) }
        let joins = outline.closed ? edges.count : edges.count - 1
        for k in 0..<joins {
            let next = (k + 1) % edges.count
            let e1 = edges[k], e2 = edges[next]
            let vertex = e1.end
            let cross = e1.dir.x * e2.dir.y - e1.dir.y * e2.dir.x
            let dot = e1.dir.x * e2.dir.x + e1.dir.y * e2.dir.y
            // Turning left (cross > 0) with the offset on the right (d > 0), or
            // vice versa, opens a gap at the corner that a round join fills;
            // otherwise the offset edges overlap and are trimmed at their crossing.
            let gap = (cross > 1e-12) == (d > 0)
            if abs(cross) < 1e-9, dot > 0 {
                out.append(e1.b)   // straight on
            } else if gap {
                let a0 = atan2(e1.b.y - vertex.y, e1.b.x - vertex.x)
                var a1 = atan2(e2.a.y - vertex.y, e2.a.x - vertex.x)
                // Sweep the short way round the vertex.
                while a1 - a0 > .pi { a1 -= 2 * .pi }
                while a1 - a0 < -.pi { a1 += 2 * .pi }
                out += arcPoints(center: vertex, radius: abs(d), from: a0, to: a1, includeStart: true)
            } else if let x = intersection(e1.a, e1.b, e2.a, e2.b) {
                // A join that shoots far past the corner marks a collapsing
                // sliver (very acute angle): clamp it rather than spiking.
                if distance(x, vertex) > abs(d) * 4 {
                    out.append(e1.b); out.append(e2.a)
                } else {
                    out.append(x)
                    edgeEnd[k] = x
                    edgeStart[next] = x
                }
            } else {
                out.append(e1.b)
            }
        }
        if !outline.closed { out.append(edges[edges.count - 1].b) }

        if outline.closed {
            for k in edges.indices {
                let dx = edgeEnd[k].x - edgeStart[k].x, dy = edgeEnd[k].y - edgeStart[k].y
                if dx * edges[k].dir.x + dy * edges[k].dir.y <= 1e-9 { return nil }   // inside out
            }
        }

        let result = cleaned(Polyline(points: out, closed: outline.closed))
        if outline.closed {
            guard result.points.count >= 3 else { return nil }
            // An inward offset that turned the outline inside out has collapsed.
            let area = signedArea(result.points)
            if area <= 1e-9 { return nil }
            if delta < 0, area >= signedArea(pts) { return nil }
            if let b = result.bounds, delta < 0, b.width < 1e-6 || b.height < 1e-6 { return nil }
        } else {
            guard result.points.count >= 2 else { return nil }
        }
        return result
    }

    private struct Edge {
        var a: CGPoint      // offset start
        var b: CGPoint      // offset end
        var dir: CGPoint    // unit direction
        var end: CGPoint    // the original vertex at the end of this edge
    }

    /// Intersection of the infinite lines through a→b and c→d.
    static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-12 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denom
        return CGPoint(x: a.x + t * r.x, y: a.y + t * r.y)
    }

    /// Concentric inward rings that clear the inside of a closed outline with
    /// a tool of `toolDiameter`, stepping by `stepOver`; innermost first.
    /// Starts at the outline offset inward by half the tool (the wall).
    static func pocketRings(_ outline: Polyline, toolDiameter: Double, stepOver: Double) -> [Polyline] {
        var rings: [Polyline] = []
        var delta = -toolDiameter / 2
        var lastArea = Double.infinity
        while let ring = offset(outline, by: delta), rings.count < 2000 {
            let area = abs(signedArea(ring.points))
            guard area < lastArea - 1e-9 else { break }   // no longer shrinking: done
            rings.append(ring)
            lastArea = area
            delta -= stepOver
        }
        // A core narrower than the last step but wider than the tool would be
        // left standing: finish with a pass down its middle.
        if let last = rings.last, let b = last.bounds, min(b.width, b.height) > toolDiameter {
            let horizontal = b.width >= b.height
            let inset = min(b.width, b.height) / 2
            let core = horizontal
                ? Polyline(points: [CGPoint(x: b.minX + inset, y: b.midY), CGPoint(x: b.maxX - inset, y: b.midY)], closed: false)
                : Polyline(points: [CGPoint(x: b.midX, y: b.minY + inset), CGPoint(x: b.midX, y: b.maxY - inset)], closed: false)
            rings.append(core.points.count == 2 && distance(core.points[0], core.points[1]) < 1e-6
                         ? Polyline(points: [core.points[0]], closed: false) : core)
        }
        return rings.reversed()
    }
}
