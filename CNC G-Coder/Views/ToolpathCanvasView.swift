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

    /// Display-only: un-mirror back-side programs (back copper, bottom mask) so
    /// they visually align with the front for registration checks. The
    /// generated G-code always stays mirrored, ready for the CNC.
    @AppStorage("previewFlipBackView") private var flipBackView = false

    /// Off: only the selected layer is shown. On: all programs overlaid, with
    /// the selected one highlighted. Origins are normalized per side (see
    /// Pcb2GcodeService.normalizeOrigins), so overlays register exactly; the
    /// back side needs "Un-mirror Back Side" to land on the front.
    @AppStorage("previewShowAllLayers") private var showAllLayers = false

    /// Draw cutting moves as a swath at the real cutter diameter, showing the
    /// material actually removed (not just the tool centerline).
    @AppStorage("previewShowToolWidth") private var showToolWidth = true

    /// Rulers along the top (X) and left (Y) edges of the canvas.
    @AppStorage("previewShowRulers") private var showRulers = true

    /// Guides dragged out of the rulers, stored as world coordinates in
    /// millimetres: `guidesXRaw` holds vertical guides (a fixed X), `guidesYRaw`
    /// horizontal ones (a fixed Y). They are machine positions, so they stay
    /// put through zoom, pan and layer changes — and across launches.
    @AppStorage("previewGuidesX") private var guidesXRaw = ""
    @AppStorage("previewGuidesY") private var guidesYRaw = ""
    @AppStorage("previewShowGuides") private var showGuides = true

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    /// Cursor position in view coordinates, for the ruler crosshair readout.
    @State private var hover: CGPoint?
    /// The guide currently being dragged (pulled from a ruler, or an existing
    /// one being moved); nil when no guide drag is in progress.
    @State private var activeGuide: GuideDrag?
    /// What the in-flight drag is doing — decided from where it started.
    @State private var dragMode: DragMode?
    /// Canvas size, mirrored out of the layout so gesture handlers can map
    /// view points to millimetres the same way `draw` does.
    @State private var canvasSize: CGSize = .zero

    @State private var zoomFactor: CGFloat = 1     // relative to auto-fit
    @State private var pan: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1
    @State private var lastDrag: CGSize = .zero

    private final class CacheBox {
        var token: UUID?
        var paths: [LayerKind: MappedPaths] = [:]
        var bridges: [LayerKind: Path] = [:]
    }
    @State private var cacheBox = CacheBox()

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .clipped()
        .background(Color(nsColor: .underPageBackgroundColor))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        .pointerStyle(pointerStyle)
        .gesture(dragGesture)
        .gesture(magnifyGesture)
        .onContinuousHover { phase in
            guard showRulers else { hover = nil; return }
            switch phase {
            case .active(let point): hover = point
            case .ended: hover = nil
            }
        }
        .onTapGesture(count: 2) { resetView() }
        .onTapGesture { resignTextFieldFocus() }
        // Zoom/pan intentionally survives layer switches; only overlay-mode
        // changes (different framing semantics) reset the view.
        .onChange(of: showAllLayers) { resetView() }
        .onChange(of: flipBackView) { resetView() }
        .overlay { scrollZoomCatcher }
        .overlay(alignment: .topTrailing) { zoomControls }
        .overlay(alignment: .bottomLeading) {
            if preview.document == nil {
                Text("No preview yet — choose a project folder, then Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }

    private func resetView() {
        zoomFactor = 1
        pan = .zero
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

    private func draw(context: GraphicsContext, size: CGSize) {
        guard let doc = preview.document, let map = mapping(in: size) else { return }
        let plot = map.plot
        let focus = map.focus
        let scale = map.scale
        let step = tickStep(scale: scale).mm

        var ctx = context
        ctx.clip(to: Path(plot))   // toolpaths never spill into the ruler bands
        ctx.concatenate(
            CGAffineTransform.identity
                .translatedBy(x: plot.midX + pan.width, y: plot.midY + pan.height)
                .scaledBy(x: scale, y: -scale)
                .translatedBy(x: -focus.midX, y: -focus.midY)
        )

        drawGrid(&ctx, world: map.visibleWorld, scale: scale, step: step)

        let cache = cachedPaths(for: doc)
        let engaged = playback.isEngaged

        if showAllLayers {
            // Overlay all programs; draw order: outline, back, front, drills on top.
            let ordered = doc.layers.sorted { drawRank($0.id) < drawRank($1.id) }
            for layer in ordered {
                guard let paths = cache[layer.id] else { continue }
                var layerCtx = ctx
                if let flip = displayTransform(for: layer.id) { layerCtx.concatenate(flip) }
                if layer.id == playback.selectedLayer {
                    drawSelectedLayer(&layerCtx, layer: layer, paths: paths, engaged: engaged, scale: scale)
                } else {
                    strokeLayer(&layerCtx, layerID: layer.id, paths: paths,
                                cut: paths.cutFull, travel: paths.travelFull,
                                color: layer.id.color, dimming: engaged ? 0.15 : 0.35,
                                hits: layer.drillHits, scale: scale,
                                toolDiameter: layer.toolDiameter)
                }
            }
        } else if let layer = selectedLayer(in: doc), let paths = cache[layer.id] {
            var layerCtx = ctx
            if let flip = displayTransform(for: layer.id) { layerCtx.concatenate(flip) }
            drawSelectedLayer(&layerCtx, layer: layer, paths: paths, engaged: engaged, scale: scale)
        }

        drawToolMarker(&ctx, scale: scale)

        drawGuides(context, map: map)
        if showRulers {
            drawRulers(context, size: size, map: map, step: step)
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

        // Origin crosshair.
        var origin = Path()
        origin.move(to: CGPoint(x: -3, y: 0))
        origin.addLine(to: CGPoint(x: 3, y: 0))
        origin.move(to: CGPoint(x: 0, y: -3))
        origin.addLine(to: CGPoint(x: 0, y: 3))
        ctx.stroke(origin, with: .color(.gray.opacity(0.5)), lineWidth: 1 / scale)
    }

    private func drawToolMarker(_ ctx: inout GraphicsContext, scale: CGFloat) {
        guard let selected = playback.selectedLayer, var position = playback.toolPosition else { return }
        if let flip = displayTransform(for: selected) { position = position.applying(flip) }
        let r = 4 / scale
        var marker = Path()
        marker.addEllipse(in: CGRect(x: position.x - r, y: position.y - r, width: r * 2, height: r * 2))
        marker.move(to: CGPoint(x: position.x - r * 2, y: position.y))
        marker.addLine(to: CGPoint(x: position.x + r * 2, y: position.y))
        marker.move(to: CGPoint(x: position.x, y: position.y - r * 2))
        marker.addLine(to: CGPoint(x: position.x, y: position.y + r * 2))
        ctx.stroke(marker, with: .color(.red), lineWidth: 1.2 / scale)
    }

    // MARK: - Rulers

    /// Gutters reserved for the rulers. The left one holds Y labels, which can
    /// run to four characters ("-100"), so it is the wider of the two.
    static let leftGutter: CGFloat = 34
    static let topGutter: CGFloat = 20

    /// The drawing area: the canvas minus the ruler gutters.
    private func plotRect(in size: CGSize) -> CGRect {
        guard showRulers else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: Self.leftGutter, y: Self.topGutter,
                      width: max(1, size.width - Self.leftGutter),
                      height: max(1, size.height - Self.topGutter))
    }

    /// World (mm) ↔ view (points) mapping for the current framing. Mirrors the
    /// transform applied to the toolpath context, so rulers, grid and the
    /// hover readout can never drift out of step with the drawing.
    private struct Mapping {
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
    private func mapping(in size: CGSize) -> Mapping? {
        guard let doc = preview.document else { return nil }
        let focus = fitBounds(doc)
        let plot = plotRect(in: size)
        guard focus.width > 0 || focus.height > 0, plot.width > 1, plot.height > 1 else { return nil }
        // Auto-fit scale from the real drawing area (canvas minus rulers), every frame.
        let fitScale = 0.9 * min(plot.width / max(focus.width, 0.001),
                                 plot.height / max(focus.height, 0.001))
        return Mapping(plot: plot, pan: pan, focus: focus, scale: fitScale * zoomFactor)
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
    private func tickStep(scale: CGFloat) -> (mm: CGFloat, display: CGFloat) {
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
        guard let hover, map.plot.contains(hover) else { return }
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

    private var guidesX: [CGFloat] { Self.decodeGuides(guidesXRaw) }
    private var guidesY: [CGFloat] { Self.decodeGuides(guidesYRaw) }

    private static func decodeGuides(_ raw: String) -> [CGFloat] {
        raw.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    }

    private static func encodeGuides(_ values: [CGFloat]) -> String {
        values.sorted().map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// Decides what a drag starting at `start` should do.
    private func beginDrag(at start: CGPoint) -> DragMode {
        guard let map = mapping(in: canvasSize) else { return .pan }
        let plot = map.plot

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
        var ctx = context
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

    private func selectedLayer(in doc: PreviewDocument) -> ParsedLayer? {
        doc.layers.first { $0.id == playback.selectedLayer } ?? doc.layers.first
    }

    private func isBackSide(_ kind: LayerKind) -> Bool {
        kind == .back || kind == .maskBottom || kind == .silkBottom
    }

    /// Back-side programs are mirrored; this reflection maps them back onto
    /// the front frame for display. With normalized origins (zeroing on), both
    /// sides span the same [0, W]×[0, H] project rectangle, so the back frame
    /// is the mirror image across its center — exact registration. With raw
    /// frames (zeroing off), the configured mirror axis is the exact inverse
    /// (reflection is an involution: applying it twice is identity).
    private var mirrorReflection: CGAffineTransform {
        guard let document = preview.document else { return .identity }
        if let size = document.projectSize {
            if document.mirrorYAxis {
                return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            } else {
                return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            }
        }
        let axis = CGFloat(document.mirrorAxis)
        if document.mirrorYAxis {
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * axis)
        } else {
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * axis, ty: 0)
        }
    }

    private func displayTransform(for kind: LayerKind) -> CGAffineTransform? {
        flipBackView && isBackSide(kind) ? mirrorReflection : nil
    }

    private func displayBounds(for layer: ParsedLayer) -> CGRect? {
        guard let bounds = layer.cutBounds ?? layer.allBounds else { return nil }
        if let flip = displayTransform(for: layer.id) { return bounds.applying(flip) }
        return bounds
    }

    /// The region the view frames: the selected layer's extent, or the union of
    /// all layers' (display-space) extents when overlaying.
    private func fitBounds(_ doc: PreviewDocument) -> CGRect {
        if !showAllLayers, let layer = selectedLayer(in: doc), let bounds = displayBounds(for: layer) {
            return bounds
        }
        var union = CGRect.null
        for layer in doc.layers {
            if let bounds = displayBounds(for: layer) { union = union.union(bounds) }
        }
        return union.isNull ? doc.bounds : union
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
        case .drill(let index, _): 7 + index
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

    // MARK: - Gestures / controls

    /// One drag gesture serves three jobs; which one is decided from where the
    /// drag started (a ruler band, an existing guide, or open canvas).
    private enum DragMode { case pan, guide }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == nil { dragMode = beginDrag(at: value.startLocation) }
                if dragMode == .guide {
                    updateGuide(to: value.location)
                } else {
                    pan = CGSize(width: pan.width + value.translation.width - lastDrag.width,
                                 height: pan.height + value.translation.height - lastDrag.height)
                    lastDrag = value.translation
                }
            }
            .onEnded { _ in
                lastDrag = .zero
                if dragMode == .guide { commitGuide() }
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
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(10)
        .padding(.top, showRulers ? Self.topGutter : 0)
    }
}
