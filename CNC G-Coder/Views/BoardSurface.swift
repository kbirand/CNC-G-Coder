import Foundation
import CoreGraphics
import QuartzCore
import Metal

/// One face of the board as a bitmap the 3D view maps onto the slab: opaque
/// copper to start with, and every cutting move of the shown programs
/// punched out of it (alpha 0) — the slot width of the tool, drill holes as
/// discs — so the groove geometry under the face (`GrooveMesh`) and the
/// hole cylinders show through where material is gone. The copper edge is
/// the only raster element left, hence the resolution.
///
/// Two kinds of content: the static programs (`setStatic`, repainted whole)
/// and one progressive program (`paintProgressive`: the one playing or
/// being streamed), painted incrementally — only the moves since the last
/// call are stroked, so an 8 000-move program costs a few strokes per tick.
/// Asking for fewer moves than painted (scrubbing back, a new program)
/// clears and repaints. The bitmap is BGRA8 premultiplied, the layout of
/// the `MTLTexture` the slab face samples, and `upload(to:)` copies only
/// the rectangle painted since the last upload into that texture in place
/// (no CGImage, no re-upload of the whole face; at most 10 Hz while
/// throttled, nothing at all when nothing was painted).
@MainActor
final class BoardSurfaceTexture {
    /// The face in world mm (the frame the programs are painted in).
    let rect: CGRect
    let pixelsPerMM: Double
    let pixelSize: (width: Int, height: Int)

    private let context: CGContext
    /// World mm → bitmap pixels.
    private let toPixels: CGAffineTransform

    private var staticLayers: [(layer: ParsedLayer, transform: CGAffineTransform)] = []
    /// The progressive program's identity and how many of its moves are in.
    private var progressive: (token: String, painted: Int)?
    /// Bitmap pixels painted since the last upload (CG coordinates, y up).
    private var dirtyRect = CGRect.null
    private var uploadTime: TimeInterval = 0

    static let minimumPixelsPerMM = 8.0
    static let maximumPixelsPerMM = 24.0
    static let longestEdgePixels = 4096.0
    /// Shortest interval between uploads while throttled: once per frame
    /// (uploads copy only the dirty rectangle, so this is cheap) — the cut
    /// must open under the bit as smoothly as the bit moves.
    static let uploadInterval: TimeInterval = 1.0 / 60

    /// Fallback cutter width when a program does not know its tool, mm.
    static let fallbackToolWidth = 0.2

    init?(rect: CGRect) {
        guard rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { return nil }
        self.rect = rect
        let longest = max(rect.width, rect.height)
        let ppm = min(max(Self.longestEdgePixels / longest, Self.minimumPixelsPerMM), Self.maximumPixelsPerMM)
        pixelsPerMM = ppm
        let width = max(1, Int((rect.width * ppm).rounded(.up)))
        let height = max(1, Int((rect.height * ppm).rounded(.up)))
        pixelSize = (width, height)
        // BGRA8 premultiplied, little-endian: `MTLPixelFormat.bgra8Unorm`'s
        // layout, so rows go into the texture untouched.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else { return nil }
        self.context = context
        toPixels = CGAffineTransform(scaleX: ppm, y: ppm).translatedBy(x: -rect.minX, y: -rect.minY)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.interpolationQuality = .none
        fillBase()
    }

    // MARK: - Content

    /// Replaces the static programs and repaints everything (the
    /// progressive program starts again from nothing).
    func setStatic(_ layers: [(layer: ParsedLayer, transform: CGAffineTransform)]) {
        staticLayers = layers
        progressive = nil
        repaintAll()
    }

    /// A smaller count than painted by up to this many moves is left as it
    /// is (painting is additive, and a live job's position-matched progress
    /// steps back a little now and then); a bigger step back — a scrub —
    /// repaints from the start.
    static let regressionTolerance = 100

