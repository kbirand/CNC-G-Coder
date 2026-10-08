import SwiftUI
import Combine
import AppKit

/// The shape editor's state and every edit it can make: the active tool,
/// the selection, the shape being drawn, snapping, handles, alignment, and
/// undo (through the window's UndoManager, so the Edit menu works).
///
/// All geometry here is in DESIGN coordinates (the Gerber frame). The canvas
/// converts screen points before calling in and converts the results back —
/// the editor never knows about zoom, mirroring or the chosen origin.
@MainActor
final class ShapeEditor: ObservableObject {

    enum Tool: String, CaseIterable, Identifiable {
        case select, line, rectangle, circle, hole, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: String(localized: "Select")
            case .line: String(localized: "Line")
            case .rectangle: String(localized: "Rectangle")
            case .circle: String(localized: "Circle")
            case .hole: String(localized: "Hole")
            case .text: String(localized: "Text")
            }
        }
        var icon: String {
            switch self {
            case .select: "cursorarrow"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .circle: "circle"
            case .hole: "circle.circle"
            case .text: "textformat"
            }
        }
        var key: Character {
            switch self {
            case .select: "v"
            case .line: "l"
            case .rectangle: "r"
            case .circle: "c"
            case .hole: "h"
            case .text: "t"
            }
        }
        var help: String {
            switch self {
            case .select: String(localized: "Select (V): click a shape, shift-click to add, drag a box to select several; drag shapes to move them and their handles to resize.")
            case .line: String(localized: "Line (L): click each point; double-click or Return finishes, clicking the first point closes it into a polygon. Shift constrains to 45° steps.")
            case .rectangle: String(localized: "Rectangle (R): click or drag from one corner to the opposite one. Shift makes a square.")
            case .circle: String(localized: "Circle (C): click or drag from the centre out to the radius.")
            case .hole: String(localized: "Hole (H): click to place a hole of the diameter set in the bar — a filled circle: drilled at its centre on a Drill layer, milled out to its size on a Milling layer cutting inside.")
            case .text: String(localized: "Text (T): set the text and its height in the bar, then click where the baseline starts.")
            }
        }
    }

    enum Handle: Hashable {
        case rectCorner(Int)     // 0 lower-left, 1 lower-right, 2 upper-right, 3 upper-left
        case rectEdge(Int)       // 0 bottom, 1 right, 2 top, 3 left
        case circleQuadrant(Int) // 0 right, 1 top, 2 left, 3 bottom
        case vertex(Int)
    }

    enum AlignEdge: String, CaseIterable, Identifiable {
        case left, centerX, right, top, centerY, bottom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .left: String(localized: "Align Left")
            case .centerX: String(localized: "Align Horizontal Centres")
            case .right: String(localized: "Align Right")
            case .top: String(localized: "Align Top")
            case .centerY: String(localized: "Align Vertical Centres")
            case .bottom: String(localized: "Align Bottom")
            }
        }
        var icon: String {
            switch self {
            case .left: "align.horizontal.left"
            case .centerX: "align.horizontal.center"
            case .right: "align.horizontal.right"
            case .top: "align.vertical.top"
            case .centerY: "align.vertical.center"
            case .bottom: "align.vertical.bottom"
            }
        }
    }

    enum DistributeAxis: String, CaseIterable, Identifiable {
        case horizontal, vertical
        var id: String { rawValue }
        var title: String {
            switch self {
            case .horizontal: String(localized: "Distribute Horizontally")
            case .vertical: String(localized: "Distribute Vertically")
            }
        }
        var icon: String {
            switch self {
            case .horizontal: "distribute.horizontal.center"
            case .vertical: "distribute.vertical.center"
            }
        }
    }

    /// A shape in progress: the fixed points so far and where the cursor is.
    struct Draft {
        var points: [CGPoint]
        var cursor: CGPoint?
        /// Line tool: the cursor is on the first point, so the next click closes.
        var closing = false
    }

    struct SnapHint: Equatable {
        var point: CGPoint
        var label: String
    }

    /// What the canvas knows that snapping needs: the grab distance in mm,
    /// the guides in design mm, and — when Snap to Grid is on — a function
    /// that rounds a design point onto the grid the view draws (the grid is
    /// laid out from the program origin, which the editor knows nothing about).
    struct SnapContext {
        var tolerance: Double
        var guidesX: [Double] = []
        var guidesY: [Double] = []
        var gridSnap: ((CGPoint) -> CGPoint)?
    }

    // MARK: - State

    @Published var tool: Tool = .select {
        didSet {
            guard tool != oldValue else { return }
            cancelDraft()
            drag = nil
            marquee = nil
            focusRequest += 1
        }
    }
    @Published var selection: Set<UUID> = []
    @Published private(set) var draft: Draft?
    /// The active layer's shapes while a move/resize drag is in progress —
    /// drawn instead of the stored ones, committed (with undo) on release.
    @Published private(set) var dragPreview: [DrawnShape]?
    @Published private(set) var marquee: CGRect?
    /// Assigned through setHint, so only real changes publish.
    @Published private(set) var snapHint: SnapHint?
    /// Bumped when the canvas should take keyboard focus.
    @Published var focusRequest = 0
    /// A short notice for the toolbar ("Select at least three shapes").
    @Published private(set) var message: String?

    @Published var snapToObjects: Bool {
        didSet { UserDefaults.standard.set(snapToObjects, forKey: "editor.snapObjects") }
    }
    @Published var textString: String {
        didSet { UserDefaults.standard.set(textString, forKey: "editor.textString") }
    }
    @Published var textHeight: Double {
        didSet { UserDefaults.standard.set(textHeight, forKey: "editor.textHeight") }
    }
    @Published var textStyle: TextStyle {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(textStyle), forKey: "editor.textStyle") }
    }
    /// Diameter of holes placed with the Hole tool, mm.
    @Published var holeDiameter: Double {
        didSet { UserDefaults.standard.set(holeDiameter, forKey: "editor.holeDiameter") }
    }
    /// Stroke width given to newly drawn shapes (0 = one tool pass).
    @Published var newStrokeWidth: Double {
        didSet { UserDefaults.standard.set(newStrokeWidth, forKey: "editor.strokeWidth") }
    }

    weak var app: AppModel?
    /// The app's one undo history (AppModel.history).
    var undoManager: UndoManager?

    private enum Drag {
        case move(origin: CGPoint, originals: [DrawnShape])
        case handle(id: UUID, handle: Handle, original: DrawnShape)
        case marquee(origin: CGPoint)
        case draw(anchor: CGPoint)
    }
    private var drag: Drag?
    private var messageTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        snapToObjects = defaults.object(forKey: "editor.snapObjects") as? Bool ?? true
        textString = defaults.string(forKey: "editor.textString") ?? "TEXT"
        let height = defaults.double(forKey: "editor.textHeight")
        textHeight = height > 0 ? height : 3
        textStyle = defaults.data(forKey: "editor.textStyle").flatMap { try? JSONDecoder().decode(TextStyle.self, from: $0) }
            ?? TextStyle()
        newStrokeWidth = max(0, defaults.double(forKey: "editor.strokeWidth"))
        let hole = defaults.double(forKey: "editor.holeDiameter")
        holeDiameter = hole > 0 ? hole : 1.0
    }

    // MARK: - Active layer

    var activeLayerID: UUID? { app?.player.selectedLayer?.customRef?.id }

    var activeLayer: CustomLayer? {
        guard let app, let id = activeLayerID else { return nil }
        return app.customLayers.first { $0.id == id }
    }

    /// The shapes as they should be drawn right now (a drag in progress included).
    var displayedShapes: [DrawnShape] { dragPreview ?? activeLayer?.shapes ?? [] }

    var selectedShapes: [DrawnShape] { displayedShapes.filter { selection.contains($0.id) } }

    /// Called when the selected layer changes: nothing carries over.
    func layerDidChange() {
        selection = []
        cancelDraft()
        drag = nil
        dragPreview = nil
        marquee = nil
    }

    // MARK: - Mutation with undo

    /// Replaces a layer wholesale, registering the inverse with the undo
    /// manager (which turns into redo when this runs during an undo).
    func setLayer(_ new: CustomLayer, actionName: String) {
        guard let app, let index = app.customLayers.firstIndex(where: { $0.id == new.id }) else { return }
        let old = app.customLayers[index]
        guard old != new else { return }
        app.customLayers[index] = new
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.setLayer(old, actionName: actionName)
        }
        undoManager?.setActionName(String(localized: String.LocalizationValue(actionName)))
    }

    func updateLayer(_ actionName: String, _ change: (inout CustomLayer) -> Void) {
        guard var layer = activeLayer else { return }
        change(&layer)
        setLayer(layer, actionName: actionName)
    }

    func setShapes(_ shapes: [DrawnShape], actionName: String) {
        updateLayer(actionName) { $0.shapes = shapes }
    }

    func updateShape(_ id: UUID, actionName: String, _ change: (inout DrawnShape) -> Void) {
        updateLayer(actionName) { layer in
            guard let i = layer.shapes.firstIndex(where: { $0.id == id }) else { return }
            change(&layer.shapes[i])
        }
    }

    func updateSelectedShapes(actionName: String, _ change: (inout DrawnShape) -> Void) {
        updateLayer(actionName) { layer in
            for i in layer.shapes.indices where selection.contains(layer.shapes[i].id) { change(&layer.shapes[i]) }
        }
    }

    func addShape(_ shape: DrawnShape, actionName: String) {
        guard let layer = activeLayer else { return }
        setShapes(layer.shapes + [shape], actionName: actionName)
        selection = [shape.id]
    }

    // MARK: - Selection edits

    func selectAll() {
        selection = Set(displayedShapes.map(\.id))
    }

    func deleteSelection() {
        guard let layer = activeLayer, !selection.isEmpty else { return }
        let remaining = layer.shapes.filter { !selection.contains($0.id) }
        setShapes(remaining, actionName: "Delete")
        selection = []
    }

    func duplicateSelection() {
        guard let layer = activeLayer, !selection.isEmpty else { return }
        var copies: [DrawnShape] = []
        for shape in layer.shapes where selection.contains(shape.id) {
            var copy = shape.moved(by: CGVector(dx: 2, dy: -2))
            copy.id = UUID()
            copies.append(copy)
        }
        setShapes(layer.shapes + copies, actionName: "Duplicate")
        selection = Set(copies.map(\.id))
    }

    // MARK: - Guides and mirroring

    /// Design → world (the rulers' frame), as the canvas last drew the
    /// layer. Guides are world positions; this maps them onto the shapes.
    var designToWorld: CGAffineTransform = .identity

    /// Adds a guide through the centre of the selection's bounds.
    func addGuideAtSelectionCentre(vertical: Bool) {
        let box = selectedShapes.compactMap(\.bounds).reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull else { notify("Select one or more shapes first"); return }
        notify("Guide at \(PreviewGuide.addThroughCentre(of: box, designToWorld: designToWorld, vertical: vertical).title)")
    }

    /// Reflects the selected shapes across a guide — as copies, or moving them.
    func mirrorSelection(across guide: PreviewGuide, copy: Bool) {
        guard let layer = activeLayer, !selection.isEmpty else { return }
        let r = guide.reflection(designToWorld: designToWorld)
        var shapes = layer.shapes
        var mirrored = Set<UUID>()
        for (i, shape) in layer.shapes.enumerated() where selection.contains(shape.id) {
            var m = shape.mirrored(by: r)
            if copy {
                m.id = UUID()
                shapes.append(m)
            } else {
                shapes[i] = m
            }
            mirrored.insert(m.id)
        }
        setShapes(shapes, actionName: copy ? "Mirror Copy" : "Mirror")
        selection = mirrored
    }

    func nudge(dx: Double, dy: Double) {
        guard !selection.isEmpty else { return }
        updateSelectedShapes(actionName: "Move") { $0 = $0.moved(by: CGVector(dx: dx, dy: dy)) }
    }

    func moveSelection(by delta: CGVector) {
        guard abs(delta.dx) > 1e-9 || abs(delta.dy) > 1e-9 else { return }
        updateSelectedShapes(actionName: "Move") { $0 = $0.moved(by: delta) }
    }

    func align(_ edge: AlignEdge) {
        let shapes = selectedShapes
        guard shapes.count >= 2 else { notify("Select at least two shapes to align"); return }
        var union = CGRect.null
        var bounds: [UUID: CGRect] = [:]
        for shape in shapes { if let b = shape.bounds { bounds[shape.id] = b; union = union.union(b) } }
        guard !union.isNull else { return }
        updateLayer(edge.title) { layer in
            for i in layer.shapes.indices {
                guard let b = bounds[layer.shapes[i].id] else { continue }
                let delta: CGVector = switch edge {
                case .left: CGVector(dx: union.minX - b.minX, dy: 0)
                case .centerX: CGVector(dx: union.midX - b.midX, dy: 0)
                case .right: CGVector(dx: union.maxX - b.maxX, dy: 0)
                case .top: CGVector(dx: 0, dy: union.maxY - b.maxY)
                case .centerY: CGVector(dx: 0, dy: union.midY - b.midY)
                case .bottom: CGVector(dx: 0, dy: union.minY - b.minY)
                }
                layer.shapes[i] = layer.shapes[i].moved(by: delta)
            }
        }
    }

    /// Equal gaps between neighbours, the outermost two staying put.
    func distribute(_ axis: DistributeAxis) {
        let shapes = selectedShapes.compactMap { shape in shape.bounds.map { (shape.id, $0) } }
        guard shapes.count >= 3 else { notify("Select at least three shapes to distribute"); return }
        let horizontal = axis == .horizontal
        let sorted = shapes.sorted { horizontal ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        let first = sorted.first!.1, last = sorted.last!.1
        let span = horizontal ? last.maxX - first.minX : last.maxY - first.minY
        let total = sorted.reduce(0.0) { $0 + (horizontal ? $1.1.width : $1.1.height) }
        let gap = (span - total) / Double(sorted.count - 1)
        var moves: [UUID: CGVector] = [:]
        var cursor = horizontal ? first.minX : first.minY
        for (id, b) in sorted {
            let current = horizontal ? b.minX : b.minY
            moves[id] = horizontal ? CGVector(dx: cursor - current, dy: 0) : CGVector(dx: 0, dy: cursor - current)
            cursor += (horizontal ? b.width : b.height) + gap
        }
        updateLayer(axis.title) { layer in
            for i in layer.shapes.indices {
                if let delta = moves[layer.shapes[i].id] { layer.shapes[i] = layer.shapes[i].moved(by: delta) }
            }
        }
    }

    func notify(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: - Hit testing

    /// The topmost shape under a point (outline within `tolerance`, else the
    /// smallest closed shape containing it).
    func hitTest(_ p: CGPoint, tolerance: Double) -> UUID? {
        var nearest: (Double, UUID)?
        var container: (Double, UUID)?
        for shape in displayedShapes.reversed() {
            let hit = shape.hit(p)
            if hit.distance <= tolerance, hit.distance < (nearest?.0 ?? .infinity) { nearest = (hit.distance, shape.id) }
            if hit.inside, let b = shape.bounds {
                let area = b.width * b.height
                if area < (container?.0 ?? .infinity) { container = (area, shape.id) }
            }
        }
        return nearest?.1 ?? container?.1
    }

    func handles(for shape: DrawnShape) -> [(handle: Handle, point: CGPoint)] {
        switch shape.geometry {
        case .rect(let o, let size, _, let rotation):
            guard rotation == 0 else { return [] }
            let w = size.width, h = size.height
            return [
                (.rectCorner(0), o), (.rectCorner(1), CGPoint(x: o.x + w, y: o.y)),
                (.rectCorner(2), CGPoint(x: o.x + w, y: o.y + h)), (.rectCorner(3), CGPoint(x: o.x, y: o.y + h)),
                (.rectEdge(0), CGPoint(x: o.x + w / 2, y: o.y)), (.rectEdge(1), CGPoint(x: o.x + w, y: o.y + h / 2)),
                (.rectEdge(2), CGPoint(x: o.x + w / 2, y: o.y + h)), (.rectEdge(3), CGPoint(x: o.x, y: o.y + h / 2))
            ]
        case .circle(let c, let d):
            let r = d / 2
            return [(.circleQuadrant(0), CGPoint(x: c.x + r, y: c.y)), (.circleQuadrant(1), CGPoint(x: c.x, y: c.y + r)),
                    (.circleQuadrant(2), CGPoint(x: c.x - r, y: c.y)), (.circleQuadrant(3), CGPoint(x: c.x, y: c.y - r))]
        case .line(let points, _):
            return points.enumerated().map { (.vertex($0), $1) }
        case .text:
            return []
        }
    }

    /// A handle of a selected shape under the point.
    func handle(at p: CGPoint, tolerance: Double) -> (id: UUID, handle: Handle)? {
        // Only a single selected shape shows handles (see the canvas).
        guard selection.count == 1, let shape = selectedShapes.first else { return nil }
        var best: (Double, Handle)?
        for (handle, point) in handles(for: shape) {
            let d = ShapeMath.distance(p, point)
            if d <= tolerance, d < (best?.0 ?? .infinity) { best = (d, handle) }
        }
        return best.map { (shape.id, $0.1) }
    }

    // MARK: - Snapping

    /// Snaps a point: to another shape's vertex/centre first, then to guides,
    /// then to the grid. Returns the point and what it snapped to.
    func snapped(_ p: CGPoint, context: SnapContext, excluding: Set<UUID> = [],
                 extra: [(CGPoint, String)] = []) -> (point: CGPoint, label: String?) {
        var best: (distance: Double, point: CGPoint, label: String)?
        for (q, label) in extra {
            let d = ShapeMath.distance(p, q)
            if d <= context.tolerance, d < (best?.distance ?? .infinity) { best = (d, q, label) }
        }
        if snapToObjects {
            for shape in displayedShapes where !excluding.contains(shape.id) {
                for q in shape.snapPoints() {
                    let d = ShapeMath.distance(p, q)
                    if d <= context.tolerance, d < (best?.distance ?? .infinity) { best = (d, q, "point") }
                }
            }
        }
        if let best { return (best.point, best.label) }

        var out = p
        var snappedX = false, snappedY = false
        if let gx = context.guidesX.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(gx - p.x) <= context.tolerance {
            out.x = gx; snappedX = true
        }
        if let gy = context.guidesY.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(gy - p.y) <= context.tolerance {
            out.y = gy; snappedY = true
        }
        if let gridSnap = context.gridSnap {
            let g = gridSnap(p)
            if !snappedX { out.x = g.x }
            if !snappedY { out.y = g.y }
            return (out, snappedX || snappedY ? "guide" : "grid")
        }
        return (out, snappedX || snappedY ? "guide" : nil)
    }

    /// Shift: constrain a segment from `anchor` to a multiple of 45°.
    private func constrained(_ p: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let length = hypot(dx, dy)
        guard length > 1e-9 else { return p }
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle))
    }

    /// The cursor as the current tool sees it: snapped, and constrained with Shift.
    private func cursorPoint(_ p: CGPoint, shift: Bool, context: SnapContext) -> CGPoint {
        var extra: [(CGPoint, String)] = []
        var anchor: CGPoint?
        if let draft, let first = draft.points.first {
            anchor = draft.points.last
            if tool == .line, draft.points.count >= 3 { extra.append((first, "close")) }
        }
        if shift, let anchor {
            let c = constrained(p, from: anchor)
            setHint(nil)
            return c
        }
        let result = snapped(p, context: context, extra: extra)
        setHint(result.label.map { SnapHint(point: result.point, label: $0) })
        return result.point
    }

    // MARK: - Pointer input (design coordinates)

    /// The mouse moved without a button down: rubber-band the draft.
    func moveCursor(to p: CGPoint, shift: Bool, context: SnapContext) {
        guard drag == nil else { return }
        switch tool {
        case .select:
            setHint(nil)
        case .line, .rectangle, .circle, .hole, .text:
            let point = cursorPoint(p, shift: shift, context: context)
            if draft != nil {
                draft?.cursor = point
                draft?.closing = snapHint?.label == "close"
            } else if tool == .text || tool == .line || tool == .hole {
                draft = Draft(points: [], cursor: point)   // shows the text/point ghost before the first click
            }
        }
    }

    func click(at p: CGPoint, shift: Bool, context: SnapContext) {
        focusRequest += 1
        switch tool {
        case .select:
            let tolerance = context.tolerance
            if let id = hitTest(p, tolerance: tolerance) {
                if shift {
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                } else {
                    selection = [id]
                }
            } else if !shift {
                selection = []
            }
        case .line:
            let point = cursorPoint(p, shift: shift, context: context)
            if draft?.closing == true, let points = draft?.points, points.count >= 3 {
                finishLine(points, closed: true)
                return
            }
            if draft == nil { draft = Draft(points: [], cursor: point) }
            if draft!.points.last.map({ ShapeMath.distance($0, point) > 1e-6 }) ?? true {
                draft!.points.append(point)
            }
        case .rectangle, .circle:
            let point = cursorPoint(p, shift: shift, context: context)
            if let anchor = draft?.points.first {
                commitTwoPoint(anchor: anchor, end: point, shift: shift)
            } else {
                draft = Draft(points: [point], cursor: point)
            }
        case .hole:
            let point = cursorPoint(p, shift: shift, context: context)
            guard holeDiameter > 0 else { notify("Set the hole diameter in the bar first"); return }
            addShape(DrawnShape(geometry: .circle(center: point, diameter: holeDiameter), filled: true),
                     actionName: "Add Hole")
            draft = Draft(points: [], cursor: point)
        case .text:
            let point = cursorPoint(p, shift: shift, context: context)
            guard !textString.isEmpty else { notify("Type the text in the bar first"); return }
            addShape(DrawnShape(geometry: .text(origin: point, string: textString, height: textHeight,
                                                rotation: 0, style: textStyle), strokeWidth: newStrokeWidth),
                     actionName: "Add Text")
            draft = Draft(points: [], cursor: point)
        }
    }

    func doubleClick(at p: CGPoint, context: SnapContext) {
        if tool == .line { finishDraft() }
    }

    /// Return: finish the shape in progress.
    func finishDraft() {
        guard let draft else { return }
        switch tool {
        case .line:
            if draft.points.count >= 2 { finishLine(draft.points, closed: false) } else { cancelDraft() }
        case .rectangle, .circle:
            if let anchor = draft.points.first, let end = draft.cursor { commitTwoPoint(anchor: anchor, end: end, shift: false) }
        case .select, .hole, .text:
            break
        }
    }

    /// Escape: drop the shape in progress, else the selection, else the tool.
    func cancel() {
        if draft != nil, !(draft?.points.isEmpty ?? true) {
            cancelDraft()
        } else if !selection.isEmpty {
            selection = []
        } else {
            tool = .select
        }
    }

    private func cancelDraft() {
        if draft != nil { draft = nil }
        setHint(nil)
    }

    /// Assigns the snap hint only when it changes, so plain mouse movement
    /// does not republish the editor (and re-render the sidebar) every frame.
    private func setHint(_ hint: SnapHint?) {
        if hint != snapHint { snapHint = hint }
    }

    private func finishLine(_ points: [CGPoint], closed: Bool) {
        var pts = points
        if closed, pts.count > 3, let f = pts.first, let l = pts.last, ShapeMath.distance(f, l) < 1e-6 { pts.removeLast() }
        cancelDraft()
        guard pts.count >= 2 else { return }
        addShape(DrawnShape(geometry: .line(points: pts, closed: closed && pts.count >= 3), strokeWidth: newStrokeWidth),
                 actionName: closed ? "Add Polygon" : "Add Line")
    }

    private func commitTwoPoint(anchor: CGPoint, end: CGPoint, shift: Bool) {
        cancelDraft()
        switch tool {
        case .rectangle:
            var w = end.x - anchor.x, h = end.y - anchor.y
            if shift {
                let s = max(abs(w), abs(h))
                w = w < 0 ? -s : s
                h = h < 0 ? -s : s
            }
            guard abs(w) > 1e-6, abs(h) > 1e-6 else { return }
            let origin = CGPoint(x: min(anchor.x, anchor.x + w), y: min(anchor.y, anchor.y + h))
            addShape(DrawnShape(geometry: .rect(origin: origin, size: CGSize(width: abs(w), height: abs(h)),
                                                cornerRadius: 0, rotation: 0), strokeWidth: newStrokeWidth),
                     actionName: "Add Rectangle")
        case .circle:
            let r = ShapeMath.distance(anchor, end)
            guard r > 1e-6 else { return }
            addShape(DrawnShape(geometry: .circle(center: anchor, diameter: 2 * r), strokeWidth: newStrokeWidth),
                     actionName: "Add Circle")
        default:
            break
        }
    }

    // MARK: - Drags

    /// What a drag starting here will do — decided by the canvas' threshold.
    func dragBegan(at p: CGPoint, shift: Bool, context: SnapContext) {
        focusRequest += 1
        switch tool {
        case .select:
            if let hit = handle(at: p, tolerance: context.tolerance), let shape = selectedShapes.first {
                drag = .handle(id: hit.id, handle: hit.handle, original: shape)
            } else if let id = hitTest(p, tolerance: context.tolerance) {
                if !selection.contains(id) { selection = shift ? selection.union([id]) : [id] }
                drag = .move(origin: p, originals: activeLayer?.shapes ?? [])
            } else {
                drag = .marquee(origin: p)
                marquee = CGRect(origin: p, size: .zero)
            }
        case .rectangle, .circle:
            let point = cursorPoint(p, shift: shift, context: context)
            draft = Draft(points: [point], cursor: point)
            drag = .draw(anchor: point)
        case .line:
            // A drag in the line tool is "click here, then click there".
            let point = cursorPoint(p, shift: shift, context: context)
            if draft == nil { draft = Draft(points: [], cursor: point) }
            if draft!.points.last.map({ ShapeMath.distance($0, point) > 1e-6 }) ?? true { draft!.points.append(point) }
            drag = .draw(anchor: point)
        case .hole, .text:
            drag = nil
        }
    }

    func dragChanged(to p: CGPoint, shift: Bool, context: SnapContext) {
        guard let drag else { return }
        switch drag {
        case .move(let origin, let originals):
            let delta = moveDelta(from: origin, to: p, originals: originals, context: context)
            dragPreview = originals.map { selection.contains($0.id) ? $0.moved(by: delta) : $0 }
        case .handle(let id, let handle, let original):
            let target = snapped(p, context: context, excluding: [id]).point
            setHint(nil)
            let edited = applyHandle(handle, to: original, point: target, shift: shift)
            dragPreview = (activeLayer?.shapes ?? []).map { $0.id == id ? edited : $0 }
        case .marquee(let origin):
            marquee = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                             width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        case .draw:
            let point = cursorPoint(p, shift: shift, context: context)
            draft?.cursor = point
            draft?.closing = snapHint?.label == "close"
        }
    }

    func dragEnded(at p: CGPoint, shift: Bool, context: SnapContext) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .move(let origin, let originals):
            let delta = moveDelta(from: origin, to: p, originals: originals, context: context)
            dragPreview = nil
            setHint(nil)
            moveSelection(by: delta)
        case .handle(let id, let handle, let original):
            let target = snapped(p, context: context, excluding: [id]).point
            dragPreview = nil
            setHint(nil)
            let edited = applyHandle(handle, to: original, point: target, shift: shift)
            updateShape(id, actionName: "Resize") { $0 = edited }
        case .marquee(let origin):
            defer { marquee = nil }
            let rect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                              width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            // Dragging right selects what the box encloses, dragging left
            // whatever it touches (the CAD convention).
            let enclose = p.x >= origin.x
            var hits = Set<UUID>()
            for shape in displayedShapes {
                guard let b = shape.bounds else { continue }
                if enclose ? rect.contains(b) : rect.intersects(b) { hits.insert(shape.id) }
            }
            selection = shift ? selection.union(hits) : hits
        case .draw(let anchor):
            let point = cursorPoint(p, shift: shift, context: context)
            switch tool {
            case .rectangle, .circle:
                commitTwoPoint(anchor: anchor, end: point, shift: shift)
            case .line:
                if draft?.closing == true, let points = draft?.points, points.count >= 3 {
                    finishLine(points, closed: true)
                } else if draft != nil, draft!.points.last.map({ ShapeMath.distance($0, point) > 1e-6 }) ?? true {
                    draft!.points.append(point)
                }
            default:
                break
            }
        }
    }

    /// Where a move drag lands: the raw offset, pulled so that any moving
    /// snap point meets a resting one (or the grid) within tolerance.
    private func moveDelta(from origin: CGPoint, to p: CGPoint, originals: [DrawnShape], context: SnapContext) -> CGVector {
        var delta = CGVector(dx: p.x - origin.x, dy: p.y - origin.y)
        let moving = originals.filter { selection.contains($0.id) }
        var best: (distance: Double, correction: CGVector, point: CGPoint, label: String)?
        if snapToObjects {
            let resting = originals.filter { !selection.contains($0.id) }.flatMap { $0.snapPoints() }
            for shape in moving {
                for q in shape.snapPoints() {
                    let moved = CGPoint(x: q.x + delta.dx, y: q.y + delta.dy)
                    for r in resting {
                        let d = ShapeMath.distance(moved, r)
                        if d <= context.tolerance, d < (best?.distance ?? .infinity) {
                            best = (d, CGVector(dx: r.x - moved.x, dy: r.y - moved.y), r, "point")
                        }
                    }
                }
            }
        }
        if let best {
            setHint(SnapHint(point: best.point, label: best.label))
            return CGVector(dx: delta.dx + best.correction.dx, dy: delta.dy + best.correction.dy)
        }
        // Guides and grid act on the dragged shapes' anchor.
        if let anchor = moving.first?.anchor {
            let moved = CGPoint(x: anchor.x + delta.dx, y: anchor.y + delta.dy)
            let s = snapped(moved, context: context, excluding: selection)
            setHint(s.label.map { SnapHint(point: s.point, label: $0) })
            delta = CGVector(dx: delta.dx + s.point.x - moved.x, dy: delta.dy + s.point.y - moved.y)
        }
        return delta
    }

    private func applyHandle(_ handle: Handle, to shape: DrawnShape, point p: CGPoint, shift: Bool) -> DrawnShape {
        var out = shape
        switch (handle, shape.geometry) {
        case (.rectCorner(let k), .rect(let o, let size, let radius, let rotation)):
            // The opposite corner stays put.
            let opposite: CGPoint = switch k {
            case 0: CGPoint(x: o.x + size.width, y: o.y + size.height)
            case 1: CGPoint(x: o.x, y: o.y + size.height)
            case 2: o
            default: CGPoint(x: o.x + size.width, y: o.y)
            }
            var w = p.x - opposite.x, h = p.y - opposite.y
            if shift {
                let s = max(abs(w), abs(h))
                w = w < 0 ? -s : s
                h = h < 0 ? -s : s
            }
            let origin = CGPoint(x: min(opposite.x, opposite.x + w), y: min(opposite.y, opposite.y + h))
            out.geometry = .rect(origin: origin, size: CGSize(width: max(abs(w), 0.01), height: max(abs(h), 0.01)),
                                 cornerRadius: radius, rotation: rotation)
        case (.rectEdge(let k), .rect(let o, let size, let radius, let rotation)):
            var minX = o.x, maxX = o.x + size.width, minY = o.y, maxY = o.y + size.height
            switch k {
            case 0: minY = p.y
            case 1: maxX = p.x
            case 2: maxY = p.y
            default: minX = p.x
            }
            out.geometry = .rect(origin: CGPoint(x: min(minX, maxX), y: min(minY, maxY)),
                                 size: CGSize(width: max(abs(maxX - minX), 0.01), height: max(abs(maxY - minY), 0.01)),
                                 cornerRadius: radius, rotation: rotation)
        case (.circleQuadrant, .circle(let c, _)):
            out.geometry = .circle(center: c, diameter: max(2 * ShapeMath.distance(c, p), 0.01))
        case (.vertex(let i), .line(var points, let closed)):
            if points.indices.contains(i) {
                points[i] = shift && i > 0 ? constrained(p, from: points[i - 1]) : p
            }
            out.geometry = .line(points: points, closed: closed)
        default:
            break
        }
        return out
    }

    /// For the canvas' cursor: what the pointer is over in the select tool.
    enum Hover { case nothing, shape, handle }
    func hover(at p: CGPoint, tolerance: Double) -> Hover {
        if handle(at: p, tolerance: tolerance) != nil { return .handle }
        return hitTest(p, tolerance: tolerance) != nil ? .shape : .nothing
    }

    var isDragging: Bool { drag != nil }
}
