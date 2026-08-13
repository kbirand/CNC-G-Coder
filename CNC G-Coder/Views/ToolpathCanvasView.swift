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
    /// back side needs Flip back view to land on the front.
    @AppStorage("previewShowAllLayers") private var showAllLayers = false

    /// Draw cutting moves as a swath at the real cutter diameter, showing the
    /// material actually removed (not just the tool centerline).
    @AppStorage("previewShowToolWidth") private var showToolWidth = true

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
        .gesture(dragGesture)
        .gesture(magnifyGesture)
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
        let cx = size.width / 2
        let cy = size.height / 2
        pan = CGSize(
            width: location.x - cx - (location.x - cx - pan.width) * ratio,
            height: location.y - cy - (location.y - cy - pan.height) * ratio
        )
        zoomFactor = new
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize) {
        guard let doc = preview.document else { return }
        let focus = fitBounds(doc)
        guard focus.width > 0 || focus.height > 0, size.width > 1, size.height > 1 else { return }

        // Auto-fit scale from the real canvas size, every frame.
        let fitScale = 0.9 * min(size.width / max(focus.width, 0.001),
                                 size.height / max(focus.height, 0.001))
        let scale = fitScale * zoomFactor

        var ctx = context
        ctx.concatenate(
            CGAffineTransform.identity
                .translatedBy(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height)
                .scaledBy(x: scale, y: -scale)
                .translatedBy(x: -focus.midX, y: -focus.midY)
        )

        drawGrid(&ctx, docBounds: focus, scale: scale)

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

    private func drawGrid(_ ctx: inout GraphicsContext, docBounds: CGRect, scale: CGFloat) {
        let step: CGFloat = 10   // mm
        let inset = docBounds.insetBy(dx: -step * 2, dy: -step * 2)
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

    // MARK: - Layer selection / mirroring / bounds

    private func selectedLayer(in doc: PreviewDocument) -> ParsedLayer? {
        doc.layers.first { $0.id == playback.selectedLayer } ?? doc.layers.first
    }

    private func isBackSide(_ kind: LayerKind) -> Bool {
        kind == .back || kind == .maskBottom
    }

    /// Back-side programs are mirrored; this reflection maps them back onto
    /// the front frame for display. With normalized origins (zeroing on), both
    /// sides span the same [0, W]×[0, H] project rectangle, so the back frame
    /// is the mirror image across its center — exact registration. With raw
    /// frames (zeroing off), the configured mirror axis is the exact inverse
    /// (reflection is an involution: applying it twice is identity).
    private var mirrorReflection: CGAffineTransform {
        if let size = preview.document?.projectSize {
            if params.mirrorYAxis {
                return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            } else {
                return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            }
        }
        let axis = CGFloat(Double(params.mirrorAxis.trimmingCharacters(in: .whitespaces)) ?? 0)
        if params.mirrorYAxis {
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
        case .maskTop: 2
        case .back: 3
        case .front: 4
        case .drill(let index, _): 5 + index
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

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                pan = CGSize(width: pan.width + value.translation.width - lastDrag.width,
                             height: pan.height + value.translation.height - lastDrag.height)
                lastDrag = value.translation
            }
            .onEnded { _ in lastDrag = .zero }
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
    }
}