    /// Paints the progressive program up to `completed` whole moves plus
    /// `fraction` of the next one. `token` identifies the program; a
    /// different token or a (clearly) smaller count repaints from the start.
    func paintProgressive(layer: ParsedLayer, token: String, transform: CGAffineTransform,
                          completed: Int, fraction: Double) {
        let completed = min(max(completed, 0), layer.moves.count)
        var painted = completed
        if let p = progressive, p.token == token, p.painted <= completed + Self.regressionTolerance {
            if p.painted < completed {
                paint(layer, transform: transform, from: p.painted, to: completed)
            } else {
                painted = p.painted
            }
        } else {
            let start = CACurrentMediaTime()
            repaintAll()
            paint(layer, transform: transform, from: 0, to: completed)
            if UserDefaults.standard.bool(forKey: "debugDumpViews") {
                print(String(format: "[debug] board surface: repaint with %d progressive moves in %.1f ms (all layers)",
                             completed, (CACurrentMediaTime() - start) * 1000))
            }
        }
        progressive = (token, painted)
        // The move in progress, up to the tool (idempotent overdraw).
        if fraction > 0, completed < layer.moves.count {
            paintPartial(layer.moves[completed], fraction: min(fraction, 1), layer: layer, transform: transform)
        }
    }

    // MARK: - Texture

    /// A texture of the bitmap's size and layout for `upload(to:)`.
    func makeTexture(device: any MTLDevice) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: pixelSize.width,   // sRGB: the bitmap holds colour, not linear light
                                                                  height: pixelSize.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Whether anything painted since the last upload is waiting.
    var needsUpload: Bool { !dirtyRect.isNull }

    /// Copies the pixels painted since the last upload into `texture`
    /// (the dirty rectangle only; everything after a repaint). While
    /// `throttled`, at most once per frame. True when something was uploaded.
    @discardableResult
    func upload(to texture: any MTLTexture, throttled: Bool) -> Bool {
        guard !dirtyRect.isNull, let base = context.data else { return false }
        let now = CACurrentMediaTime()
        if throttled, now - uploadTime < Self.uploadInterval { return false }
        let bounds = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        let r = dirtyRect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { dirtyRect = .null; return false }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        // CG rows run upward; the bitmap's first row in memory is the top.
        let firstRow = pixelSize.height - (y0 + h)
        let bytesPerRow = context.bytesPerRow
        let pointer = base.advanced(by: firstRow * bytesPerRow + x0 * 4)
        texture.replace(region: MTLRegionMake2D(x0, firstRow, w, h), mipmapLevel: 0,
                        withBytes: pointer, bytesPerRow: bytesPerRow)
        dirtyRect = .null
        uploadTime = now
        return true
    }

    /// The whole bitmap as an image (not used per tick).
    func makeImage() -> CGImage? { context.makeImage() }

    private func markDirty(_ rect: CGRect) {
        dirtyRect = dirtyRect.isNull ? rect : dirtyRect.union(rect)
    }

    private func markAllDirty() {
        dirtyRect = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
    }

    // MARK: - Painting

