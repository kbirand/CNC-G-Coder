import SwiftUI
import Combine
import AppKit

/// An imported layer file that can be edited: a single-file role, or one
/// of the drill files (by its position in the list).
nonisolated enum LayerEditTarget: Hashable, Sendable {
    case layer(LayerSlot)
    case drill(Int)

    var isDrill: Bool {
        if case .drill = self { return true }
        return false
    }

    /// Machined after the flip, like the programs made from it.
    var isBackSide: Bool {
        if case .layer(let slot) = self { return slot == .back || slot == .bottomMask || slot == .bottomSilk }
        return false
    }

    /// The program that shows this file mirrored with the back side, for
    /// the preview's un-mirror option.
    var backProgram: LayerKind? {
        guard case .layer(let slot) = self else { return nil }
        switch slot {
        case .back: return .back
        case .bottomMask: return .maskBottom
        case .bottomSilk: return .silkBottom
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .layer(let slot): slot.title
        case .drill: "Drill file"
        }
    }
}

extension LayerKind {
    /// The imported file this program is made from, when it is one that
    /// can be edited.
    nonisolated var editTarget: LayerEditTarget? {
        switch self {
        case .front: .layer(.front)
        case .back: .layer(.back)
        case .outline: .layer(.outline)
        case .maskTop: .layer(.topMask)
        case .maskBottom: .layer(.bottomMask)
        case .silkTop: .layer(.topSilk)
        case .silkBottom: .layer(.bottomSilk)
        case .drill(let index, _), .millDrill(let index, _): .drill(index)
        case .custom, .test: nil
        }
    }
}

extension DetectedFiles {
    subscript(target: LayerEditTarget) -> URL? {
        get {
            switch target {
            case .layer(let slot): self[slot]
            case .drill(let index): drills.indices.contains(index) ? drills[index] : nil
            }
        }
        set {
            switch target {
            case .layer(let slot): self[slot] = newValue
            case .drill(let index):
                guard let newValue, drills.indices.contains(index) else { return }
                drills[index] = newValue
            }
        }
    }
}

/// Edits an imported Gerber or drill file: select pads, tracks and holes in
/// the preview, move or delete them, change track widths, pad and hole sizes.
///
/// Every edit writes a new copy of the file (under the working folder, same
/// name) and points the layer at it, as one step on the app's undo history —
/// Undo simply points back at the previous copy, and saving packs the edited
/// file into the project. pcb2gcode does not run while editing; the preview
/// regenerates from the edited file once editing ends.
/// The original file is never touched.
///
/// Geometry is in DESIGN coordinates (the Gerber frame), like ShapeEditor.
@MainActor
final class LayerFileEditor: ObservableObject {

    /// The file being edited; nil = not editing.
    @Published private(set) var target: LayerEditTarget?
    @Published var selection: Set<UUID> = []
    /// The artwork while a move drag is in progress (committed on release).
    @Published private(set) var dragPreview: LayerArtwork?
    @Published private(set) var marquee: CGRect?
    /// A short notice for the toolbar.
    @Published private(set) var message: String?
    /// Bumped when the canvas should take keyboard focus.
    @Published var focusRequest = 0
    /// Drill files: a click on empty space places a new hole.
    @Published var addingHoles = false

    /// Design → world (the rulers' frame), as the canvas last drew the
    /// file. Guides are world positions; this maps them onto the artwork.
    var designToWorld: CGAffineTransform = .identity
    /// Hole size for the next added hole when nothing is selected.
    private var lastHoleDiameter: Double?

    weak var app: AppModel?

    /// Parsed (or edited) contents per file revision. Edits add entries;
    /// undo points the layer back at an earlier file, found here again.
    private var artworks: [URL: LayerArtwork] = [:]
    private var failed: Set<URL> = []

    private enum Drag {
        case move(origin: CGPoint, base: LayerArtwork)
        case marquee(origin: CGPoint)
    }
    private var drag: Drag?
    private var messageTask: Task<Void, Never>?

    /// Where edited copies are written; the working root is cleared at launch.
    static var editsRoot: URL {
        ProjectDocument.workingRoot.appendingPathComponent("Edits", isDirectory: true)
    }

