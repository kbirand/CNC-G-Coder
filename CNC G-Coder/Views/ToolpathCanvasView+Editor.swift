import SwiftUI
import AppKit

/// The shape editor's half of the toolpath canvas: drawing the shapes,
/// selection, handles, the shape in progress and snap feedback, and turning
/// pointer and key events into editor calls. The editor works in design
/// millimetres; `editorTransform` maps them into the canvas' world frame
/// (the selected program's coordinates, un-mirrored when asked).
extension ToolpathCanvasView {

    /// Cached outlines per shape value: text outlines cost a CoreText pass.
    final class OutlineCache {
        private var entries: [DrawnShape: [Polyline]] = [:]
        func outlines(_ shape: DrawnShape) -> [Polyline] {
            if let cached = entries[shape] { return cached }
            if entries.count > 400 { entries.removeAll() }
            let outlines = shape.outlines()
            entries[shape] = outlines
            return outlines
        }
    }

    /// The auto-fit frozen while editing: shapes grow and the program
    /// regenerates under the cursor, and the view must not jump with them.
    final class FitBox {
        var layerID: UUID?
        /// Kept in DESIGN coordinates: moving the origin (or a drawing-only
        /// project's extent growing) shifts the program frame, and the view
        /// must stay on the drawing rather than on the old program position.
        var rect: CGRect?
        /// A first document changes what there is to frame, so the fit is retaken.
        var hadDocument = false
    }

    /// A drag that started in the plot while editing; it becomes a real drag
    /// after a few points of movement, else a click on release.
    struct EditDrag {
        var start: CGPoint
        var started = false
    }

    /// The editor is live when a drawn layer is selected in the sidebar.
    var editorActive: Bool {
        sectionOverride.isEmpty && playback.selectedLayer?.isCustom == true && editor.activeLayer != nil
    }

    var editorLayerKind: LayerKind? {
        guard let layer = editor.activeLayer, let ref = model.customLayers.ref(id: layer.id) else { return nil }
        return .custom(ref)
    }

    /// Design (Gerber) coordinates → the canvas' world frame for the active
    /// drawn layer: the side's program frame, un-mirrored on request.
    func editorTransform() -> CGAffineTransform {
        guard let layer = editor.activeLayer else { return .identity }
        let frame: CustomLayerGenerator.ProgramFrame
        if preview.document == nil, !model.detectedFiles.hasAnyToolpathInput {
            // Drawing-only and nothing generated yet (the first shape is still
            // being drawn): use the very frame the generator will use, so a
            // point clicked at X0 Y0 is still at X0 Y0 once its program exists.
            frame = CustomLayerGenerator.ProgramFrame(
                frame: CustomLayerGenerator.frame(layers: model.customLayers, params: params.snapshot()),
                mirrorAxis: Double(params.mirrorAxis) ?? 0, mirrorYAxis: params.mirrorYAxis)
        } else {
            frame = CustomLayerGenerator.ProgramFrame(document: preview.document,
                                                      mirrorAxis: Double(params.mirrorAxis) ?? 0,
                                                      mirrorYAxis: params.mirrorYAxis)
        }
        var t = frame.designToProgram(back: layer.back)
        if layer.back, let kind = editorLayerKind, let flip = displayTransform(for: kind) {
            t = t.concatenating(flip)
        }
        return t
    }

    func designPoint(fromView p: CGPoint, map: Mapping) -> CGPoint {
        CGPoint(x: map.worldX(p.x), y: map.worldY(p.y)).applying(editorTransform().inverted())
    }

    func viewPoint(fromDesign p: CGPoint, map: Mapping) -> CGPoint {
        let w = p.applying(editorTransform())
        return CGPoint(x: map.viewX(w.x), y: map.viewY(w.y))
    }

    func snapContext(map: Mapping) -> ShapeEditor.SnapContext {
        let t = editorTransform()
        let inverse = t.inverted()
        // Guides are world positions; through a translation/mirror a vertical
        // guide stays vertical, so only the matching coordinate matters.
        let gx: [Double] = guidesX.map { Double(CGPoint(x: $0, y: 0).applying(inverse).x) }
        let gy: [Double] = guidesY.map { Double(CGPoint(x: 0, y: $0).applying(inverse).y) }
        var context = ShapeEditor.SnapContext(tolerance: 8 / map.scale, guidesX: gx, guidesY: gy)
        if snapToGrid {
            let step = tickStep(scale: map.scale).mm / 2
            context.gridSnap = { (p: CGPoint) -> CGPoint in
                let w = p.applying(t)
                return CGPoint(x: (w.x / step).rounded() * step, y: (w.y / step).rounded() * step).applying(inverse)
            }
        }
        return context
    }

