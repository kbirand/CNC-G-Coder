import SwiftUI
import AppKit

/// The layer-file editor's half of the toolpath canvas: the imported file's
/// artwork (pads, tracks, regions, holes) drawn over its program, selection,
/// and pointer and key events for LayerFileEditor. The artwork is in design
/// millimetres; `layerEditTransform` maps it into the canvas' world frame
/// exactly as the file's program is (mirrored for the back side, un-mirrored
/// on request) — so the artwork sits on its own isolation paths.
extension ToolpathCanvasView {

    /// Drawing pieces per object, cached by value: flattening arcs and
    /// aperture macros is not free, and the canvas redraws on every hover.
    final class ArtworkPieceCache {
        struct Piece {
            /// Pads, regions, round holes (even-odd filled).
            var fill: Path?
            /// Track centre lines and slots, stroked at `width`.
            var stroke: Path?
            var width: Double = 0
            var round = true
        }
        private struct GerberKey: Hashable {
            var object: GerberObject
            var aperture: GerberAperture?
        }
        private struct HoleKey: Hashable {
            var hole: ExcellonHole
            var diameter: Double
        }
        private var gerber: [GerberKey: Piece] = [:]
        private var holes: [HoleKey: Piece] = [:]

        func piece(_ object: GerberObject, in image: GerberImage) -> Piece {
            let key = GerberKey(object: object, aperture: object.aperture.flatMap { image.apertures[$0] })
            if let cached = gerber[key] { return cached }
            if gerber.count > 20_000 { gerber.removeAll() }
            var piece = Piece()
            switch object.kind {
            case .track(let a, let path):
                piece.stroke = Self.polyline(path.flattened(), closed: false)
                piece.width = image.trackWidth(aperture: a)
                piece.round = image.apertures[a]?.shape != .rectangle
            case .flash(let a, let at):
                var p = Path()
                for outline in image.flashOutlines(aperture: a, at: at) {
                    p.addPath(Self.polyline(outline.points, closed: true))
                }
                piece.fill = p
            case .region(let contours):
                var p = Path()
                for contour in contours { p.addPath(Self.polyline(contour.flattened(), closed: true)) }
                piece.fill = p
            }
            gerber[key] = piece
            return piece
        }

        func piece(_ hole: ExcellonHole, in image: ExcellonImage) -> Piece {
            let key = HoleKey(hole: hole, diameter: image.diameter(hole.tool))
            if let cached = holes[key] { return cached }
            if holes.count > 20_000 { holes.removeAll() }
            let d = max(key.diameter, 0.05)
            var piece = Piece()
            if let end = hole.slotEnd {
                piece.stroke = Self.polyline([hole.at, end], closed: false)
                piece.width = d
            } else {
                piece.fill = Path(ellipseIn: CGRect(x: hole.at.x - d / 2, y: hole.at.y - d / 2, width: d, height: d))
            }
            holes[key] = piece
            return piece
        }

        private static func polyline(_ points: [CGPoint], closed: Bool) -> Path {
            var p = Path()
            guard let first = points.first else { return p }
            p.move(to: first)
            for q in points.dropFirst() { p.addLine(to: q) }
            if closed { p.closeSubpath() }
            return p
        }
    }

    /// Editing an imported file (and not drawing on a custom layer).
    var layerEditActive: Bool {
        !editorActive && layerEditor.isActive
    }

    /// Design (Gerber) coordinates → the canvas' world frame for the file
    /// being edited: its side's program frame, un-mirrored on request.
    func layerEditTransform() -> CGAffineTransform {
        let frame = CustomLayerGenerator.ProgramFrame(document: preview.document,
                                                      mirrorAxis: Double(params.mirrorAxis) ?? 0,
                                                      mirrorYAxis: params.mirrorYAxis)
        let target = layerEditor.target
        var t = frame.designToProgram(back: target?.isBackSide ?? false)
        if let kind = target?.backProgram, let flip = displayTransform(for: kind) {
            t = t.concatenating(flip)
        }
        return t
    }

