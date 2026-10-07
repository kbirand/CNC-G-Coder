import SwiftUI

/// Top (XY) view of the generated toolpaths: zoom/pan, per-layer preview,
/// playback-aware rendering (completed moves solid, remainder ghosted).
///
/// Framing is computed fresh every frame from the canvas's actual size and the
/// focused layer's bounds — never cached — so window restoration and split-view
/// layout races can't leave the view mis-fitted. User zoom/pan are relative
/// adjustments (`zoomFactor`, `pan`) on top of the always-correct auto fit.
struct ToolpathCanvasView: View {
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    @ObservedObject var params: ParametersStore
    @ObservedObject var model: AppModel
    /// The shape editor (model.editor), live while a drawn layer is selected.
    @ObservedObject var editor: ShapeEditor
    /// Edits imported Gerber / drill files (model.layerEditor).
    @ObservedObject var layerEditor: LayerFileEditor

    /// Display-only: un-mirror back-side programs (back copper, bottom mask) so
    /// they visually align with the front for registration checks. The
    /// generated G-code always stays mirrored, ready for the CNC.
    @AppStorage("previewFlipBackView") private var flipBackView = false

    /// Off: only the selected layer is shown. On: all programs overlaid, with
    /// the selected one highlighted. Origins are normalized per side (see
    /// Pcb2GcodeService.normalizeOrigins), so overlays register exactly; the
    /// back side needs "Un-mirror Back Side" to land on the front.
    @AppStorage("previewShowAllLayers") var showAllLayers = false

    /// Draw cutting moves as a swath at the real cutter diameter, showing the
    /// material actually removed (not just the tool centerline).
    @AppStorage("previewShowToolWidth") private var showToolWidth = true

    /// The probed height map (autolevel grid) of the shown side, under the
    /// programs: the interpolated surface, grid and points colour-coded by
    /// height. Also shown regardless while probing, while the Machine
    /// panel is on its Height Map tab, and when the loaded machine program
    /// carries a map (see `AppModel.heightMapOverlay`).
    @AppStorage("previewShowHeightMap") private var showHeightMap = true
    @AppStorage("previewFollowTool") private var followTool = false
    @AppStorage("machine.inspectorTab") private var inspectorTab = MachineInspectorTab.control.rawValue
    /// The machine's travel area (bed) while connected (View Options).
    @AppStorage("previewShowMachineTravel") private var showMachineTravel = true
    /// One-shot: frame the travel area too (View Options → Fit Machine Travel).
    @State private var fitTravel = false
    /// Candle's "interpolation grid": lines of the height-map wireframe.
    @AppStorage(HeightMapSurface.interpolationXKey) private var heightMapLinesX = HeightMapSurface.interpolationDefault
    @AppStorage(HeightMapSurface.interpolationYKey) private var heightMapLinesY = HeightMapSurface.interpolationDefault

    /// Rulers along the top (X) and left (Y) edges of the canvas.
    @AppStorage("previewShowRulers") var showRulers = true

    /// Guides dragged out of the rulers, stored as world coordinates in
    /// millimetres: `guidesXRaw` holds vertical guides (a fixed X), `guidesYRaw`
    /// horizontal ones (a fixed Y). They are machine positions, so they stay
    /// put through zoom, pan and layer changes — and across launches.
    @AppStorage("previewGuidesX") private var guidesXRaw = ""
    @AppStorage("previewGuidesY") private var guidesYRaw = ""
    @AppStorage("previewShowGuides") var showGuides = true
    /// Moving the origin lands on grid lines (View Options / View menu).
    @AppStorage(SettingsKeys.snapToGrid) var snapToGrid = false
    /// Non-empty when the sidebar shows a settings group instead of the
    /// selected program; the editor stays out of the way then.
    @AppStorage("ui.sectionOverride") var sectionOverride = ""

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    /// Cursor position in view coordinates, for the ruler crosshair readout.
    @State var hover: CGPoint?
    /// The guide currently being dragged (pulled from a ruler, or an existing
    /// one being moved); nil when no guide drag is in progress.
    @State private var activeGuide: GuideDrag?
    /// What the in-flight drag is doing — decided from where it started.
    @State private var dragMode: DragMode?
    /// Canvas size, mirrored out of the layout so gesture handlers can map
    /// view points to millimetres the same way `draw` does.
    @State var canvasSize: CGSize = .zero
    /// Keyboard focus for the editor's shortcuts (Delete, Esc, arrows, V/L/R/C/T).
    @FocusState var canvasFocused: Bool
    @State var editDrag: EditDrag?
    /// Tape measure mode (see ToolpathCanvasView+Measure.swift).
    @State var measuring = false
    @State var measurement: Measurement?
    @State var outlineCache = OutlineCache()
    @State var artworkCache = ArtworkPieceCache()
    @State private var fitBox = FitBox()

    @State private var zoomFactor: CGFloat = 1     // relative to auto-fit
    @State private var pan: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var lastDrag: CGSize = .zero
    /// Where the origin marker is being dragged to (nil when not dragging).
    @State private var originDrag: OriginTarget?
    /// A dropped origin, shown until the preview regenerates around it (the
    /// document it was dropped on is remembered; any newer one supersedes it).
    @State private var pendingOrigin: (target: OriginTarget, token: UUID)?