    private var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    // MARK: - Framing

    /// The drawn layer's extent in the world frame (its program if generated,
    /// else the shapes themselves), for fitting.
    func editorFitBounds() -> CGRect? {
        guard let layer = editor.activeLayer else { return nil }
        if let kind = editorLayerKind, let parsed = preview.document?.layers.first(where: { $0.id == kind }),
           let b = parsed.cutBounds ?? parsed.allBounds {
            return displayTransform(for: kind).map { b.applying($0) } ?? b
        }
        return layer.bounds?.applying(editorTransform())
    }

    // MARK: - Pointer events

    func editorClick(at location: CGPoint) {
        guard let map = mapping(in: canvasSize), map.plot.contains(location) else { return }
        editor.click(at: designPoint(fromView: location, map: map), shift: shiftDown, context: snapContext(map: map))
        canvasFocused = true
    }

    func editorDoubleClick(at location: CGPoint) {
        guard let map = mapping(in: canvasSize), map.plot.contains(location) else { return }
        editor.doubleClick(at: designPoint(fromView: location, map: map), context: snapContext(map: map))
    }

    func editorHover(_ point: CGPoint?) {
        guard editorActive, let point, let map = mapping(in: canvasSize), map.plot.contains(point) else { return }
        editor.moveCursor(to: designPoint(fromView: point, map: map), shift: shiftDown, context: snapContext(map: map))
    }

    func editorDragChanged(_ value: DragGesture.Value) {
        guard var drag = editDrag, let map = mapping(in: canvasSize) else { return }
        let context = snapContext(map: map)
        if !drag.started {
            guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
            drag.started = true
            editDrag = drag
            editor.dragBegan(at: designPoint(fromView: drag.start, map: map), shift: shiftDown, context: context)
        }
        editor.dragChanged(to: designPoint(fromView: value.location, map: map), shift: shiftDown, context: context)
    }

    func editorDragEnded(_ value: DragGesture.Value) {
        defer { editDrag = nil }
        guard let drag = editDrag, let map = mapping(in: canvasSize) else { return }
        let context = snapContext(map: map)
        if drag.started {
            editor.dragEnded(at: designPoint(fromView: value.location, map: map), shift: shiftDown, context: context)
        } else {
            editor.click(at: designPoint(fromView: drag.start, map: map), shift: shiftDown, context: context)
        }
        canvasFocused = true
    }

    // MARK: - Keys

    /// Runs a key's action after the key event has been dispatched. SwiftUI
    /// delivers key presses inside a view update, and changing published
    /// model state there is "publishing changes from within view updates".
    func afterKeyEvent(_ action: @escaping @MainActor () -> Void) -> KeyPress.Result {
        DispatchQueue.main.async { action() }
        return .handled
    }