    private func layerDesignPoint(fromView p: CGPoint, map: Mapping) -> CGPoint {
        CGPoint(x: map.worldX(p.x), y: map.worldY(p.y)).applying(layerEditTransform().inverted())
    }

    private func layerSnapContext(map: Mapping) -> ShapeEditor.SnapContext {
        var context = ShapeEditor.SnapContext(tolerance: 6 / map.scale)
        if snapToGrid {
            let t = layerEditTransform()
            let inverse = t.inverted()
            let step = tickStep(scale: map.scale).mm / 2
            context.gridSnap = { (p: CGPoint) -> CGPoint in
                let w = p.applying(t)
                return CGPoint(x: (w.x / step).rounded() * step, y: (w.y / step).rounded() * step).applying(inverse)
            }
        }
        return context
    }

    private var layerEditShift: Bool { NSEvent.modifierFlags.contains(.shift) }

    // MARK: - Pointer events

    func layerEditClick(at location: CGPoint) {
        guard let map = mapping(in: canvasSize), map.plot.contains(location) else { return }
        layerEditor.click(at: layerDesignPoint(fromView: location, map: map), shift: layerEditShift,
                          tolerance: 6 / map.scale)
        canvasFocused = true
    }

    func layerEditDragChanged(_ value: DragGesture.Value) {
        guard var drag = editDrag, let map = mapping(in: canvasSize) else { return }
        if !drag.started {
            guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
            drag.started = true
            editDrag = drag
            layerEditor.dragBegan(at: layerDesignPoint(fromView: drag.start, map: map), shift: layerEditShift,
                                  tolerance: 6 / map.scale)
        }
        layerEditor.dragChanged(to: layerDesignPoint(fromView: value.location, map: map),
                                context: layerSnapContext(map: map))
    }

    func layerEditDragEnded(_ value: DragGesture.Value) {
        defer { editDrag = nil }
        guard let drag = editDrag, let map = mapping(in: canvasSize) else { return }
        if drag.started {
            layerEditor.dragEnded(at: layerDesignPoint(fromView: value.location, map: map), shift: layerEditShift,
                                  context: layerSnapContext(map: map))
        } else {
            layerEditor.click(at: layerDesignPoint(fromView: drag.start, map: map), shift: layerEditShift,
                              tolerance: 6 / map.scale)
        }
        canvasFocused = true
    }