    private final class CacheBox {
        var token: UUID?
        var paths: [LayerKind: MappedPaths] = [:]
        var bridges: [LayerKind: Path] = [:]
        /// The program being streamed (see LiveJob): its geometry comes from
        /// the text actually sent, not from the document, and lives for the
        /// job's token — a preview refresh mid-job never touches it.
        var jobToken: UUID?
        var jobPaths: MappedPaths?
        /// The height map's wireframe, keyed by the map's identity (side,
        /// probed date, point count, geometry), the line counts and the
        /// render token.
        var heightMapKey: String?
        var heightMapSurface: [(path: Path, color: Color)] = []
    }
    @State private var cacheBox = CacheBox()

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        PlaybackTimeReader(clock: playback.clock) { playbackContent }
    }

    /// Everything here moves with playback, so it re-renders on each tick.
    @ViewBuilder
    private var playbackContent: some View {
        // Read here, inside the time reader, so Observation re-renders only
        // this subtree when the controller's status changes (5 Hz while
        // connected) — never the pane around it.
        let machine = machineMarkerPosition
        // The live probe target is read here too, so every recorded point
        // redraws the map as it fills in.
        let heightMap = layerEditActive ? nil : model.heightMapOverlay(toggle: showHeightMap, inspectorTab: inspectorTab)
        let travel = showMachineTravel && !layerEditActive ? machineTravel : nil
        Canvas { context, size in
            draw(context: context, size: size, machine: machine, heightMap: heightMap, travel: travel)
        }
        .clipped()
        .background(Color(nsColor: .underPageBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .focusable(editorActive || layerEditActive || measuring)
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onKeyPress(phases: .down) { press in
            if measuring, press.key == .escape {
                // Esc drops the measurement first, then leaves the tool.
                return afterKeyEvent {
                    if measurement != nil { measurement = nil } else { toggleMeasuring() }
                }
            }
            if press.modifiers.isEmpty, press.characters.lowercased() == "m" {
                return afterKeyEvent { toggleMeasuring() }
            }
            if layerEditActive { return layerEditKey(press) }
            return editorKey(press)
        }
        .pointerStyle(pointerStyle)
        .gesture(dragGesture)
        .gesture(magnifyGesture)
        .onContinuousHover { phase in
            // Tracked even without rulers: the origin marker's grab cursor needs it.
            switch phase {
            case .active(let point):
                hover = point
                if !measuring { editorHover(point) }
            case .ended: hover = nil
            }
        }
        .onTapGesture(count: 2) { location in
            if measuring { return }
            if editorActive, editor.draft != nil { editorDoubleClick(at: location) } else if !layerEditActive { resetView() }
        }
        .onTapGesture { location in
            if measuring {
                resignTextFieldFocus()
                measureClick(at: location)
                return
            }
            if playback.placingOrigin { placeOrigin(at: location) }
            resignTextFieldFocus()
            if editorActive {
                editorClick(at: location)
            } else if layerEditActive {
                layerEditClick(at: location)
            }
        }
        // Zoom/pan intentionally survives layer switches; only overlay-mode
        // changes (different framing semantics) reset the view.
        .onChange(of: showAllLayers) { resetView() }
        .onChange(of: flipBackView) { resetView() }
        .onChange(of: model.travelFitRequest) {
            zoomFactor = 1
            pan = .zero
            fitBox.rect = nil
            fitTravel = true
        }
        .onChange(of: playback.selectedLayer) {
            editor.layerDidChange()
            layerEditor.selectedLayerChanged(to: playback.selectedLayer)
            fitBox.rect = nil
        }
        .onChange(of: editor.focusRequest) { canvasFocused = true }
        .onChange(of: layerEditor.focusRequest) { canvasFocused = true }
        .onAppear {
            // Dev hook: `-debugDrawCircleAt x,y` adds an empty drawn layer and
            // then a 5 mm circle at those RULER coordinates, as a click would.
            if let raw = UserDefaults.standard.string(forKey: "debugDrawCircleAt") {
                let v = raw.split(separator: ",").compactMap { Double($0) }
                if v.count == 2 {
                    model.addCustomLayer()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        let center = CGPoint(x: v[0], y: v[1]).applying(editorTransform().inverted())
                        editor.addShape(DrawnShape(geometry: .circle(center: center, diameter: 5)), actionName: "Add Circle")
                    }
                }
            }
            // Dev hook: `-debugMeasure x1,y1,x2,y2` shows a measurement (ruler coordinates, mm).
            if let raw = UserDefaults.standard.string(forKey: "debugMeasure") {
                let v = raw.split(separator: ",").compactMap { Double($0) }
                if v.count == 4 {
                    measuring = true
                    measurement = Measurement(a: CGPoint(x: v[0], y: v[1]), b: CGPoint(x: v[2], y: v[3]))
                }
            }
        }
        .overlay { scrollZoomCatcher }
        .overlay {
            // Right- or middle-drag pans, in every mode, drawing included.
            MousePanCatcher { delta in
                if followTool { followTool = false }
                pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 0) {
                if editorActive {
                    ShapeInspectorPanel(model: model, editor: editor)
                        .padding(.trailing, 10)
                        .padding(.bottom, 90)   // clear of the playback bar
                } else if layerEditActive {
                    LayerEditInspectorPanel(editor: layerEditor)
                        .padding(.trailing, 10)
                        .padding(.bottom, 90)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: editor.selection.isEmpty)
            .animation(.easeInOut(duration: 0.18), value: layerEditor.selection.isEmpty)
        }
        .overlay(alignment: .topLeading) { topOverlays }
        .overlay(alignment: .bottomLeading) {
            if preview.document == nil, !editorActive {
                Text("No preview yet — choose a project folder, then Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .padding(.leading, showRulers ? Self.leftGutter : 0)   // clear of the Y ruler
            }
        }
    }

    func resetView() {
        zoomFactor = 1
        pan = .zero
        fitBox.rect = nil   // editing: refit to what is drawn now
        fitTravel = false
    }

    /// The editor bar and the Set Origin banner, stacked under the ruler.
    @ViewBuilder
    private var topOverlays: some View {
        VStack(alignment: .leading, spacing: 8) {
            zoomControls
            if editorActive {
                ShapeEditorToolbar(model: model, editor: editor)
            } else if layerEditActive {
                LayerEditToolbar(model: model, editor: layerEditor)
            }
            originBanner
            measureBanner
        }
        .padding(.leading, (showRulers ? Self.leftGutter : 0) + 10)
        .padding(.top, (showRulers ? Self.topGutter : 0) + 10)
    }

    private var scrollZoomCatcher: some View {
        ScrollWheelCatcher { deltaY, location, size in
            // Gentle exponent: ~1.5% zoom per wheel line, smooth on trackpads.
            zoomAnchored(factor: exp(deltaY * 0.00067), at: location, size: size)
        }
    }

    /// Zoom keeping the world point under the cursor stationary.
    private func zoomAnchored(factor: CGFloat, at location: CGPoint, size: CGSize) {
        let old = zoomFactor
        let new = min(max(old * factor, 0.02), 300)
        guard new != old else { return }
        let ratio = new / old
        let plot = plotRect(in: size)
        let cx = plot.midX
        let cy = plot.midY
        pan = CGSize(
            width: location.x - cx - (location.x - cx - pan.width) * ratio,
            height: location.y - cy - (location.y - cy - pan.height) * ratio
        )
        zoomFactor = new
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize, machine: CGPoint?, heightMap: HeightMapOverlay?,
                      travel: MachineTravel?) {
        guard let map = mapping(in: size) else { return }
        let plot = map.plot
        let focus = map.focus
        let scale = map.scale
        let step = tickStep(scale: scale).mm

        var ctx = context
        ctx.clip(to: Path(plot))   // toolpaths never spill into the ruler bands
        let world = CGAffineTransform.identity
            .translatedBy(x: plot.midX + pan.width, y: plot.midY + pan.height)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -focus.midX, y: -focus.midY)
        ctx.concatenate(world)

        drawGrid(&ctx, world: map.visibleWorld, scale: scale, step: step)
        if let travel { drawMachineTravel(&ctx, travel: travel, scale: scale) }

        // Editing a layer file: only its artwork. The programs are out of
        // date until editing ends, so they are not drawn under it.
        if !layerEditActive {
            if let heightMap { drawHeightMap(&ctx, overlay: heightMap, scale: scale) }
            drawLayers(&ctx, doc: preview.document, scale: scale)
            // Simulating (playing or scrubbed, no job): the red tool follows
            // playback and the machine, if connected, is the blue marker.
            // Otherwise the tool follows the machine's live position (as in
            // Candle) when connected, else playback.
            let simulating = playback.job == nil && (playback.isPlaying || playback.currentTime > 0)
            if simulating, let position = playbackToolPosition {
                drawToolMarker(&ctx, at: position, scale: scale)
                if let machine { drawMachineMarker(&ctx, at: machine, scale: scale) }
            } else if let machine {
                drawToolMarker(&ctx, at: machine, scale: scale)
            } else if let position = playbackToolPosition {
                drawToolMarker(&ctx, at: position, scale: scale)
            }
        }

        drawEditor(context, map: map, world: world)
        drawLayerEdit(context, map: map, world: world)
        drawMeasurement(context, map: map)
        drawGuides(context, map: map)
        drawOriginMarker(context, map: map)
        if let heightMap { drawHeightMapLegend(context, map: map, overlay: heightMap) }
        if showRulers {
            drawRulers(context, size: size, map: map, step: step)
        }
    }

    /// The programs: the selected one alone, or — with All Layers Overlay on —
    /// every program with the selected one on top. While a job streams, the
    /// selected program is the job's own geometry (which may exist without
    /// any document at all: an external .ngc sent straight to the machine).
    private func drawLayers(_ ctx: inout GraphicsContext, doc: PreviewDocument?, scale: CGFloat) {
        let cache = doc.map { cachedPaths(for: $0) } ?? [:]
        let engaged = playback.isEngaged
        let job = playback.job
        let jobPaths = job.map { cachedJobPaths(for: $0) }

        func drawSelected(_ layer: ParsedLayer, _ paths: MappedPaths) {
            var layerCtx = ctx
            if let flip = displayTransform(for: layer.id) { layerCtx.concatenate(flip) }
            drawSelectedLayer(&layerCtx, layer: layer, paths: paths, engaged: engaged, scale: scale)
        }

        if showAllLayers {
            // Overlay all programs; draw order: outline, back, front, drills on top.
            // The job's own document layer is left out: the job draws it.
            let ordered = (doc?.layers ?? [])
                .filter { $0.id != job?.kind }
                .sorted { drawRank($0.id) < drawRank($1.id) }
            for layer in ordered {
                guard let paths = cache[layer.id] else { continue }
                if job == nil, layer.id == playback.displayedKind {
                    drawSelected(layer, paths)
                } else {
                    var layerCtx = ctx
                    if let flip = displayTransform(for: layer.id) { layerCtx.concatenate(flip) }
                    strokeLayer(&layerCtx, layerID: layer.id, paths: paths,
                                cut: paths.cutFull, travel: paths.travelFull,
                                color: layer.id.color, dimming: engaged ? 0.15 : 0.35,
                                hits: layer.drillHits, scale: scale,
                                toolDiameter: layer.toolDiameter)
                }
            }
            if let job, let jobPaths { drawSelected(job.layer, jobPaths) }
        } else if let job, let jobPaths {
            drawSelected(job.layer, jobPaths)
        } else if editorActive {
            // Only the drawn layer's own program — none yet while it is empty
            // (never the fallback first program).
            guard let kind = editorLayerKind, let layer = doc?.layers.first(where: { $0.id == kind }),
                  let paths = cache[layer.id] else { return }
            drawSelected(layer, paths)
        } else if let doc, let layer = selectedLayer(in: doc), let paths = cache[layer.id] {
            drawSelected(layer, paths)
        }
    }

    private func drawSelectedLayer(_ ctx: inout GraphicsContext, layer: ParsedLayer, paths: MappedPaths,
                                   engaged: Bool, scale: CGFloat) {
        if engaged {
            // Ghost of the whole program, then the completed prefix on top.
            strokeLayer(&ctx, layerID: layer.id, paths: paths,
                        cut: paths.cutFull, travel: paths.travelFull,
                        color: layer.id.color, dimming: 0.13, hits: [], scale: scale,
                        toolDiameter: layer.toolDiameter)
            let prefix = paths.prefix(playback.completedMoves)
            strokeLayer(&ctx, layerID: layer.id, paths: paths,
                        cut: prefix.cut, travel: prefix.travel,
                        color: layer.id.color, dimming: 1, hits: layer.drillHits, scale: scale,
                        toolDiameter: layer.toolDiameter, includeBridges: false)
            drawPartialMove(&ctx, layer: layer, scale: scale)
        } else {
            strokeLayer(&ctx, layerID: layer.id, paths: paths,
                        cut: paths.cutFull, travel: paths.travelFull,
                        color: layer.id.color, dimming: 1, hits: layer.drillHits, scale: scale,
                        toolDiameter: layer.toolDiameter)
        }
    }

    private func strokeLayer(_ ctx: inout GraphicsContext, layerID: LayerKind, paths: MappedPaths,
                             cut: Path, travel: Path, color: Color, dimming: Double, hits: [CGPoint],
                             scale: CGFloat, toolDiameter: Double? = nil, includeBridges: Bool = true) {
        // Head travel (rapids / moves above the surface) — always yellow, a
        // color no layer uses, so travel is distinguishable at a glance.
        ctx.stroke(
            travel,
            with: .color(Color.yellow.opacity(0.45 * dimming)),
            style: StrokeStyle(lineWidth: 0.8 / scale, dash: [4 / scale, 3 / scale])
        )
        // Material actually removed: swath at cutter diameter (world mm units,
        // so it scales with zoom), under the centerline.
        if showToolWidth, let toolDiameter, toolDiameter > 0 {
            ctx.stroke(
                cut,
                with: .color(color.opacity(0.30 * dimming)),
                style: StrokeStyle(lineWidth: toolDiameter, lineCap: .round, lineJoin: .round)
            )
        }
        ctx.stroke(
            cut,
            with: .color(color.opacity(0.85 * dimming)),
            style: StrokeStyle(lineWidth: 1.6 / scale, lineCap: .round, lineJoin: .round)
        )
        // Bridge tabs (outline only): white at full kerf width, so the holding
        // tabs — where material is left connecting the board — are obvious.
        if includeBridges, let bridges = cacheBox.bridges[layerID] {
            let width = max(toolDiameter ?? 0, 3.2 / scale)
            ctx.stroke(
                bridges,
                with: .color(.white.opacity(0.75 * dimming)),
                style: StrokeStyle(lineWidth: width, lineCap: .butt)
            )
        }
        guard !hits.isEmpty else { return }
        let radius = 2.5 / scale
        var dots = Path()
        for hit in hits {
            dots.addEllipse(in: CGRect(x: hit.x - radius, y: hit.y - radius, width: radius * 2, height: radius * 2))
        }
        ctx.fill(dots, with: .color(color.opacity(0.7 * dimming)))
    }

    /// The in-progress move, drawn from its start to the interpolated tool position.
    private func drawPartialMove(_ ctx: inout GraphicsContext, layer: ParsedLayer, scale: CGFloat) {
        guard let index = playback.progressIndex, index < layer.moves.count,
              let position = playback.toolPosition else { return }
        let move = layer.moves[index]
        var segment = Path()
        segment.move(to: move.start)
        segment.addLine(to: position)
        let color = layer.id.color
        switch move.kind {
        case .cut, .plunge:
            if showToolWidth, let d = layer.toolDiameter, d > 0 {
                ctx.stroke(segment, with: .color(color.opacity(0.30)),
                           style: StrokeStyle(lineWidth: d, lineCap: .round, lineJoin: .round))
            }
            ctx.stroke(segment, with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.6 / scale, lineCap: .round, lineJoin: .round))
        case .rapid:
            ctx.stroke(segment, with: .color(Color.yellow.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 0.8 / scale, dash: [4 / scale, 3 / scale]))
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, world: CGRect, scale: CGFloat, step: CGFloat) {
        // Two grid lines per labelled ruler tick: the grid always matches the
        // numbers on the rulers, at every zoom level.
        let step = step / 2
        let inset = world.insetBy(dx: -step, dy: -step)
        var grid = Path()
        var x = (inset.minX / step).rounded(.down) * step
        while x <= inset.maxX {
            grid.move(to: CGPoint(x: x, y: inset.minY))
            grid.addLine(to: CGPoint(x: x, y: inset.maxY))
            x += step
        }
        var y = (inset.minY / step).rounded(.down) * step
        while y <= inset.maxY {
            grid.move(to: CGPoint(x: inset.minX, y: y))
            grid.addLine(to: CGPoint(x: inset.maxX, y: y))
            y += step
        }
        ctx.stroke(grid, with: .color(.gray.opacity(0.12)), lineWidth: 0.5 / scale)
        // Machine axes (X0 / Y0) stand out from the rest of the grid.
        var axes = Path()
        if world.minX <= 0, world.maxX >= 0 {
            axes.move(to: CGPoint(x: 0, y: inset.minY))
            axes.addLine(to: CGPoint(x: 0, y: inset.maxY))
        }
        if world.minY <= 0, world.maxY >= 0 {
            axes.move(to: CGPoint(x: inset.minX, y: 0))
            axes.addLine(to: CGPoint(x: inset.maxX, y: 0))
        }
        if !axes.isEmpty {
            ctx.stroke(axes, with: .color(.gray.opacity(0.28)), lineWidth: 0.7 / scale)
        }
    }

    /// The playback (planned) tool position in the shown frame.
    private var playbackToolPosition: CGPoint? {
        guard let selected = playback.displayedKind, var position = playback.toolPosition else { return nil }
        if let flip = displayTransform(for: selected) { position = position.applying(flip) }
        return position
    }

    /// The machine's live position while a simulation plays: a blue dot
    /// with a crosshair, distinct from the red simulated tool.
    private func drawMachineMarker(_ ctx: inout GraphicsContext, at position: CGPoint, scale: CGFloat) {
        let r = 5 / scale
        let gap = 2 / scale
        var marker = Path()
        marker.addEllipse(in: CGRect(x: position.x - r, y: position.y - r, width: r * 2, height: r * 2))
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            marker.move(to: CGPoint(x: position.x + dx * gap, y: position.y + dy * gap))
            marker.addLine(to: CGPoint(x: position.x + dx * r * 2.2, y: position.y + dy * r * 2.2))
        }
        ctx.stroke(marker, with: .color(.white.opacity(0.6)), lineWidth: 3 / scale)
        ctx.stroke(marker, with: .color(.blue), lineWidth: 1.4 / scale)
    }

    /// The red tool crosshair: at the machine's live position while
    /// connected, else at the playback position.
    private func drawToolMarker(_ ctx: inout GraphicsContext, at position: CGPoint, scale: CGFloat) {
        let r = 4 / scale
        var marker = Path()
        marker.addEllipse(in: CGRect(x: position.x - r, y: position.y - r, width: r * 2, height: r * 2))
        marker.move(to: CGPoint(x: position.x - r * 2, y: position.y))
        marker.addLine(to: CGPoint(x: position.x + r * 2, y: position.y))
        marker.move(to: CGPoint(x: position.x, y: position.y - r * 2))
        marker.addLine(to: CGPoint(x: position.x, y: position.y + r * 2))
        ctx.stroke(marker, with: .color(.red), lineWidth: 1.2 / scale)
    }

    // MARK: - Machine

    /// The connected controller's work position, in the shown program's
    /// frame — nil when nothing is connected, no position is known yet, or
    /// the board side on the machine (the job's) is not the one shown: a
    /// back-side program's coordinates are mirrored, so the position would
    /// land in the wrong place.
    private var machineMarkerPosition: CGPoint? {
        let machine = model.machine
        guard machine.isConnected, let work = machine.smoothedWorkPosition ?? machine.status.workPosition,
              let shown = playback.displayedKind else { return nil }
        if let job = playback.job, job.kind.boardSide != shown.boardSide { return nil }
        var point = CGPoint(x: work.x, y: work.y)
        if let flip = displayTransform(for: shown) { point = point.applying(flip) }
        return point
    }

    // MARK: - Machine travel

    /// The connected machine's travel area in the shown frame.
    struct MachineTravel {
        var rect: CGRect
        /// Width × height in mm, before any flip.
        var size: CGSize
        var home: CGPoint?
    }

    /// The bed (axis ranges − work offset) in work coordinates, through the
    /// display flip of the shown program; nil when not connected or the
    /// ranges / offset are unknown.
    private var machineTravel: MachineTravel? {
        let machine = model.machine
        guard machine.isConnected, let rect = machine.workTravelRect else { return nil }
        var shown = rect
        var home = machine.workHomeCorner
        if let kind = playback.displayedKind, let flip = displayTransform(for: kind) {
            shown = rect.applying(flip)
            home = home?.applying(flip)
        }
        return MachineTravel(rect: shown, size: rect.size, home: home)
    }

    /// A dashed grey outline with its size in a corner and a small marker at
    /// the home corner.
    private func drawMachineTravel(_ ctx: inout GraphicsContext, travel: MachineTravel, scale: CGFloat) {
        ctx.stroke(Path(travel.rect), with: .color(.gray.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1 / scale, dash: [6 / scale, 4 / scale]))
        if let home = travel.home {
            let r = 4 / scale
            var marker = Path()
            marker.addRect(CGRect(x: home.x - r, y: home.y - r, width: r * 2, height: r * 2))
            marker.move(to: CGPoint(x: home.x - r, y: home.y))
            marker.addLine(to: CGPoint(x: home.x + r, y: home.y))
            marker.move(to: CGPoint(x: home.x, y: home.y - r))
            marker.addLine(to: CGPoint(x: home.x, y: home.y + r))
            ctx.stroke(marker, with: .color(.gray), lineWidth: 1 / scale)
        }
        let label = "Machine travel \(formatMM(travel.size.width, decimals: 0)) × \(formatMM(travel.size.height, decimals: 0)) mm"
        drawWorldLabel(ctx, label, at: CGPoint(x: travel.rect.minX + 3 / scale, y: travel.rect.maxY - 3 / scale),
                       transform: .identity, color: .gray, anchor: .topLeading)
    }

    /// The region the travel fit frames: the usual bounds plus the bed.
    private func travelFitBounds(_ bounds: CGRect) -> CGRect {
        guard fitTravel, let travel = machineTravel else { return bounds }
        return bounds.union(travel.rect)
    }

    /// The height map of the shown side, Candle-style, under the programs:
    /// the wireframe interpolation grid (every segment coloured by its
    /// height, blue = lowest … red = highest; flat and teal where nothing
    /// is probed yet), the border, every probe point as a hollow (unprobed)
    /// or filled (probed) dot, the point being probed as a pulsing yellow
    /// ring, and the heights as labels once zoomed in enough to read. The
    /// map is in the side's work frame, so it is un-mirrored with the back
    /// side like everything else.
    private func drawHeightMap(_ ctx: inout GraphicsContext, overlay: HeightMapOverlay, scale: CGFloat) {
        let map = overlay.map
        var mapCtx = ctx
        // Design coordinates → the side's program frame → the display flip.
        let flip = playback.displayedKind.flatMap { displayTransform(for: $0) }
        if let flip { mapCtx.concatenate(flip) }
        mapCtx.concatenate(overlay.frame)
        let toWorld = overlay.frame.concatenating(flip ?? .identity)
        let range = HeightMapSurface.range(map)

        // The interpolation grid, cached per map (see CacheBox), 1 px lines.
        for (path, color) in cachedHeightMapSurface(for: overlay) {
            mapCtx.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 1 / scale)
        }
        // The border.
        mapCtx.stroke(Path(map.rect), with: .color(.teal), lineWidth: 1 / scale)

        // The probe points.
        let r = 2.5 / scale
        let labelled = scale >= 6
        for row in 0..<map.ny {
            for col in 0..<map.nx {
                let p = map.gridPoint(row: row, col: col)
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                guard let z = HeightMapSurface.value(map, at: HeightMapIndex(row: row, col: col)) else {
                    mapCtx.stroke(Path(ellipseIn: rect), with: .color(.teal.opacity(0.8)), lineWidth: 1 / scale)
                    continue
                }
                let color = HeightMapSurface.hasSpread(range)
                    ? HeightMapSurface.color(unit: HeightMapSurface.unit(z, in: range!)) : HeightMapSurface.neutral
                mapCtx.fill(Path(ellipseIn: rect), with: .color(color))
                mapCtx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 0.6 / scale)
                if labelled {
                    drawWorldLabel(ctx, String(format: "%+.3f", z), at: CGPoint(x: p.x + r * 1.4, y: p.y + r * 1.4),
                                   transform: toWorld, color: color, anchor: .bottomLeading)
                }
            }
        }
        // (d) The point being probed: a pulsing yellow ring (the canvas
        // redraws with every status report, so the pulse runs at that rate).
        // (The reference is work X0/Y0: that design point.)
        let probingAt: CGPoint? = overlay.probingReference ? CGPoint.zero.applying(overlay.frame.inverted())
            : overlay.currentPoint.map { map.gridPoint(row: $0.row, col: $0.col) }
        if overlay.probing, let p = probingAt {
            let phase = (Date().timeIntervalSinceReferenceDate * 2).truncatingRemainder(dividingBy: 1)
            let pulse = r * (1.8 + 0.6 * sin(phase * 2 * .pi))
            let ring = Path(ellipseIn: CGRect(x: p.x - pulse, y: p.y - pulse, width: pulse * 2, height: pulse * 2))
            mapCtx.stroke(ring, with: .color(.yellow.opacity(0.9)), lineWidth: 2 / scale)
            mapCtx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                          with: .color(.yellow), lineWidth: 1.2 / scale)
        }
    }

    /// Text is drawn unscaled: the anchor (in the coordinates `transform`
    /// maps to the world) goes through the world transform by hand.
    private func drawWorldLabel(_ ctx: GraphicsContext, _ text: String, at anchor: CGPoint,
                                transform: CGAffineTransform, color: Color, anchor unitPoint: UnitPoint) {
        let world = anchor.applying(transform)
        var textCtx = ctx
        textCtx.transform = .identity
        let view = world.applying(ctx.transform)
        textCtx.draw(Text(text).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(color),
                     at: view, anchor: unitPoint)
    }

    /// The legend box in the plot's bottom-right corner, in view coordinates.
    private func drawHeightMapLegend(_ context: GraphicsContext, map: Mapping, overlay: HeightMapOverlay) {
        let title = overlay.legend
        var detail: String?
        if overlay.probing, !overlay.probingReference, let last = HeightMapSurface.lastProbed(overlay.map) {
            detail = String(format: "last Z %+.3f mm", last.z)
        } else if !overlay.probing, let date = overlay.map.probedAt {
            detail = "\(overlay.side.title) side · probed " + date.formatted(date: .abbreviated, time: .shortened)
        } else {
            detail = "\(overlay.side.title) side"
        }
        let titleText = context.resolve(Text(title).font(.caption.weight(.medium).monospacedDigit()).foregroundStyle(.primary))
        let detailText = detail.map { context.resolve(Text($0).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)) }
        let titleSize = titleText.measure(in: CGSize(width: 400, height: 40))
        let detailSize = detailText?.measure(in: CGSize(width: 400, height: 40)) ?? .zero
        let padding: CGFloat = 7
        let width = max(titleSize.width, detailSize.width) + padding * 2
        let height = titleSize.height + (detailText == nil ? 0 : detailSize.height + 2) + padding * 2
        let box = CGRect(x: map.plot.maxX - 10 - width, y: map.plot.maxY - 10 - height, width: width, height: height)
        context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        context.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(.teal.opacity(0.6)), lineWidth: 1)
        context.draw(titleText, at: CGPoint(x: box.minX + padding, y: box.minY + padding), anchor: .topLeading)
        if let detailText {
            context.draw(detailText, at: CGPoint(x: box.minX + padding, y: box.minY + padding + titleSize.height + 2), anchor: .topLeading)
        }
    }

    /// The wireframe of the overlay's map, rebuilt here — inside the draw
    /// closure, like the path caches — when the map or the line counts change.
    private func cachedHeightMapSurface(for overlay: HeightMapOverlay) -> [(path: Path, color: Color)] {
        let map = overlay.map
        let key = "\(overlay.side.rawValue)|\(map.probedAt?.timeIntervalSinceReferenceDate ?? 0)|\(map.probedCount)|"
            + "\(playback.renderToken?.uuidString ?? "-")|\(map.rect)|\(map.nx)x\(map.ny)|\(heightMapLinesX)x\(heightMapLinesY)"
        if cacheBox.heightMapKey != key {
            cacheBox.heightMapKey = key
            cacheBox.heightMapSurface = HeightMapSurface.wireframePaths(map, linesX: heightMapLinesX, linesY: heightMapLinesY)
        }
        return cacheBox.heightMapSurface
    }

    // MARK: - Rulers

    /// Gutters reserved for the rulers. The left one holds Y labels, which can
    /// run to four characters ("-100"), so it is the wider of the two.
    static let leftGutter: CGFloat = 34
    static let topGutter: CGFloat = 20

    /// The drawing area: the canvas minus the ruler gutters.
    func plotRect(in size: CGSize) -> CGRect {
        guard showRulers else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: Self.leftGutter, y: Self.topGutter,
                      width: max(1, size.width - Self.leftGutter),
                      height: max(1, size.height - Self.topGutter))
    }

    /// World (mm) ↔ view (points) mapping for the current framing. Mirrors the
    /// transform applied to the toolpath context, so rulers, grid and the
    /// hover readout can never drift out of step with the drawing.
    struct Mapping {
        let plot: CGRect
        let pan: CGSize
        let focus: CGRect
        let scale: CGFloat

        func viewX(_ x: CGFloat) -> CGFloat { plot.midX + pan.width + (x - focus.midX) * scale }
        func viewY(_ y: CGFloat) -> CGFloat { plot.midY + pan.height - (y - focus.midY) * scale }
        func worldX(_ x: CGFloat) -> CGFloat { focus.midX + (x - plot.midX - pan.width) / scale }
        func worldY(_ y: CGFloat) -> CGFloat { focus.midY - (y - plot.midY - pan.height) / scale }

        /// The world rectangle currently visible inside the plot area.
        var visibleWorld: CGRect {
            let minX = worldX(plot.minX), maxX = worldX(plot.maxX)
            let minY = worldY(plot.maxY), maxY = worldY(plot.minY)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// The framing for a given canvas size — the single definition of where
    /// world millimetres land on screen, used by drawing and by the gestures.
    func mapping(in size: CGSize) -> Mapping? {
        let plot = plotRect(in: size)
        guard plot.width > 1, plot.height > 1 else { return nil }
        let focus = fitBounds()
        guard focus.width > 0 || focus.height > 0 else { return nil }
        // Auto-fit scale from the real drawing area (canvas minus rulers), every frame.
        let fitScale = 0.9 * min(plot.width / max(focus.width, 0.001),
                                 plot.height / max(focus.height, 0.001))
        let scale = fitScale * zoomFactor
        // Following the tool: the pan keeps the tool at the plot centre.
        if followTool, let tool = followedToolPosition {
            let followPan = CGSize(width: -(tool.x - focus.midX) * scale, height: (tool.y - focus.midY) * scale)
            return Mapping(plot: plot, pan: followPan, focus: focus, scale: scale)
        }
        return Mapping(plot: plot, pan: pan, focus: focus, scale: scale)
    }

    /// The point the view follows: the machine while connected, else playback.
    private var followedToolPosition: CGPoint? {
        let simulating = playback.job == nil && (playback.isPlaying || playback.currentTime > 0)
        if simulating, let p = playbackToolPosition { return p }
        return machineMarkerPosition ?? playbackToolPosition
    }

    /// Smallest 1/2/5 × 10ⁿ value that is at least `minimum` — keeps tick
    /// labels on round numbers at any zoom level.
    private func niceStep(minimum: CGFloat) -> CGFloat {
        guard minimum > 0, minimum.isFinite else { return 1 }
        let base = pow(10, floor(log10(minimum)))
        for multiple in [1.0, 2.0, 5.0] where base * multiple >= minimum {
            return base * multiple
        }
        return base * 10
    }

    /// Spacing between labelled ticks, chosen in the DISPLAY unit so inches
    /// land on round inches rather than on converted millimetres.
    func tickStep(scale: CGFloat) -> (mm: CGFloat, display: CGFloat) {
        let perMM = CGFloat(units.perMM)
        let display = niceStep(minimum: 64 / scale * perMM)
        return (display / perMM, display)
    }

    private func tickLabel(_ value: CGFloat, step: CGFloat) -> String {
        if abs(value) < step / 1000 { return "0" }
        let decimals = max(0, Int(ceil(-log10(Double(step)))))
        return String(format: "%.\(decimals)f", Double(value))
    }

    private func drawRulers(_ context: GraphicsContext, size: CGSize, map: Mapping, step: CGFloat) {
        let plot = map.plot
        let world = map.visibleWorld
        let bandColor = Color(nsColor: .windowBackgroundColor)

        var ctx = context
        ctx.fill(Path(CGRect(x: plot.minX, y: 0, width: plot.width, height: Self.topGutter)),
                 with: .color(bandColor))
        ctx.fill(Path(CGRect(x: 0, y: plot.minY, width: Self.leftGutter, height: plot.height)),
                 with: .color(bandColor))
        // Corner block, with the unit the numbers are in.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: Self.leftGutter, height: Self.topGutter)),
                 with: .color(bandColor))
        ctx.draw(Text(units.lengthSymbol).font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary),
                 at: CGPoint(x: Self.leftGutter / 2, y: Self.topGutter / 2))

        var separators = Path()
        separators.move(to: CGPoint(x: 0, y: plot.minY))
        separators.addLine(to: CGPoint(x: size.width, y: plot.minY))
        separators.move(to: CGPoint(x: plot.minX, y: 0))
        separators.addLine(to: CGPoint(x: plot.minX, y: size.height))
        ctx.stroke(separators, with: .color(.gray.opacity(0.35)), lineWidth: 1)

        // Minor ticks subdivide each labelled step 5×, but only while they stay
        // far enough apart to read as ticks rather than a grey band.
        let minorStep = step / 5
        let showMinor = minorStep * map.scale >= 5
        let labelFont = Font.system(size: 9, design: .rounded).monospacedDigit()
        let perMM = CGFloat(units.perMM)
        let stepDisplay = step * perMM

        var majors = Path()
        var minors = Path()

        var x = (world.minX / minorStep).rounded(.down) * minorStep
        while x <= world.maxX {
            let vx = map.viewX(x)
            let isMajor = abs(x / step - (x / step).rounded()) < 1e-6
            if vx >= plot.minX - 0.5, vx <= plot.maxX + 0.5 {
                if isMajor {
                    majors.move(to: CGPoint(x: vx, y: Self.topGutter))
                    majors.addLine(to: CGPoint(x: vx, y: Self.topGutter - 5))
                    ctx.draw(Text(tickLabel(x * perMM, step: stepDisplay)).font(labelFont).foregroundStyle(.secondary),
                             at: CGPoint(x: vx, y: 6.5))
                } else if showMinor {
                    minors.move(to: CGPoint(x: vx, y: Self.topGutter))
                    minors.addLine(to: CGPoint(x: vx, y: Self.topGutter - 2.5))
                }
            }
            x += minorStep
        }

        var y = (world.minY / minorStep).rounded(.down) * minorStep
        while y <= world.maxY {
            let vy = map.viewY(y)
            let isMajor = abs(y / step - (y / step).rounded()) < 1e-6
            if vy >= plot.minY - 0.5, vy <= plot.maxY + 0.5 {
                if isMajor {
                    majors.move(to: CGPoint(x: Self.leftGutter, y: vy))
                    majors.addLine(to: CGPoint(x: Self.leftGutter - 5, y: vy))
                    ctx.draw(Text(tickLabel(y * perMM, step: stepDisplay)).font(labelFont).foregroundStyle(.secondary),
                             at: CGPoint(x: Self.leftGutter / 2 - 2, y: vy))
                } else if showMinor {
                    minors.move(to: CGPoint(x: Self.leftGutter, y: vy))
                    minors.addLine(to: CGPoint(x: Self.leftGutter - 2.5, y: vy))
                }
            }
            y += minorStep
        }

        ctx.stroke(minors, with: .color(.gray.opacity(0.45)), lineWidth: 1)
        ctx.stroke(majors, with: .color(.gray.opacity(0.8)), lineWidth: 1)

        drawHoverReadout(&ctx, map: map, step: step)
    }

    /// Crosshair guides plus the cursor's machine coordinates, shown in the
    /// rulers — the quickest way to check where a feature really sits.
    private func drawHoverReadout(_ ctx: inout GraphicsContext, map: Mapping, step: CGFloat) {
        guard showRulers, let hover, map.plot.contains(hover) else { return }
        let plot = map.plot
        let tint = Color.accentColor

        var guides = Path()
        guides.move(to: CGPoint(x: hover.x, y: plot.minY))
        guides.addLine(to: CGPoint(x: hover.x, y: plot.maxY))
        guides.move(to: CGPoint(x: plot.minX, y: hover.y))
        guides.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
        ctx.stroke(guides, with: .color(tint.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        // One more decimal than the ticks: the readout is for inspecting, the
        // ticks only for orientation.
        let perMM = CGFloat(units.perMM)
        let decimals = max(1, Int(ceil(-log10(Double(step * perMM)))) + 1)
        func badge(_ text: String, at point: CGPoint, width: CGFloat, height: CGFloat) {
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(tint))
            ctx.draw(Text(text).font(.system(size: 9, design: .rounded).monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.white),
                     at: CGPoint(x: rect.midX, y: rect.midY))
        }

        let xText = String(format: "%.\(decimals)f", Double(map.worldX(hover.x) * perMM))
        let yText = String(format: "%.\(decimals)f", Double(map.worldY(hover.y) * perMM))
        badge(xText,
              at: CGPoint(x: min(max(hover.x, plot.minX + 22), plot.maxX - 22), y: Self.topGutter / 2),
              width: max(34, CGFloat(xText.count) * 6 + 8), height: 13)
        badge(yText,
              at: CGPoint(x: Self.leftGutter / 2, y: min(max(hover.y, plot.minY + 8), plot.maxY - 8)),
              width: Self.leftGutter - 4, height: 13)
    }

    // MARK: - Guides

    /// A guide line pulled out of a ruler. Vertical guides hold a world X,
    /// horizontal guides a world Y — always in millimetres, whatever the
    /// display unit is.
    enum GuideAxis { case vertical, horizontal }

    struct GuideDrag {
        var axis: GuideAxis
        /// Index into the stored list, or nil while a new guide is being pulled.
        var existing: Int?
        var value: CGFloat
        /// Dragged back out of the drawing area: releasing here removes it.
        var discarding = false
    }

    /// Grab distance for picking up a guide, in points.
    private static let guideHitSlop: CGFloat = 4
    private static let guideColor = Color(red: 0.96, green: 0.32, blue: 0.84)

    var guidesX: [CGFloat] { Self.decodeGuides(guidesXRaw) }
    var guidesY: [CGFloat] { Self.decodeGuides(guidesYRaw) }

    static func decodeGuides(_ raw: String) -> [CGFloat] {
        raw.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    }

    static func encodeGuides(_ values: [CGFloat]) -> String {
        values.sorted().map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// Decides what a drag starting at `start` should do.
    private func beginDrag(at start: CGPoint) -> DragMode {
        guard let map = mapping(in: canvasSize) else { return .pan }
        let plot = map.plot

        // Grabbing the origin marker moves the origin.
        if isOnOriginMarker(start, map: map) {
            originDrag = originTarget(at: start, map: map)
            return .origin
        }

        // Measuring: a drag in the plot measures from press to release.
        if measuring, plot.contains(start), !NSEvent.modifierFlags.contains(.option) {
            measureDragBegan(at: start, map: map)
            return .measure
        }

        // Drawing: everything inside the plot goes to the editor (⌥-drag pans).
        if editorActive || layerEditActive, plot.contains(start), !NSEvent.modifierFlags.contains(.option) {
            editDrag = EditDrag(start: start)
            return .edit
        }

        // Pulling a fresh guide out of a ruler band.
        if showRulers, showGuides {
            if start.y < plot.minY, start.x >= plot.minX {
                activeGuide = GuideDrag(axis: .horizontal, existing: nil, value: map.worldY(start.y))
                return .guide
            }
            if start.x < plot.minX, start.y >= plot.minY {
                activeGuide = GuideDrag(axis: .vertical, existing: nil, value: map.worldX(start.x))
                return .guide
            }
        }
        // Picking up a guide that is already there.
        if showGuides, let hit = guide(at: start, map: map) {
            activeGuide = hit
            return .guide
        }
        return .pan
    }

    /// The guide under a point, preferring whichever line is closest.
    private func guide(at point: CGPoint, map: Mapping) -> GuideDrag? {
        guard map.plot.contains(point) else { return nil }
        var best: (distance: CGFloat, drag: GuideDrag)?
        for (index, value) in guidesX.enumerated() {
            let distance = abs(map.viewX(value) - point.x)
            if distance <= Self.guideHitSlop, distance < (best?.distance ?? .infinity) {
                best = (distance, GuideDrag(axis: .vertical, existing: index, value: value))
            }
        }
        for (index, value) in guidesY.enumerated() {
            let distance = abs(map.viewY(value) - point.y)
            if distance <= Self.guideHitSlop, distance < (best?.distance ?? .infinity) {
                best = (distance, GuideDrag(axis: .horizontal, existing: index, value: value))
            }
        }
        return best?.drag
    }

    private func updateGuide(to point: CGPoint) {
        guard var drag = activeGuide, let map = mapping(in: canvasSize) else { return }
        switch drag.axis {
        case .vertical: drag.value = snapped(map.worldX(point.x), map: map)
        case .horizontal: drag.value = snapped(map.worldY(point.y), map: map)
        }
        drag.discarding = !map.plot.insetBy(dx: -1, dy: -1).contains(point)
        activeGuide = drag
    }

    /// Pulls a guide onto the nearest ruler tick when it is within a few points
    /// of one, so guides land on round numbers without blocking free placement.
    private func snapped(_ world: CGFloat, map: Mapping) -> CGFloat {
        let minor = tickStep(scale: map.scale).mm / 5
        guard minor > 0 else { return world }
        let nearest = (world / minor).rounded() * minor
        return abs(nearest - world) * map.scale <= 3 ? nearest : world
    }

    private func commitGuide() {
        defer { activeGuide = nil }
        guard let drag = activeGuide else { return }
        var values = drag.axis == .vertical ? guidesX : guidesY
        if let index = drag.existing, values.indices.contains(index) {
            if drag.discarding { values.remove(at: index) } else { values[index] = drag.value }
        } else if !drag.discarding {
            values.append(drag.value)
        }
        let encoded = Self.encodeGuides(values)
        if drag.axis == .vertical { guidesXRaw = encoded } else { guidesYRaw = encoded }
    }

    /// Cursor feedback: a resize cursor over a guide, a crosshair over the
    /// rulers where a new guide can be pulled out.
    private var pointerStyle: PointerStyle? {
        if originDrag != nil { return .grabActive }
        if playback.placingOrigin { return .rectSelection }
        if measuring, let hover, let map = mapping(in: canvasSize), map.plot.contains(hover) { return .rectSelection }
        if editorActive, let hover, let map = mapping(in: canvasSize), !isOnOriginMarker(hover, map: map),
           let style = editorPointerStyle(at: hover, map: map) { return style }
        if layerEditActive, let hover, let map = mapping(in: canvasSize), !isOnOriginMarker(hover, map: map),
           let style = layerEditPointerStyle(at: hover, map: map) { return style }
        if let hover, let map = mapping(in: canvasSize), isOnOriginMarker(hover, map: map) { return .grabIdle }
        guard showGuides, let hover, let map = mapping(in: canvasSize) else { return nil }
        if let drag = guide(at: hover, map: map) {
            return drag.axis == .vertical ? .columnResize : .rowResize
        }
        if showRulers, !map.plot.contains(hover) {
            if hover.y < map.plot.minY, hover.x >= map.plot.minX { return .rowResize }
            if hover.x < map.plot.minX, hover.y >= map.plot.minY { return .columnResize }
        }
        return nil
    }

    private func drawGuides(_ context: GraphicsContext, map: Mapping) {
        guard showGuides else { return }
        let plot = map.plot
        var ctx = context
        ctx.clip(to: Path(plot))

        let dragged = activeGuide
        func line(_ axis: GuideAxis, _ value: CGFloat) -> Path {
            var path = Path()
            switch axis {
            case .vertical:
                let x = map.viewX(value).rounded() + 0.5   // crisp hairline
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
            case .horizontal:
                let y = map.viewY(value).rounded() + 0.5
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            return path
        }

        var settled = Path()
        for (index, value) in guidesX.enumerated()
        where !(dragged?.axis == .vertical && dragged?.existing == index) {
            settled.addPath(line(.vertical, value))
        }
        for (index, value) in guidesY.enumerated()
        where !(dragged?.axis == .horizontal && dragged?.existing == index) {
            settled.addPath(line(.horizontal, value))
        }
        ctx.stroke(settled, with: .color(Self.guideColor.opacity(0.8)), lineWidth: 1)

        guard let dragged else { return }
        if dragged.discarding {
            // Ghosted: releasing out here deletes the guide instead of placing it.
            ctx.stroke(line(dragged.axis, dragged.value),
                       with: .color(Self.guideColor.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        } else {
            ctx.stroke(line(dragged.axis, dragged.value), with: .color(Self.guideColor), lineWidth: 1)
        }
        drawGuideBadge(context, map: map, drag: dragged)
    }

    /// The guide's exact position, shown in its ruler while it is being dragged.
    private func drawGuideBadge(_ context: GraphicsContext, map: Mapping, drag: GuideDrag) {
        guard showRulers else { return }
        let ctx = context
        let plot = map.plot
        let decimals = max(1, Int(ceil(-log10(Double(tickStep(scale: map.scale).display)))) + 1)
        let text = String(format: "%.\(decimals)f", Double(drag.value) * units.perMM)
        let color = drag.discarding ? Color.secondary : Self.guideColor

        let rect: CGRect
        switch drag.axis {
        case .vertical:
            let width = max(34, CGFloat(text.count) * 6 + 8)
            let x = min(max(map.viewX(drag.value), plot.minX + width / 2), plot.maxX - width / 2)
            rect = CGRect(x: x - width / 2, y: Self.topGutter / 2 - 6.5, width: width, height: 13)
        case .horizontal:
            let y = min(max(map.viewY(drag.value), plot.minY + 8), plot.maxY - 8)
            rect = CGRect(x: 2, y: y - 6.5, width: Self.leftGutter - 4, height: 13)
        }
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
        ctx.draw(Text(text).font(.system(size: 9, design: .rounded).monospacedDigit().weight(.medium))
                    .foregroundStyle(Color.white),
                 at: CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: - Layer selection / mirroring / bounds

    /// The program the view focuses on. While a job streams it is the job's
    /// own parsed program (the text actually sent), whatever the document
    /// holds — an external file has no document layer at all.
    func selectedLayer(in doc: PreviewDocument) -> ParsedLayer? {
        if let job = playback.job { return job.layer }
        return doc.layers.first { $0.id == playback.selectedLayer } ?? doc.layers.first
    }

    /// Back-side programs are mirrored; "Un-mirror Back Side" maps them onto
    /// the front frame for display (see ProjectFrame.backToFront), so the two
    /// sides overlay in exact registration wherever the origin was put.
    /// A running job uses the mapping snapshotted when it started, so a
    /// preview refresh mid-job cannot move the drawing under the marker.
    func displayTransform(for kind: LayerKind) -> CGAffineTransform? {
        guard flipBackView, kind.isBackSide else { return nil }
        if let job = playback.job { return job.backToFront }
        guard let document = preview.document else { return nil }
        return document.backToFront
    }

    private func displayBounds(for layer: ParsedLayer) -> CGRect? {
        guard let bounds = layer.cutBounds ?? layer.allBounds else { return nil }
        if let flip = displayTransform(for: layer.id) { return bounds.applying(flip) }
        return bounds
    }

    /// The region the view frames: the selected layer's extent, or the union of
    /// all layers' (display-space) extents when overlaying.
    /// The origin is always framed too (as in FlatCAM) once the programs are
    /// zeroed; raw design frames can sit far from their origin, so not then.
    private func fitBounds() -> CGRect {
        let doc = preview.document
        if editorActive, let id = editor.activeLayerID {
            // Frozen per layer while drawing (see FitBox); Fit / double-click refits.
            let toWorld = editorTransform()
            if fitBox.layerID == id, let rect = fitBox.rect, fitBox.hadDocument == (doc != nil) {
                return rect.applying(toWorld)
            }
            var bounds = editorFitBounds() ?? .null
            // The other programs count only when they are shown — or, for an
            // empty layer, to start the sheet on the board.
            if let doc, showAllLayers || bounds.isNull {
                for layer in doc.layers where layer.id != editorLayerKind {
                    if let own = displayBounds(for: layer) { bounds = bounds.union(own) }
                }
            }
            if bounds.isNull || (bounds.width == 0 && bounds.height == 0) {
                bounds = CGRect(x: 0, y: 0, width: 100, height: 80)   // an empty sheet to start on
            }
            bounds = bounds.union(CGRect(origin: displayedOrigin, size: .zero))
            fitBox.layerID = id
            fitBox.rect = bounds.applying(toWorld.inverted())
            fitBox.hadDocument = doc != nil
            return bounds
        }
        fitBox.rect = nil
        guard let doc else {
            // A job with no document (an external file sent to the machine).
            if let job = playback.job, let own = displayBounds(for: job.layer) {
                return travelFitBounds(own.union(CGRect(origin: displayedOrigin, size: .zero)))
            }
            return travelFitBounds(CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        return travelFitBounds(documentFitBounds(doc))
    }

    private func documentFitBounds(_ doc: PreviewDocument) -> CGRect {
        var bounds = CGRect.null
        if !showAllLayers, let layer = selectedLayer(in: doc), let own = displayBounds(for: layer) {
            bounds = own
        } else {
            for layer in doc.layers {
                if let own = displayBounds(for: layer) { bounds = bounds.union(own) }
            }
        }
        if bounds.isNull { bounds = doc.bounds }
        if doc.frame != nil {
            let origin = displayedOrigin
            bounds = bounds.union(CGRect(origin: origin, size: .zero))
        }
        return bounds
    }

    // MARK: - Origin

    /// Where the displayed program's X0/Y0 sits in the drawing: the origin of
    /// the selected program, carried through the un-mirror when a back-side
    /// program is shown un-mirrored.
    var displayedOrigin: CGPoint {
        guard let selected = playback.displayedKind, let flip = displayTransform(for: selected) else { return .zero }
        return CGPoint.zero.applying(flip)
    }

    /// FlatCAM-style origin marker: a ringed crosshair with X (red) and Y
    /// (green) axis arrows, fixed on screen size so it reads at any zoom.
    private func drawOriginMarker(_ context: GraphicsContext, map: Mapping) {
        guard preview.document != nil else { return }
        let world = markerWorld
        let center = CGPoint(x: map.viewX(world.x), y: map.viewY(world.y))
        guard map.plot.insetBy(dx: -30, dy: -30).contains(center) else { return }
        var ctx = context
        ctx.clip(to: Path(map.plot))

        let arm: CGFloat = 30
        func arrow(to end: CGPoint, head: (CGPoint, CGPoint), color: Color, label: String, labelAt: CGPoint) {
            var shaft = Path()
            shaft.move(to: center)
            shaft.addLine(to: end)
            ctx.stroke(shaft, with: .color(color), lineWidth: 1.5)
            var tip = Path()
            tip.move(to: end)
            tip.addLine(to: head.0)
            tip.addLine(to: head.1)
            tip.closeSubpath()
            ctx.fill(tip, with: .color(color))
            ctx.draw(Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color), at: labelAt)
        }
        let xEnd = CGPoint(x: center.x + arm, y: center.y)
        arrow(to: xEnd, head: (CGPoint(x: xEnd.x - 6, y: xEnd.y - 3.5), CGPoint(x: xEnd.x - 6, y: xEnd.y + 3.5)),
              color: .red, label: "X", labelAt: CGPoint(x: xEnd.x + 7, y: xEnd.y))
        let yEnd = CGPoint(x: center.x, y: center.y - arm)
        arrow(to: yEnd, head: (CGPoint(x: yEnd.x - 3.5, y: yEnd.y + 6), CGPoint(x: yEnd.x + 3.5, y: yEnd.y + 6)),
              color: .green, label: "Y", labelAt: CGPoint(x: yEnd.x, y: yEnd.y - 8))

        let r: CGFloat = 6
        let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(ring, with: .color(.black.opacity(0.35)))
        ctx.stroke(ring, with: .color(.white), lineWidth: 1.5)
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - r - 4, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + r + 4, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - r - 4))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + r + 4))
        ctx.stroke(cross, with: .color(.white), lineWidth: 1)

        let side = playback.displayedKind.map { $0.isBackSide && !flipBackView } ?? false
        let pending = pendingOrigin.map { $0.token == preview.document?.token } ?? false
        let caption = originDrag.map { target -> String in
            let units = UnitSystem(rawValue: unitRaw) ?? .metric
            let offset = "X\(units.length(target.display.x)) Y\(units.length(target.display.y))"
            return target.label.isEmpty ? "Drop at \(offset)" : "Drop: \(target.label) · \(offset)"
        }
            ?? (pending ? "Moving X0 Y0…" : (side ? "X0 Y0 · back" : "X0 Y0"))
        ctx.draw(Text(caption)
                    .font(.system(size: 9, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.85)),
                 at: CGPoint(x: center.x - 8, y: center.y + 14), anchor: .topTrailing)
    }

    /// Snap distance when placing the origin, in points.
    private static let originSnap: CGFloat = 10

    /// A place the origin can be put: a project corner/centre (stored as that
    /// mode) or any other point (stored as a custom design-coordinate point).
    struct OriginTarget {
        /// Where it sits in the drawing's current frame.
        var display: CGPoint
        var mode: String
        var design: CGPoint?
        /// What it snapped to, for the marker caption; empty = free point.
        var label: String
    }

    /// Where the marker is drawn: mid-drag, just dropped, or the real origin.
    private var markerWorld: CGPoint {
        if let originDrag { return originDrag.display }
        if let pendingOrigin, pendingOrigin.token == preview.document?.token { return pendingOrigin.target.display }
        return displayedOrigin
    }

    /// The whole marker is a handle: the ring, both axis arrows and the caption.
    private func isOnOriginMarker(_ location: CGPoint, map: Mapping) -> Bool {
        guard preview.document != nil else { return false }
        let o = markerWorld
        let center = CGPoint(x: map.viewX(o.x), y: map.viewY(o.y))
        let dx = location.x - center.x, dy = location.y - center.y
        if hypot(dx, dy) <= 14 { return true }
        if abs(dy) <= 7, dx >= 0, dx <= 44 { return true }       // X arrow and its label
        if abs(dx) <= 7, dy <= 0, dy >= -44 { return true }      // Y arrow and its label
        return dx >= -60 && dx <= 0 && dy >= 8 && dy <= 28     // caption
    }

    /// Resolves a view location to an origin target, snapping to the
    /// project's corners and centre first, then to drill holes.
    private func originTarget(at location: CGPoint, map: Mapping) -> OriginTarget? {
        guard let doc = preview.document else { return nil }
        let displayed = CGPoint(x: map.worldX(location.x), y: map.worldY(location.y))
        let slop = Self.originSnap / map.scale
        // A back program shown in its own (mirrored) frame, as the machine sees it after the flip.
        let backFrame = playback.displayedKind.map { $0.isBackSide && !flipBackView } ?? false

        if let frame = doc.frame {
            let o = backFrame ? frame.backOrigin : frame.frontOrigin
            let r = CGRect(x: -o.x, y: -o.y, width: frame.rect.width, height: frame.rect.height)
            let anchors: [(String, CGPoint, String)] = [
                ("bottomLeft", CGPoint(x: r.minX, y: r.minY), "Lower-left corner"),
                ("bottomRight", CGPoint(x: r.maxX, y: r.minY), "Lower-right corner"),
                ("topLeft", CGPoint(x: r.minX, y: r.maxY), "Upper-left corner"),
                ("topRight", CGPoint(x: r.maxX, y: r.maxY), "Upper-right corner"),
                ("center", CGPoint(x: r.midX, y: r.midY), "Centre")
            ]
            if let hit = anchors.min(by: { hypot($0.1.x - displayed.x, $0.1.y - displayed.y)
                                           < hypot($1.1.x - displayed.x, $1.1.y - displayed.y) }),
               hypot(hit.1.x - displayed.x, hit.1.y - displayed.y) <= slop {
                // A drawing-only project has no board: its corners are just
                // points, so the origin is pinned there rather than following
                // the drawing's extent as it grows.
                if doc.layers.allSatisfy({ $0.id.isCustom }) {
                    let front = hit.1.applying(backFrame ? doc.backToFront : .identity)
                    return OriginTarget(display: hit.1, mode: "custom",
                                        design: doc.designPoint(fromFront: front), label: hit.2)
                }
                return OriginTarget(display: hit.1, mode: hit.0, design: nil, label: hit.2)
            }
        }

        // Into the front programs' frame, where the drill holes are.
        let toFront = backFrame ? doc.backToFront : .identity
        let front = displayed.applying(toFront)
        var best: (distance: CGFloat, hit: CGPoint)?
        for layer in doc.layers where layer.id.isDrill {
            for hit in layer.drillHits {
                let d = hypot(hit.x - front.x, hit.y - front.y)
                if d <= slop, d < (best?.distance ?? .infinity) { best = (d, hit) }
            }
        }
        if let best {
            return OriginTarget(display: best.hit.applying(toFront.inverted()), mode: "custom",
                                design: doc.designPoint(fromFront: best.hit), label: "drill hole")
        }

        // The grid as drawn: lines every half ruler tick, counted from the
        // current X0/Y0 — so the origin moves in whole grid steps.
        var point = displayed
        var label = ""
        if snapToGrid {
            let step = tickStep(scale: map.scale).mm / 2
            point = CGPoint(x: (displayed.x / step).rounded() * step, y: (displayed.y / step).rounded() * step)
            label = "grid"
        }
        return OriginTarget(display: point, mode: "custom",
                            design: doc.designPoint(fromFront: point.applying(toFront)), label: label)
    }

    private func apply(_ target: OriginTarget) {
        if let design = target.design {
            func rounded(_ v: CGFloat) -> String { ParametersStore.format((Double(v) * 1000).rounded() / 1000) }
            params.originX = rounded(design.x)
            params.originY = rounded(design.y)
        }
        params.originMode = target.mode
        params.zeroStart = true
    }

    /// "Set Origin" click: the origin goes where the view was clicked; the
    /// preview regenerates around it.
    private func placeOrigin(at location: CGPoint) {
        playback.placingOrigin = false
        guard let map = mapping(in: canvasSize), map.plot.contains(location),
              let target = originTarget(at: location, map: map) else { return }
        if let token = preview.document?.token { pendingOrigin = (target, token) }
        apply(target)
    }

    @ViewBuilder
    private var originBanner: some View {
        if playback.placingOrigin {
            HStack(spacing: 10) {
                Image(systemName: "scope")
                Text("Click to place X0 Y0 — snaps to corners, centre and drill holes")
                Button("Cancel") { playback.placingOrigin = false }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect()
            .padding(.top, (showRulers ? Self.topGutter : 0) + 10)
        }
    }

    private func drawRank(_ kind: LayerKind) -> Int {
        switch kind {
        case .outline: 0
        case .maskBottom: 1
        case .silkBottom: 2
        case .maskTop: 3
        case .silkTop: 4
        case .back: 5
        case .front: 6
        case .drill(let index, _), .millDrill(let index, _): 7 + index
        case .custom(let ref): 50 + ref.index
        case .test: 100
        }
    }

    // MARK: - Caching

    private func cachedPaths(for doc: PreviewDocument) -> [LayerKind: MappedPaths] {
        if cacheBox.token != doc.token {
            cacheBox.token = doc.token
            var newCache: [LayerKind: MappedPaths] = [:]
            var newBridges: [LayerKind: Path] = [:]
            let bridgeZ = Double(params.zBridge.trimmingCharacters(in: .whitespaces))
            for layer in doc.layers {
                newCache[layer.id] = MappedPaths.build(moves: layer.moves) { move, _ in (move.start, move.end) }
                // Outline bridge crossings: cutting moves that ride exactly at
                // the bridge height while deeper passes run below it.
                if layer.id == .outline, let bridgeZ, bridgeZ < 0 {
                    var bridgePath = Path()
                    for move in layer.moves where move.kind == .cut
                        && abs(move.zStart - bridgeZ) < 1e-6 && abs(move.zEnd - bridgeZ) < 1e-6
                        && (abs(move.end.x - move.start.x) > 1e-9 || abs(move.end.y - move.start.y) > 1e-9) {
                        bridgePath.move(to: move.start)
                        bridgePath.addLine(to: move.end)
                    }
                    if !bridgePath.isEmpty { newBridges[layer.id] = bridgePath }
                }
            }
            cacheBox.paths = newCache
            cacheBox.bridges = newBridges
        }
        return cacheBox.paths
    }

    /// The streamed program's paths, keyed by the job token (= `renderToken`
    /// while a job runs) and built here, inside the draw closure, like the
    /// document cache — never from onChange (see CLAUDE.md).
    private func cachedJobPaths(for job: LiveJob) -> MappedPaths {
        if cacheBox.jobToken != job.token || cacheBox.jobPaths == nil {
            cacheBox.jobToken = job.token
            cacheBox.jobPaths = MappedPaths.build(moves: job.layer.moves) { move, _ in (move.start, move.end) }
        }
        return cacheBox.jobPaths!
    }

    // MARK: - Gestures / controls

    /// One drag gesture serves three jobs; which one is decided from where the
    /// drag started (a ruler band, an existing guide, or open canvas).
    private enum DragMode { case pan, guide, origin, edit, measure }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == nil { dragMode = beginDrag(at: value.startLocation) }
                if dragMode == .guide {
                    updateGuide(to: value.location)
                } else if dragMode == .edit {
                    if layerEditActive { layerEditDragChanged(value) } else { editorDragChanged(value) }
                } else if dragMode == .measure {
                    hover = value.location   // the end follows the pointer
                } else if dragMode == .origin {
                    if let map = mapping(in: canvasSize) { originDrag = originTarget(at: value.location, map: map) }
                } else {
                    if followTool { followTool = false }
                    pan = CGSize(width: pan.width + value.translation.width - lastDrag.width,
                                 height: pan.height + value.translation.height - lastDrag.height)
                    lastDrag = value.translation
                }
            }
            .onEnded { value in
                lastDrag = .zero
                if dragMode == .guide { commitGuide() }
                if dragMode == .edit {
                    if layerEditActive { layerEditDragEnded(value) } else { editorDragEnded(value) }
                }
                if dragMode == .measure { measureDragEnded(at: value.location) }
                if dragMode == .origin {
                    if let target = originDrag {
                        if let token = preview.document?.token { pendingOrigin = (target, token) }
                        apply(target)
                    }
                    originDrag = nil
                }
                dragMode = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                zoomFactor = min(max(zoomFactor * delta, 0.02), 300)
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button { zoomFactor = min(zoomFactor * 1.15, 300) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (scroll wheel over the view also zooms, centered on the cursor)")
            Button { zoomFactor = max(zoomFactor / 1.15, 0.02) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { resetView() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right") }
                .help("Fit the selected program to the view (double-click does the same)")
            Toggle(isOn: $followTool) { Image(systemName: "scope") }
                .toggleStyle(.button)
                .help("Follow the tool head: the view keeps the tool centred while it moves (panning turns this off)")
            Button { toggleMeasuring() } label: {
                Image(systemName: "ruler").foregroundStyle(measuring ? Color.yellow : Color.primary)
            }
            .help("Measure (M): click two points — or drag between them — to read the distance, ΔX, ΔY and angle. Snaps to toolpath corners, drill holes, drawn shapes, the origin, guides and the grid; Shift keeps the line horizontal, vertical or at 45°. Esc clears the measurement, then leaves the tool.")
            Button { playback.placingOrigin.toggle() } label: { Image(systemName: "scope") }
                .help("Set Origin: click a point in the view to make it X0 Y0 for every program. You can also drag the origin marker itself. Both snap to drill holes and to the project's corners and centre.")
                .disabled(preview.document == nil)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}