    func editorKey(_ press: KeyPress) -> KeyPress.Result {
        guard editorActive else { return .ignored }
        let editor = self.editor
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "a": return afterKeyEvent { editor.selectAll() }
            case "d": return afterKeyEvent { editor.duplicateSelection() }
            default: return .ignored
            }
        }
        let step = press.modifiers.contains(.shift) ? 1.0 : 0.1
        switch press.key {
        case .escape: return afterKeyEvent { editor.cancel() }
        case .return: return afterKeyEvent { editor.finishDraft() }
        case .delete, .deleteForward: return afterKeyEvent { editor.deleteSelection() }
        case .leftArrow: return afterKeyEvent { editor.nudge(dx: -step, dy: 0) }
        case .rightArrow: return afterKeyEvent { editor.nudge(dx: step, dy: 0) }
        case .upArrow: return afterKeyEvent { editor.nudge(dx: 0, dy: step) }
        case .downArrow: return afterKeyEvent { editor.nudge(dx: 0, dy: -step) }
        default: break
        }
        if press.modifiers.isEmpty || press.modifiers == .shift,
           let ch = press.characters.lowercased().first,
           let tool = ShapeEditor.Tool.allCases.first(where: { $0.key == ch }) {
            return afterKeyEvent { editor.tool = tool }
        }
        return .ignored
    }

    /// Cursor feedback while editing; nil = the usual arrow.
    func editorPointerStyle(at hover: CGPoint, map: Mapping) -> PointerStyle? {
        guard editorActive, map.plot.contains(hover) else { return nil }
        if NSEvent.modifierFlags.contains(.option) { return .grabIdle }
        switch editor.tool {
        case .select:
            if editor.isDragging { return .grabActive }
            switch editor.hover(at: designPoint(fromView: hover, map: map), tolerance: 8 / map.scale) {
            case .handle, .shape: return .grabIdle
            case .nothing: return nil
            }
        case .line, .rectangle, .circle, .text:
            return .rectSelection
        }
    }

    // MARK: - Drawing

    private static let handleSize: CGFloat = 7

    /// Draws the shapes, selection, handles, draft and snap hint. `world` is
    /// the canvas' world transform (mm → points).
    func drawEditor(_ context: GraphicsContext, map: Mapping, world: CGAffineTransform) {
        guard editorActive, let layer = editor.activeLayer, let kind = editorLayerKind else { return }
        let t = editorTransform()
        let toView = t.concatenating(world)
        let scale = map.scale
        let color = kind.color
        let dimOthers = playback.isEngaged

        var ctx = context
        ctx.clip(to: Path(map.plot))

        // Shapes (in view space, so hairlines stay crisp at any zoom).
        for shape in editor.displayedShapes {
            let selected = editor.selection.contains(shape.id)
            var path = Path()
            for outline in outlineCache.outlines(shape) {
                guard let first = outline.points.first else { continue }
                path.move(to: first.applying(toView))
                for p in outline.points.dropFirst() { path.addLine(to: p.applying(toView)) }
                if outline.closed { path.closeSubpath() }
                if outline.points.count == 1 {
                    let v = first.applying(toView)
                    path.addEllipse(in: CGRect(x: v.x - 2, y: v.y - 2, width: 4, height: 4))
                }
            }
            if shape.strokeWidth > 0 {
                ctx.stroke(path, with: .color(color.opacity(0.16 * (dimOthers ? 0.5 : 1))),
                           style: StrokeStyle(lineWidth: shape.strokeWidth * scale, lineCap: .round, lineJoin: .round))
            }
            if shape.filled, shape.geometry.isClosed {
                ctx.fill(path, with: .color(color.opacity(0.10)), style: FillStyle(eoFill: true))
            }
            ctx.stroke(path, with: .color(selected ? .white : color.opacity(dimOthers ? 0.6 : 0.95)),
                       style: StrokeStyle(lineWidth: selected ? 1.8 : 1.1, lineJoin: .round))
        }

        // Selection: handles for one shape, a dashed box for several.
        let selectedShapes = editor.selectedShapes
        if selectedShapes.count == 1, let shape = selectedShapes.first {
            let handles = editor.handles(for: shape)
            if handles.isEmpty, let b = shape.bounds {
                drawBox(&ctx, b.applying(t), map: map)
            }
            let s = Self.handleSize
            for (_, point) in handles {
                let v = point.applying(toView)
                let r = CGRect(x: v.x - s / 2, y: v.y - s / 2, width: s, height: s)
                ctx.fill(Path(r), with: .color(.white))
                ctx.stroke(Path(r), with: .color(color), lineWidth: 1)
            }
        } else if selectedShapes.count > 1 {
            var union = CGRect.null
            for shape in selectedShapes { if let b = shape.bounds { union = union.union(b) } }
            if !union.isNull { drawBox(&ctx, union.applying(t), map: map) }
        }

        // The shape being drawn.
        if let draft = editor.draft {
            drawDraft(&ctx, draft, layer: layer, toView: toView, color: color)
        }

        // Marquee.
        if let marquee = editor.marquee {
            let r = viewRect(marquee.applying(t), map: map)
            ctx.fill(Path(r), with: .color(Color.accentColor.opacity(0.08)))
            ctx.stroke(Path(r), with: .color(Color.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Snap feedback: a ring on the point and what it is.
        if let hint = editor.snapHint {
            let v = hint.point.applying(toView)
            ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)),
                       with: .color(.green), lineWidth: 1.5)
            ctx.draw(Text(hint.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.green),
                     at: CGPoint(x: v.x + 9, y: v.y - 9), anchor: .bottomLeading)
        }
    }

    private func viewRect(_ world: CGRect, map: Mapping) -> CGRect {
        let a = CGPoint(x: map.viewX(world.minX), y: map.viewY(world.minY))
        let b = CGPoint(x: map.viewX(world.maxX), y: map.viewY(world.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func drawBox(_ ctx: inout GraphicsContext, _ world: CGRect, map: Mapping) {
        let r = viewRect(world, map: map).insetBy(dx: -4, dy: -4)
        ctx.stroke(Path(r), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func drawDraft(_ ctx: inout GraphicsContext, _ draft: ShapeEditor.Draft, layer: CustomLayer,
                           toView: CGAffineTransform, color: Color) {
        var path = Path()
        let ghost = StrokeStyle(lineWidth: 1.2, dash: [5, 3])
        switch editor.tool {
        case .line:
            let pts = draft.points + (draft.cursor.map { [$0] } ?? [])
            guard let first = pts.first else { return }
            path.move(to: first.applying(toView))
            for p in pts.dropFirst() { path.addLine(to: p.applying(toView)) }
            if draft.closing, pts.count >= 3 { path.closeSubpath() }
            ctx.stroke(path, with: .color(color), style: ghost)
            for p in draft.points {
                let v = p.applying(toView)
                ctx.fill(Path(ellipseIn: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5)), with: .color(color))
            }
            if let c = draft.cursor {
                let v = c.applying(toView)
                ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)), with: .color(color), lineWidth: 1)
            }
        case .rectangle:
            guard let anchor = draft.points.first, let cursor = draft.cursor else { return }
            var w = cursor.x - anchor.x, h = cursor.y - anchor.y
            if shiftDown {
                let s = max(abs(w), abs(h))
                w = w < 0 ? -s : s
                h = h < 0 ? -s : s
            }
            let shape = DrawnShape(geometry: .rect(origin: CGPoint(x: min(anchor.x, anchor.x + w), y: min(anchor.y, anchor.y + h)),
                                                   size: CGSize(width: abs(w), height: abs(h)), cornerRadius: 0, rotation: 0))
            strokeOutlines(&ctx, shape.outlines(), toView: toView, color: color, style: ghost)
            drawSizeLabel(&ctx, "\(units.length(abs(w))) × \(units.length(abs(h))) \(units.lengthSymbol)", near: cursor.applying(toView))
        case .circle:
            guard let center = draft.points.first, let cursor = draft.cursor else { return }
            let r = ShapeMath.distance(center, cursor)
            strokeOutlines(&ctx, [ShapeMath.circle(center: center, radius: r)], toView: toView, color: color, style: ghost)
            var spoke = Path()
            spoke.move(to: center.applying(toView))
            spoke.addLine(to: cursor.applying(toView))
            ctx.stroke(spoke, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            drawSizeLabel(&ctx, "⌀ \(units.length(2 * r)) \(units.lengthSymbol)", near: cursor.applying(toView))
        case .text:
            guard let cursor = draft.cursor, !editor.textString.isEmpty else { return }
            let outlines = TextOutlines.outlines(editor.textString, style: editor.textStyle, height: editor.textHeight,
                                                 origin: cursor, rotation: 0)
            strokeOutlines(&ctx, outlines, toView: toView, color: color.opacity(0.7), style: ghost)
        case .select:
            break
        }
    }

    private func strokeOutlines(_ ctx: inout GraphicsContext, _ outlines: [Polyline], toView: CGAffineTransform,
                                color: Color, style: StrokeStyle) {
        var path = Path()
        for outline in outlines {
            guard let first = outline.points.first else { continue }
            path.move(to: first.applying(toView))
            for p in outline.points.dropFirst() { path.addLine(to: p.applying(toView)) }
            if outline.closed { path.closeSubpath() }
        }
        ctx.stroke(path, with: .color(color), style: style)
    }

    private func drawSizeLabel(_ ctx: inout GraphicsContext, _ text: String, near point: CGPoint) {
        let width = CGFloat(text.count) * 6 + 10
        let rect = CGRect(x: point.x + 12, y: point.y + 10, width: width, height: 15)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.black.opacity(0.65)))
        ctx.draw(Text(text).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.white),
                 at: CGPoint(x: rect.midX, y: rect.midY))
    }
}