    private func fillBase() {
        // Copper with a subtle vertical gradient (lighter at the top), opaque.
        let colors = [CGColor(red: 0.76, green: 0.49, blue: 0.23, alpha: 1),
                      CGColor(red: 0.68, green: 0.42, blue: 0.18, alpha: 1)] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        context.saveGState()
        context.resetClip()
        context.setBlendMode(.copy)
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(pixelSize.height)),
                                       end: CGPoint(x: 0, y: 0), options: [])
        } else {
            context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height))
        }
        context.restoreGState()
        markAllDirty()
    }

    private func repaintAll() {
        let start = CACurrentMediaTime()
        fillBase()
        for item in staticLayers {
            paint(item.layer, transform: item.transform, from: 0, to: item.layer.moves.count)
        }
        progressive = nil
        if UserDefaults.standard.bool(forKey: "debugDumpViews") {
            let moves = staticLayers.reduce(0) { $0 + $1.layer.moves.count }
            print(String(format: "[debug] board surface %dx%d px (%.1f px/mm): full repaint of %d static moves in %.1f ms",
                         pixelSize.width, pixelSize.height, pixelsPerMM, moves, (CACurrentMediaTime() - start) * 1000))
        }
    }

    /// Cut pixels are punched out: painted with `.copy` blending in a fully
    /// transparent colour, the face shows what lies beneath.
    private static let cutColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    private static let holeColor = cutColor

    /// Whether a move removes material at the surface.
    private static func cuts(_ move: ToolpathMove) -> Bool {
        (move.kind == .cut || move.kind == .plunge) && move.zEnd < -1e-9
    }

    /// Segments per stroked path. CoreGraphics' stroker is superlinear in
    /// the path size (one path of 8 000 segments: ~550 ms; 256-segment runs
    /// of joined polylines: ~11 ms for the same program), so moves are
    /// stroked as consecutive runs, flushed every `chunk` segments.
    private static let chunk = 256

    /// Punches moves `from..<to` of `layer` (and the holes that start in
    /// that range) out of the face: joined polyline runs, flushed in chunks.
    private func paint(_ layer: ParsedLayer, transform: CGAffineTransform, from: Int, to: Int) {
        guard from < to, from >= 0, to <= layer.moves.count else { return }
        let fullTransform = transform.concatenating(toPixels)
        let drill = layer.id.isDrill
        if !drill {
            let width = CGFloat((layer.toolDiameter ?? Self.fallbackToolWidth) * pixelsPerMM)
            context.setLineWidth(max(width, 1))
            context.setBlendMode(.copy)
            context.setStrokeColor(Self.cutColor)
            var path = CGMutablePath()
            var count = 0
            var last: CGPoint?
            let pad = CGFloat(max(width, 1) / 2 + 2)
            func flush() {
                guard count > 0 else { return }
                markDirty(path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad))
                context.addPath(path)
                context.strokePath()
                path = CGMutablePath()
                count = 0
                last = nil
            }
            for move in layer.moves[from..<to] where Self.cuts(move) {
                let a = move.start.applying(fullTransform), b = move.end.applying(fullTransform)
                if last != a { path.move(to: a) }
                path.addLine(to: b)
                last = b
                count += 1
                if count >= Self.chunk { flush() }
            }
            flush()
        }
        // Holes: a disc once their first plunge is in the painted range.
        context.setBlendMode(.copy)
        context.setFillColor(Self.holeColor)
        for hole in layer.drillHoles where hole.moveIndex >= from && hole.moveIndex < to {
            let c = hole.center.applying(fullTransform)
            let r = CGFloat(hole.diameter / 2 * pixelsPerMM)
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            markDirty(disc.insetBy(dx: -2, dy: -2))
            context.fillEllipse(in: disc)
        }
    }

    /// The in-progress move from its start to the tool.
    private func paintPartial(_ move: ToolpathMove, fraction: Double, layer: ParsedLayer, transform: CGAffineTransform) {
        guard Self.cuts(move), !layer.id.isDrill else { return }
        let fullTransform = transform.concatenating(toPixels)
        let end = CGPoint(x: move.start.x + (move.end.x - move.start.x) * fraction,
                          y: move.start.y + (move.end.y - move.start.y) * fraction)
        let width = CGFloat((layer.toolDiameter ?? Self.fallbackToolWidth) * pixelsPerMM)
        context.setLineWidth(max(width, 1))
        context.setBlendMode(.copy)
        context.setStrokeColor(Self.cutColor)
        let a = move.start.applying(fullTransform), b = end.applying(fullTransform)
        let pad = CGFloat(max(width, 1) / 2 + 2)
        markDirty(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    .insetBy(dx: -pad, dy: -pad))
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
    }
}
