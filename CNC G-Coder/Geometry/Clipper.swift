import Foundation
import CoreGraphics

/// Polygon booleans and offsetting (Clipper2, through ThirdParty/ClipperShim)
/// in millimetres. Coordinates go to Clipper as integers of 0.1 µm, far
/// below anything a mill can resolve, so rounding never shows.
nonisolated enum Clipper {
    typealias Path = [CGPoint]
    typealias Paths = [Path]

    static let scale = 10_000.0

    enum Op: Int32 { case intersection = 0, union, difference, xor }
    enum Fill: Int32 { case evenOdd = 0, nonZero, positive, negative }
    enum Join: Int32 { case square = 0, bevel, round, miter }
    enum End: Int32 { case polygon = 0, joined, butt, square, round }

    /// Largest deviation of offset arcs from the true circle, mm.
    static let arcTolerance = 0.002

    // MARK: Operations

    static func boolean(_ op: Op, subject: Paths = [], openSubject: Paths = [], clip: Paths = [],
                        fill: Fill = .nonZero) -> (closed: Paths, open: Paths) {
        let s = pack(subject), o = pack(openSubject), c = pack(clip)
        var openCount: Int32 = 0
        let result = s.coords.withUnsafeBufferPointer { sc in
            s.counts.withUnsafeBufferPointer { sn in
                o.coords.withUnsafeBufferPointer { oc in
                    o.counts.withUnsafeBufferPointer { on in
                        c.coords.withUnsafeBufferPointer { cc in
                            c.counts.withUnsafeBufferPointer { cn in
                                cs_boolean(op.rawValue, fill.rawValue,
                                           sc.baseAddress, sn.baseAddress, Int32(subject.count),
                                           oc.baseAddress, on.baseAddress, Int32(openSubject.count),
                                           cc.baseAddress, cn.baseAddress, Int32(clip.count),
                                           &openCount)
                            }
                        }
                    }
                }
            }
        }
        let all = unpack(result)
        let closedCount = all.count - Int(openCount)
        return (Array(all.prefix(max(closedCount, 0))), Array(all.suffix(Int(openCount))))
    }

    static func union(_ paths: Paths, fill: Fill = .nonZero) -> Paths {
        guard !paths.isEmpty else { return [] }
        return boolean(.union, subject: paths, fill: fill).closed
    }

    static func difference(_ a: Paths, _ b: Paths) -> Paths {
        guard !a.isEmpty else { return [] }
        guard !b.isEmpty else { return a }
        return boolean(.difference, subject: a, clip: b).closed
    }

    static func intersection(_ a: Paths, _ b: Paths) -> Paths {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        return boolean(.intersection, subject: a, clip: b).closed
    }

    /// Open paths clipped to the inside of `region`.
    static func clipLines(_ lines: Paths, to region: Paths) -> Paths {
        guard !lines.isEmpty, !region.isEmpty else { return [] }
        return boolean(.intersection, openSubject: lines, clip: region).open
    }

    /// Grows (positive `delta`) or shrinks polygons; open paths with a
    /// non-polygon end type become their outline at `delta` from the line.
    static func inflate(_ paths: Paths, by delta: Double, join: Join = .round, end: End = .polygon,
                        arcTolerance: Double = Clipper.arcTolerance) -> Paths {
        guard !paths.isEmpty else { return [] }
        let p = pack(paths)
        let result = p.coords.withUnsafeBufferPointer { pc in
            p.counts.withUnsafeBufferPointer { pn in
                cs_inflate(pc.baseAddress, pn.baseAddress, Int32(paths.count), delta * scale,
                           join.rawValue, end.rawValue, 2.0, arcTolerance * scale)
            }
        }
        return unpack(result)
    }

    // MARK: Measures

    /// Signed area (mm²): positive for counter-clockwise rings (Y up).
    static func area(_ path: Path) -> Double {
        guard path.count >= 3 else { return 0 }
        var a = 0.0
        var prev = path[path.count - 1]
        for p in path {
            a += (prev.x * p.y - p.x * prev.y)
            prev = p
        }
        return a / 2
    }

    /// Total area of a set of rings as Clipper returns them (holes negative).
    static func area(_ paths: Paths) -> Double {
        paths.reduce(0) { $0 + area($1) }
    }

    // MARK: Marshalling

    private static func pack(_ paths: Paths) -> (coords: [Int64], counts: [Int32]) {
        var coords: [Int64] = []
        var counts: [Int32] = []
        coords.reserveCapacity(paths.reduce(0) { $0 + $1.count } * 2)
        counts.reserveCapacity(paths.count)
        for path in paths {
            counts.append(Int32(path.count))
            for p in path {
                coords.append(Int64((p.x * scale).rounded()))
                coords.append(Int64((p.y * scale).rounded()))
            }
        }
        // Never hand C a null pointer for a non-zero count.
        if coords.isEmpty { coords = [0] }
        if counts.isEmpty { counts = [0] }
        return (coords, counts)
    }

    private static func unpack(_ result: CSPaths) -> Paths {
        defer { cs_free(result) }
        guard result.ok != 0, let coords = result.coords, let counts = result.counts else { return [] }
        var out: Paths = []
        out.reserveCapacity(Int(result.pathCount))
        var k = 0
        for i in 0..<Int(result.pathCount) {
            let n = Int(counts[i])
            var path: Path = []
            path.reserveCapacity(n)
            for _ in 0..<n {
                path.append(CGPoint(x: Double(coords[k]) / scale, y: Double(coords[k + 1]) / scale))
                k += 2
            }
            out.append(path)
        }
        return out
    }
}