    func layerEditKey(_ press: KeyPress) -> KeyPress.Result {
        guard layerEditActive else { return .ignored }
        let editor = layerEditor
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "a": return afterKeyEvent { editor.selectAll() }
            default: return .ignored
            }
        }
        // Arrows move in the view's directions: on an un-mirrored back side
        // the design X runs the other way.
        let step = press.modifiers.contains(.shift) ? 1.0 : 0.1
        let t = layerEditTransform()
        let sx: Double = t.a < 0 ? -1 : 1, sy: Double = t.d < 0 ? -1 : 1
        switch press.key {
        case .escape: return afterKeyEvent { editor.cancel() }
        case .delete, .deleteForward: return afterKeyEvent { editor.deleteSelection() }
        case .leftArrow: return afterKeyEvent { editor.nudge(dx: -step * sx, dy: 0) }
        case .rightArrow: return afterKeyEvent { editor.nudge(dx: step * sx, dy: 0) }
        case .upArrow: return afterKeyEvent { editor.nudge(dx: 0, dy: step * sy) }
        case .downArrow: return afterKeyEvent { editor.nudge(dx: 0, dy: -step * sy) }
        default: return .ignored
        }
    }

    func layerEditPointerStyle(at hover: CGPoint, map: Mapping) -> PointerStyle? {
        guard layerEditActive, map.plot.contains(hover) else { return nil }
        if NSEvent.modifierFlags.contains(.option) { return .grabIdle }
        if layerEditor.isDragging { return .grabActive }
        return layerEditor.isOverSelection(layerDesignPoint(fromView: hover, map: map), tolerance: 6 / map.scale)
            ? .grabIdle : nil
    }

    // MARK: - Drawing

    /// Artwork colour per kind of file, chosen to stand apart from the
    /// program drawn underneath it.
    private var artworkColor: Color {
        switch layerEditor.target {
        case .layer(let slot):
            switch slot {
            case .front, .back: Color(red: 0.95, green: 0.58, blue: 0.22)       // copper
            case .topMask, .bottomMask: Color(red: 0.25, green: 0.75, blue: 0.4)
            case .topSilk, .bottomSilk: Color(white: 0.92)
            case .outline, .drill: Color(white: 0.7)
            }
        case .drill: Color(white: 0.85)
        case nil: .gray
        }
    }

    func drawLayerEdit(_ context: GraphicsContext, map: Mapping, world: CGAffineTransform) {
        guard layerEditActive, let artwork = layerEditor.displayed else { return }
        let t = layerEditTransform()
        let hairline = 1.2 / map.scale
        let color = artworkColor
        let selection = layerEditor.selection
        let cache = artworkCache

        var ctx = context
        ctx.clip(to: Path(map.plot))
        ctx.concatenate(world)
        ctx.concatenate(t)

        func draw(_ piece: ArtworkPieceCache.Piece, in c: inout GraphicsContext, shading: GraphicsContext.Shading) {
            if let fill = piece.fill { c.fill(fill, with: shading, style: FillStyle(eoFill: true)) }
            if let stroke = piece.stroke {
                c.stroke(stroke, with: shading,
                         style: StrokeStyle(lineWidth: max(piece.width, hairline),
                                            lineCap: piece.round ? .round : .square, lineJoin: .round))
            }
        }
        func outline(_ piece: ArtworkPieceCache.Piece, in c: inout GraphicsContext, shading: GraphicsContext.Shading) {
            if let fill = piece.fill { c.stroke(fill, with: shading, lineWidth: hairline) }
            if let stroke = piece.stroke { c.stroke(stroke, with: shading, style: StrokeStyle(lineWidth: hairline, lineCap: .round)) }
        }

        // The artwork, flattened into one layer so overlapping copper does
        // not stack up, and clear-polarity objects cut what is under them.
        var artCtx = ctx
        artCtx.opacity = playback.isEngaged ? 0.25 : 0.45
        var selectedPieces: [ArtworkPieceCache.Piece] = []
        artCtx.drawLayer { layer in
            switch artwork {
            case .gerber(let image):
                for object in image.objects {
                    let piece = cache.piece(object, in: image)
                    layer.blendMode = object.dark ? .normal : .destinationOut
                    draw(piece, in: &layer, shading: .color(color))
                    if selection.contains(object.id) { selectedPieces.append(piece) }
                }
            case .drill(let image):
                for hole in image.holes {
                    let piece = cache.piece(hole, in: image)
                    draw(piece, in: &layer, shading: .color(color))
                    if selection.contains(hole.id) { selectedPieces.append(piece) }
                }
            }
        }
        // Outlines keep small pads readable at any zoom.
        if case .drill(let image) = artwork {
            for hole in image.holes { outline(cache.piece(hole, in: image), in: &ctx, shading: .color(color.opacity(0.9))) }
        }

        // The selection, on top.
        let highlight = Color.accentColor
        for piece in selectedPieces {
            var c = ctx
            c.opacity = 0.55
            draw(piece, in: &c, shading: .color(highlight))
            outline(piece, in: &ctx, shading: .color(.white))
        }

        // Marquee, in view space.
        if let marquee = layerEditor.marquee {
            let corners = [CGPoint(x: marquee.minX, y: marquee.minY), CGPoint(x: marquee.maxX, y: marquee.maxY)]
                .map { $0.applying(t).applying(world) }
            let r = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                           width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y))
            var c = context
            c.clip(to: Path(map.plot))
            c.fill(Path(r), with: .color(Color.accentColor.opacity(0.08)))
            c.stroke(Path(r), with: .color(Color.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
