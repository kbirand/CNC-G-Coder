import Foundation
import CoreGraphics
import AppKit
import SceneKit
import QuartzCore

/// Real geometry for what a program cuts out of the board: the removed
/// area per cut depth as ONE region — the union of every slot (each run
/// of cutting moves inflated by the tool radius with round joins and
/// ends, through the Clipper port, which unions its offsets) — extruded
/// from the board top down to that depth with `SCNShape`. Overlapping
/// passes are one flat channel; walls exist only on the union's boundary.
///
/// The geometry is complete and static: during playback or live
/// machining the copper face's progressive mask (opaque where not cut yet)
/// hides what the bit has not reached.
nonisolated enum GrooveMesh {
    /// Cutter width when the program does not know its tool, mm.
    static let fallbackToolWidth = 0.2
    /// Offset arc tolerance for display, mm (finer than a pixel at any zoom
    /// the board is viewed at; far fewer vertices than the machining one).
    static let arcTolerance = 0.01
    /// The invisible opening face sits this far inside the board so it never
    /// fights the copper face at Z0.
    static let faceInset = 0.01
    /// Islands (inner rings of the removed region) smaller than this are
    /// left out, mm²: a 0.16 mm post of FR4 or copper does not stand.
    static let minimumIslandArea = 0.02

    struct Result {
        var node: SCNNode
        var bins: Int
        var rings: Int
        var ringVertices: Int
        /// Estimated (SceneKit's SCNShape tessellation is not exposed).
        var triangles: Int
        var unionTime: TimeInterval
        var tessellationTime: TimeInterval
    }

    /// Floor colour of a cut at depth `z` (negative, mm).
    static func floorColor(z: Double) -> NSColor {
        let depth = max(0, -z)
        if depth > 0.5 { return NSColor(red: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1) }
        let shade = 1 - min(depth, 0.5) / 0.5 * 0.25
        return NSColor(red: 170 / 255 * shade, green: 160 / 255 * shade, blue: 110 / 255 * shade, alpha: 1)
    }

    static func wallColor(z: Double) -> NSColor {
        let f = floorColor(z: z)
        return NSColor(red: f.redComponent * 0.78, green: f.greenComponent * 0.78, blue: f.blueComponent * 0.78, alpha: 1)
    }

    /// Whether a move removes material.
    private static func cuts(_ move: ToolpathMove) -> Bool {
        (move.kind == .cut || move.kind == .plunge) && move.zEnd < -1e-9
    }

    /// Builds the grooves of a program. `planar` maps the program's XY into
    /// the frame the board is drawn in (identity, or the back→front flip for
    /// an overlaid back-side program); `underside` puts them on the bottom
    /// face of a board `thickness` thick, opening downwards. Nil when the
    /// program cuts nothing.
    static func build(layer: ParsedLayer, planar: CGAffineTransform, underside: Bool, thickness: Double) -> Result? {
        let r = max((layer.toolDiameter ?? fallbackToolWidth) / 2, 0.02)
        let moves = layer.moves

        // Runs of consecutive cutting moves, each binned by the deepest Z it
        // reaches (0.01 mm bins). A run ends at a rapid, a non-cutting move,
        // a vertical move (a bridge rising out of an outline cut, or the
        // descent back into it) or a gap in the path. Binning the whole run
        // by its deepest Z is what a helix leaves behind: hole milling
        // spirals down in full turns and its last turn clears everything
        // above it, whereas binning every tessellated chord on its own Z
        // shredded one hole into ~180 pill-shaped slabs at as many depths.
        var runs: [Int: [[CGPoint]]] = [:]
        var current: [CGPoint] = []
        var currentDeepest: Double?
        func flush() {
            if let z = currentDeepest, current.count >= 2 {
                runs[Int((z * 100).rounded()), default: []].append(current)
            }
            current = []
            currentDeepest = nil
        }
        for move in moves {
            let planarLength = hypot(move.end.x - move.start.x, move.end.y - move.start.y) > 1e-6
            guard cuts(move), planarLength else {
                flush()
                continue
            }
            if current.last != move.start {
                flush()
                current = [move.start]
            }
            current.append(move.end)
            currentDeepest = min(currentDeepest ?? move.zEnd, move.zEnd)
        }
        flush()
        guard !runs.isEmpty else { return nil }

        // Mirror Y for the underside: the node is turned to open downwards,
        // which would mirror the drawing otherwise (see below).
        var frame = planar
        if underside { frame = frame.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }

        let root = SCNNode()
        var rings = 0, ringVertices = 0, triangles = 0
        var unionTime = 0.0, tessellationTime = 0.0
        for (bin, paths) in runs.sorted(by: { $0.key > $1.key }) {
            let z = Double(bin) / 100
            let depth = min(max(-z, 0.01), thickness + 0.6)
            let t0 = CACurrentMediaTime()
            let rawRegion = Clipper.inflate(paths.map { $0.map { $0.applying(frame) } }, by: r,
                                            join: .round, end: .round, arcTolerance: arcTolerance)
            unionTime += CACurrentMediaTime() - t0
            // Islands too thin to survive are not drawn: a hole milled as one
            // circle by a bit of less than half its diameter leaves a post at
            // the centre (4.125 mm hole, 2 mm bit: 0.125 mm across, 0.012 mm²)
            // that breaks off at the first touch; drawn, it reads as a defect.
            let region = rawRegion.filter { Clipper.area($0) >= 0 || -Clipper.area($0) >= minimumIslandArea }
            guard !region.isEmpty else { continue }
            rings += region.count
            ringVertices += region.reduce(0) { $0 + $1.count }

            let path = NSBezierPath()
            path.windingRule = .evenOdd
            for ring in region where ring.count >= 3 {
                path.move(to: ring[0])
                for p in ring.dropFirst() { path.line(to: p) }
                path.close()
            }
            let t1 = CACurrentMediaTime()
            let shape = SCNShape(path: path, extrusionDepth: CGFloat(depth))
            shape.chamferRadius = 0
            tessellationTime += CACurrentMediaTime() - t1   // SceneKit tessellates lazily at first render
            // SceneKit keeps the tessellation internal; estimate: floor ≈ one
            // triangle per ring vertex (plus bridges), walls two per edge.
            triangles += region.reduce(0) { $0 + $1.count } * 3
            shape.materials = materials(for: shape, z: z)

            // The shape lies in its local XY plane, extruded along local Z
            // (−depth/2 … +depth/2): turned so local Z is the board's Z and
            // placed so it spans the inset top face down to the floor.
            let node = SCNNode(geometry: shape)
            node.name = "groove-\(bin)"
            if underside {
                node.simdOrientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])      // local +Z → scene −Y
                node.simdPosition = SIMD3(0, Float(-thickness + faceInset + depth / 2), 0)
            } else {
                node.simdOrientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])     // local +Z → scene +Y
                node.simdPosition = SIMD3(0, Float(-faceInset - depth / 2), 0)
            }
            node.renderingOrder = 0
            root.addChildNode(node)
        }
        guard !root.childNodes.isEmpty else { return nil }
        return Result(node: root, bins: runs.count, rings: rings, ringVertices: ringVertices, triangles: triangles,
                      unionTime: unionTime, tessellationTime: tessellationTime)
    }

    /// The shape's three materials: SCNShape's are [front, back, side], and
    /// the front is the face on the local +Z side — verified by rendering a
    /// red/green/blue-coloured test shape offscreen (`SCNRenderer`) from +Z,
    /// −Z and +X: +Z shows material 0, the side material 2; the −Z face
    /// (material 1) is wound to face +Z, i.e. up into the groove, which is
    /// where the floor is seen from. (The tessellation itself is internal:
    /// `elements` stays empty, so it cannot be inspected.)
    private static func materials(for shape: SCNShape, z: Double) -> [SCNMaterial] {
        [opening(), floor(z: z), wall(z: z)]
    }

    /// Draws nothing: the copper face above shows through its own cut-out.
    private static func opening() -> SCNMaterial {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        return m
    }

    private static func floor(z: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = floorColor(z: z)
        m.specular.contents = NSColor(white: 0.2, alpha: 1)
        m.shininess = 0.3
        m.isDoubleSided = true
        return m
    }

    private static func wall(z: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = wallColor(z: z)
        m.specular.contents = NSColor(white: 0.3, alpha: 1)
        m.shininess = 0.35
        m.isDoubleSided = true
        return m
    }
}