    static func isEditedCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(editsRoot.standardizedFileURL.path)
    }

    // MARK: - State

    var fileURL: URL? {
        guard let app, let target else { return nil }
        return app.detectedFiles[target]
    }

    /// The file's current contents (parsed on first use).
    var artwork: LayerArtwork? {
        guard let url = fileURL, let target else { return nil }
        if let cached = artworks[url] { return cached }
        guard !failed.contains(url), let loaded = try? Self.load(url, drill: target.isDrill) else {
            failed.insert(url)
            return nil
        }
        artworks[url] = loaded
        return loaded
    }

    /// As it should be drawn right now (a drag in progress included).
    var displayed: LayerArtwork? { dragPreview ?? artwork }

    var isActive: Bool { target != nil && artwork != nil }

    static func load(_ url: URL, drill: Bool) throws -> LayerArtwork {
        drill ? .drill(try ExcellonFile.read(url)) : .gerber(try GerberFile.read(url))
    }

    // MARK: - Start / stop

    /// Starts editing a layer file and shows its program in the preview.
    func begin(_ target: LayerEditTarget) {
        guard let app, let url = app.detectedFiles[target] else { return }
        if artworks[url] == nil {
            do {
                artworks[url] = try Self.load(url, drill: target.isDrill)
                failed.remove(url)
            } catch {
                app.appendLog("\nCannot edit \(url.lastPathComponent): \(error.localizedDescription)\n")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(url.lastPathComponent) cannot be edited"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
        // The program made from this file, so its toolpaths show under the
        // artwork and follow each edit.
        if let kind = app.preview.document?.layers.first(where: { $0.id.editTarget == target })?.id {
            app.player.selectedLayer = kind
        }
        UserDefaults.standard.set("", forKey: "ui.sectionOverride")
        UserDefaults.standard.set(false, forKey: "preview3D")   // editing happens in the 2D view
        self.target = target
        // No regeneration until editing ends; drop one already queued.
        if app.preview.phase == .debouncing { Task { await app.preview.cancelActiveRun() } }
        resetInteraction()
        focusRequest += 1
        app.appendLog("\nEditing \(url.lastPathComponent) — click pads, tracks or holes in the preview to change them.\n")
    }

    /// Stops editing and regenerates the preview from the edited file(s).
    func end() {
        guard target != nil else { return }
        target = nil
        resetInteraction()
        app?.preview.parametersDidChange()
    }

    private func resetInteraction() {
        addingHoles = false
        selection = []
        drag = nil
        dragPreview = nil
        marquee = nil
    }

    /// Picking a program made from another file (or a drawn layer) ends the edit.
    func selectedLayerChanged(to kind: LayerKind?) {
        guard let target, let kind else { return }
        if kind.editTarget != target { end() }
    }

    // MARK: - Committing

    /// Writes the edited artwork as a new copy of the file and points the
    /// layer at it, as one undoable step.
    func commit(_ new: LayerArtwork, actionName: String) {
        guard let app, let target, let url = fileURL, new != artwork else { return }
        let text: String = switch new {
        case .gerber(let image): GerberFile.write(image)
        case .drill(let image): ExcellonFile.write(image)
        }
        let dir = Self.editsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let edited = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: edited, atomically: true, encoding: .utf8)
        } catch {
            notify("Could not write the edited file: \(error.localizedDescription)")
            return
        }
        artworks[edited] = new
        // Where it originally came from, for the project file and Show in Finder.
        app.layerOrigins[edited] = app.layerOrigins[url] ?? url
        var files = app.detectedFiles
        files[target] = edited
        app.setDetectedFiles(files, actionName: actionName)
        if app.projectURL == nil { app.manualLayerEdits = true }
        // The preview regenerates when editing ends, not after every edit.
    }

    private func updateGerber(_ actionName: String, _ change: (inout GerberImage) -> Void) {
        guard case .gerber(var image) = artwork else { return }
        change(&image)
        commit(.gerber(image), actionName: actionName)
    }

    private func updateDrill(_ actionName: String, _ change: (inout ExcellonImage) -> Void) {
        guard case .drill(var image) = artwork else { return }
        change(&image)
        commit(.drill(image), actionName: actionName)
    }

    // MARK: - Selection

    func selectAll() {
        selection = Set(artwork?.objectIDs ?? [])
    }

    /// Adds everything the same size as the selection: all tracks of that
    /// width, all pads of that aperture, all holes of that drill.
    func selectSimilar() {
        guard let artwork, !selection.isEmpty else { notify("Select a pad, track or hole first"); return }
        selection = artwork.similar(to: selection)
    }

    // MARK: - Edits

    func deleteSelection() {
        guard let artwork, !selection.isEmpty else { return }
        commit(artwork.removing(selection), actionName: "Delete")
        selection = []
    }

    func moveSelection(by delta: CGVector) {
        guard let artwork, !selection.isEmpty, abs(delta.dx) > 1e-9 || abs(delta.dy) > 1e-9 else { return }
        commit(artwork.moving(selection, by: delta), actionName: "Move")
    }

    func nudge(dx: Double, dy: Double) {
        moveSelection(by: CGVector(dx: dx, dy: dy))
    }

    // The inspector passes the objects it shows: its fields commit when they
    // lose focus, which can come after a click has changed the selection.

    /// Moves one object so its anchor lands on a position.
    func setPosition(of id: UUID, x: Double? = nil, y: Double? = nil) {
        guard let artwork, let anchor = artwork.anchor(of: id) else { return }
        let delta = CGVector(dx: (x ?? anchor.x) - anchor.x, dy: (y ?? anchor.y) - anchor.y)
        guard abs(delta.dx) > 1e-9 || abs(delta.dy) > 1e-9 else { return }
        commit(artwork.moving([id], by: delta), actionName: "Move")
    }

    /// Tracks drawn with a round aperture of this width (mm).
    func setTrackWidth(_ width: Double, of ids: Set<UUID>) {
        guard width > 0 else { return }
        updateGerber("Change Track Width") { image in
            let code = image.aperture(matching: GerberAperture(code: 0, template: "C", params: [width / image.unit]))
            for i in image.objects.indices where ids.contains(image.objects[i].id) {
                if case .track(_, let path) = image.objects[i].kind {
                    image.objects[i].kind = .track(aperture: code, path: path)
                }
            }
        }
    }

    /// Resizes pads (mm). Each keeps its shape; pads sharing an aperture
    /// with others that are not being resized get an aperture of their own.
    func setPadSize(width: Double? = nil, height: Double? = nil, of ids: Set<UUID>) {
        updateGerber("Change Pad Size") { image in
            for i in image.objects.indices where ids.contains(image.objects[i].id) {
                guard case .flash(let code, let at) = image.objects[i].kind,
                      let aperture = image.apertures[code], let size = aperture.size else { continue }
                let w = width.map { $0 / image.unit } ?? size.width
                let h = height.map { $0 / image.unit } ?? size.height
                guard w > 0, h > 0 else { continue }
                let resized = image.aperture(matching: aperture.resized(width: w, height: h))
                image.objects[i].kind = .flash(aperture: resized, at: at)
            }
        }
    }

    /// Changes one aperture everywhere it is used (mm).
    func setAperture(_ code: Int, width: Double, height: Double) {
        guard width > 0, height > 0 else { return }
        updateGerber("Change Aperture") { image in
            guard let aperture = image.apertures[code] else { return }
            image.apertures[code] = aperture.resized(width: width / image.unit, height: height / image.unit)
        }
    }

    /// Holes drilled at this diameter (mm).
    func setHoleDiameter(_ diameter: Double, of ids: Set<UUID>) {
        guard diameter > 0 else { return }
        updateDrill("Change Hole Size") { image in
            let tool = image.tool(forDiameter: diameter)
            for i in image.holes.indices where ids.contains(image.holes[i].id) {
                image.holes[i].tool = tool
            }
        }
    }

    /// Changes one drill tool — every hole it drills (mm).
    func setToolDiameter(_ tool: Int, _ diameter: Double) {
        guard diameter > 0 else { return }
        updateDrill("Change Hole Size") { $0.tools[tool] = diameter }
    }

    func selectAperture(_ code: Int) {
        guard case .gerber(let image) = artwork else { return }
        selection = Set(image.objects.filter { $0.aperture == code }.map(\.id))
    }

    func selectTool(_ tool: Int) {
        guard case .drill(let image) = artwork else { return }
        selection = Set(image.holes.filter { $0.tool == tool }.map(\.id))
    }

    // MARK: - Guides

    /// Adds a guide through the centre of the selection's bounds — between
    /// two selected lines, or across the middle of a selected outline.
    func addGuideAtSelectionCentre(vertical: Bool) {
        guard let b = artwork?.bounds(of: selection) else { notify("Select one or more objects first"); return }
        notify("Guide at \(PreviewGuide.addThroughCentre(of: b, designToWorld: designToWorld, vertical: vertical).title)")
    }

    /// Reflects the selected holes across a guide — as copies, or moving them.
    func mirrorSelection(across guide: PreviewGuide, copy: Bool) {
        guard let artwork, !selection.isEmpty else { return }
        let result = artwork.mirroring(selection, by: guide.reflection(designToWorld: designToWorld), copy: copy)
        guard !result.ids.isEmpty else { notify("Those holes are already mirrored"); return }
        commit(result.artwork, actionName: copy ? "Mirror Copy" : "Mirror")
        selection = result.ids
        if result.unflipped > 0 {
            notify("\(result.unflipped) custom-shaped pad\(result.unflipped == 1 ? " was" : "s were") moved but not flipped")
        }
    }

    /// Places a hole at a design point, the size of the selected holes (or
    /// the last one added), and selects it so the inspector can resize it.
    private func addHole(at p: CGPoint) {
        guard case .drill(let image) = artwork else { return }
        let selectedSizes = image.holes.filter { selection.contains($0.id) }.map { image.diameter($0.tool) }
        let common = image.toolUse.max { $0.value < $1.value }.map { image.diameter($0.key) }
        let diameter = selectedSizes.first ?? lastHoleDiameter ?? common ?? 1.0
        lastHoleDiameter = diameter
        var new = image
        let hole = ExcellonHole(tool: new.tool(forDiameter: diameter), at: p)
        new.holes.append(hole)
        commit(.drill(new), actionName: "Add Hole")
        selection = [hole.id]
    }

    /// Grid first, then guides within reach (both optional).
    private func snapped(_ p: CGPoint, context: ShapeEditor.SnapContext) -> CGPoint {
        var q = context.gridSnap?(p) ?? p
        if let gx = context.guidesX.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(gx - p.x) <= context.tolerance { q.x = gx }
        if let gy = context.guidesY.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(gy - p.y) <= context.tolerance { q.y = gy }
        return q
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

    // MARK: - Pointer input (design coordinates)

    func click(at p: CGPoint, shift: Bool, tolerance: Double, context: ShapeEditor.SnapContext? = nil) {
        focusRequest += 1
        let hit = artwork?.hitTest(p, tolerance: tolerance)
        if addingHoles, hit == nil, !shift {
            addHole(at: context.map { snapped(p, context: $0) } ?? p)
            return
        }
        if let id = hit {
            if shift {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else {
                selection = [id]
            }
        } else if !shift {
            selection = []
        }
    }

    func dragBegan(at p: CGPoint, shift: Bool, tolerance: Double) {
        focusRequest += 1
        guard let artwork else { return }
        if let id = artwork.hitTest(p, tolerance: tolerance) {
            if !selection.contains(id) { selection = shift ? selection.union([id]) : [id] }
            drag = .move(origin: p, base: artwork)
        } else {
            drag = .marquee(origin: p)
            marquee = CGRect(origin: p, size: .zero)
        }
    }

    func dragChanged(to p: CGPoint, context: ShapeEditor.SnapContext) {
        guard let drag else { return }
        switch drag {
        case .move(let origin, let base):
            dragPreview = base.moving(selection, by: moveDelta(from: origin, to: p, base: base, context: context))
        case .marquee(let origin):
            marquee = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                             width: abs(p.x - origin.x), height: abs(p.y - origin.y))
        }
    }

    func dragEnded(at p: CGPoint, shift: Bool, context: ShapeEditor.SnapContext) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .move(let origin, let base):
            let delta = moveDelta(from: origin, to: p, base: base, context: context)
            dragPreview = nil
            moveSelection(by: delta)
        case .marquee(let origin):
            marquee = nil
            guard let artwork else { return }
            let rect = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                              width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            // Right-to-left selects what the box touches, left-to-right what it encloses.
            let hits = artwork.objects(in: rect, enclose: p.x >= origin.x)
            selection = shift ? selection.union(hits) : hits
        }
    }

    /// The dragged objects' anchor lands on the grid (Snap to Grid) or a
    /// guide it comes near.
    private func moveDelta(from origin: CGPoint, to p: CGPoint, base: LayerArtwork,
                           context: ShapeEditor.SnapContext) -> CGVector {
        var delta = CGVector(dx: p.x - origin.x, dy: p.y - origin.y)
        if let id = selection.first, let anchor = base.anchor(of: id) {
            let moved = anchor + delta
            let s = snapped(moved, context: context)
            delta = CGVector(dx: delta.dx + s.x - moved.x, dy: delta.dy + s.y - moved.y)
        }
        return delta
    }

    /// Escape: drop the selection, else stop editing.
    func cancel() {
        if addingHoles { addingHoles = false } else if !selection.isEmpty { selection = [] } else { end() }
    }

    var isDragging: Bool { drag != nil }

    /// Whether the point is over the selection (for the grab cursor).
    func isOverSelection(_ p: CGPoint, tolerance: Double) -> Bool {
        guard !selection.isEmpty, let b = displayed?.bounds(of: selection) else { return false }
        return b.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
    }
}
