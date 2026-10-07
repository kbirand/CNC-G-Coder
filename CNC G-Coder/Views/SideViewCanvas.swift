import SwiftUI
import QuartzCore

/// Z cross-section of the selected playback layer, for verifying drill and
/// etch depths. Two modes: orthographic projection (X–Z or Y–Z) and profile
/// (Z against program travel distance). Z is exaggerated independently of the
/// horizontal axis; labeled reference lines mark Z0 and the configured depths.
struct SideViewCanvas: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState

    @AppStorage("sideViewMode") private var mode = "projX"   // projX | projY | profile
    @AppStorage("previewFlipBackView") private var flipBackView = false

    /// Reference-type cache rebuilt lazily inside the draw closure, so it can
    /// never miss a state change (no onChange ordering dependency).
    private final class CacheBox {
        var key = ""
        var paths: MappedPaths?
    }
    @State private var cacheBox = CacheBox()

    private let padX: CGFloat = 72
    private let padTop: CGFloat = 10
    private let padBottom: CGFloat = 16

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        PlaybackTimeReader(clock: playback.clock) { playbackContent }
    }

    /// Everything here moves with playback, so it re-renders on each tick.
    @ViewBuilder
    private var playbackContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Side view")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("", selection: $mode) {
                    Text("X–Z").tag("projX")
                    Text("Y–Z").tag("projY")
                    Text("Profile").tag("profile")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("X–Z / Y–Z: side projection of the program — drill columns and cut depths against the reference lines. Profile: Z over distance traveled — shows the plunge/cut/retract sequence like a timeline.")
                if let layer = playback.layer {
                    Text(layer.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // The machine position is read here, inside the time reader, so
            // Observation re-renders only this subtree on status reports.
            let machine = machineMarkerPosition
            Canvas { context, size in
                let start = CACurrentMediaTime()
                draw(context: context, size: size, machine: machine)
                BodyCounter.time("SideViewCanvas.draw", CACurrentMediaTime() - start)
            }
            .clipped()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// The connected controller's work position, in the shown program's
    /// frame (see ToolpathCanvasView.machineMarkerPosition for the rules).
    private var machineMarkerPosition: MachinePosition? {
        let machine = model.machine
        guard machine.isConnected, let work = machine.status.workPosition,
              let shown = playback.displayedKind else { return nil }
        if let job = playback.job, job.kind.boardSide != shown.boardSide { return nil }
        return work
    }

    // MARK: - Domains and mapping

    private var referenceLines: [(label: String, z: Double, emphasized: Bool)] {
        var lines: [(String, Double, Bool)] = [("Z0", 0, true)]
        func add(_ label: String, _ text: String) {
            if let v = Double(text.trimmingCharacters(in: .whitespaces)) {
                lines.append((label, v, false))
            }
        }
        let p = model.parameters
        switch playback.displayedKind {
        case .front, .back:
            add("zwork", p.zWork)
        case .outline:
            add("zcut", p.zCut)
            add("zbridge", p.zBridge)
        case .drill:
            add("zdrill", p.zDrill)
        case .millDrill:
            add("zmill", p.holeMillDepth)
        case .maskTop, .maskBottom:
            add("etch", p.maskDepth)
        case .silkTop, .silkBottom:
            add("silk", p.silkDepth)
        case .custom(let ref):
            if let layer = model.customLayers.first(where: { $0.id == ref.id }) {
                lines.append(("depth", layer.cutDepth, false))
            }
        case .test:
            break   // patches sweep multiple depths; Z0/zsafe suffice
        case nil:
            add("zwork", p.zWork)
            add("zdrill", p.zDrill)
        }
        add("zsafe", p.zSafe)
        add("zchange", p.zChange)
        return lines
    }

    /// Piecewise Z mapping: everything up to zsafe is linear (the working
    /// range gets most of the height); travel above zsafe (retracts to the
    /// tool-change height) is compressed into a thin band at the top instead
    /// of being cropped away or flattening the cutting depths.
    private struct ZWarp {
        var cap: Double      // zsafe — compression starts here
        var k: Double        // scale factor above the cap (1 = no compression)
        func callAsFunction(_ z: Double) -> Double {
            z <= cap ? z : cap + (z - cap) * k
        }
    }

    private func zWarp(for layer: ParsedLayer) -> ZWarp {
        let refs = referenceLines.map(\.z)
        let zLow = min(layer.zMin, refs.min() ?? 0)
        let cap = max(Double(model.parameters.zSafe.trimmingCharacters(in: .whitespaces)) ?? 3, 0.5)
        let zTop = max(layer.zMax, refs.max() ?? cap)
        guard zTop > cap + 1e-9 else { return ZWarp(cap: cap, k: 1) }
        // The above-zsafe band gets ~18% of the plot height.
        let workingSpan = max(cap - zLow, 0.5)
        return ZWarp(cap: cap, k: (workingSpan * 0.22) / (zTop - cap))
    }

    private func domains(for layer: ParsedLayer) -> (x: ClosedRange<Double>, z: ClosedRange<Double>)? {
        let refs = referenceLines.map(\.z)
        let warp = zWarp(for: layer)
        var zLow = min(layer.zMin, refs.min() ?? 0)
        var zHigh = warp(max(layer.zMax, refs.max() ?? 0, 0.5))
        if zHigh - zLow < 0.5 {
            zHigh += 0.25
            zLow -= 0.25
        }
        let zPad = (zHigh - zLow) * 0.06
        zLow -= zPad
        zHigh += zPad

        let xRange: ClosedRange<Double>
        switch mode {
        case "projY":
            guard let b = bounds(of: layer), b.height > 0 else { return nil }
            xRange = b.minY...b.maxY
        case "profile":
            guard layer.totalDistance > 0 else { return nil }
            xRange = 0...layer.totalDistance
        default:
            guard let b = bounds(of: layer), b.width > 0 else { return nil }
            xRange = b.minX...b.maxX
        }
        return (xRange, zLow...zHigh)
    }

    /// Display-only un-mirroring of back-side programs (matches the top view).
    private var isFlipped: Bool {
        guard flipBackView, let selected = playback.displayedKind else { return false }
        return selected.isBackSide
    }

    /// The back→front mapping in force: a running job's snapshot (so a
    /// preview refresh mid-job cannot move the drawing), else the document's.
    private var backToFront: CGAffineTransform? {
        if let job = playback.job { return job.backToFront }
        return preview.document?.backToFront
    }

    /// Back-side coordinates onto the front frame, exactly as the top view does.
    private func reflected(_ point: CGPoint) -> CGPoint {
        guard isFlipped, let flip = backToFront else { return point }
        return point.applying(flip)
    }

    /// Maps a move into side-view "domain space" (horizontal value, warped z).
    private func mapMove(_ move: ToolpathMove, previousDistance: Double, warp: ZWarp) -> (CGPoint, CGPoint) {
        let start = reflected(move.start)
        let end = reflected(move.end)
        let z0 = warp(move.zStart)
        let z1 = warp(move.zEnd)
        return switch mode {
        case "projY":
            (CGPoint(x: start.y, y: z0), CGPoint(x: end.y, y: z1))
        case "profile":
            (CGPoint(x: previousDistance, y: z0), CGPoint(x: move.cumulativeDistance, y: z1))
        default:
            (CGPoint(x: start.x, y: z0), CGPoint(x: end.x, y: z1))
        }
    }

    private func bounds(of layer: ParsedLayer) -> CGRect? {
        guard let b = layer.allBounds else { return nil }
        guard isFlipped, let flip = backToFront else { return b }
        return b.applying(flip)
    }

    private func viewTransform(domains: (x: ClosedRange<Double>, z: ClosedRange<Double>), size: CGSize) -> CGAffineTransform {
        let xSpan = max(domains.x.upperBound - domains.x.lowerBound, 0.001)
        let zSpan = max(domains.z.upperBound - domains.z.lowerBound, 0.001)
        let sx = (size.width - padX * 2) / xSpan
        let sy = (size.height - padTop - padBottom) / zSpan
        // viewX = padX + (x - xLow) * sx ; viewY = padTop + (zHigh - z) * sy
        return CGAffineTransform.identity
            .translatedBy(x: padX - domains.x.lowerBound * sx, y: padTop + domains.z.upperBound * sy)
            .scaledBy(x: sx, y: -sy)
    }

    /// Cached view-space paths for the current (program, layer, mode, size);
    /// the view transform is baked in so playback frames stroke pre-scaled
    /// paths. `renderToken` is the job's token while one streams, so the
    /// cache follows the sent program rather than the regenerating document.
    private func cachedPaths(layer: ParsedLayer, domains: (x: ClosedRange<Double>, z: ClosedRange<Double>), size: CGSize) -> MappedPaths? {
        let key = "\(playback.renderToken?.uuidString ?? "-")|\(layer.displayName)|\(mode)|\(Int(size.width))x\(Int(size.height))|\(isFlipped)"
        if cacheBox.key != key {
            cacheBox.key = key
            guard size.width > padX * 2, size.height > padTop + padBottom else {
                cacheBox.paths = nil
                return nil
            }
            let t = viewTransform(domains: domains, size: size)
            let warp = zWarp(for: layer)
            cacheBox.paths = MappedPaths.build(moves: layer.moves) { move, prev in
                let (a, b) = mapMove(move, previousDistance: prev, warp: warp)
                return (a.applying(t), b.applying(t))
            }
        }
        return cacheBox.paths
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize, machine: MachinePosition?) {
        guard let layer = playback.layer, let domains = domains(for: layer),
              let cache = cachedPaths(layer: layer, domains: domains, size: size) else {
            context.draw(
                Text("Select a layer in the player below to see its Z profile.")
                    .font(.callout).foregroundStyle(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }

        let t = viewTransform(domains: domains, size: size)
        let warp = zWarp(for: layer)
        let color = layer.id.color

        // Subtle tint over the compressed above-zsafe band.
        if warp.k < 1 {
            let capY = CGPoint(x: 0, y: warp.cap).applying(t).y
            if capY > 0 {
                context.fill(Path(CGRect(x: padX, y: 0, width: size.width - padX - 6, height: capY)),
                             with: .color(.gray.opacity(0.06)))
            }
        }

        // Reference depth lines (labels skip if they would overlap a neighbor).
        var lastLabelY = -CGFloat.greatestFiniteMagnitude
        for ref in referenceLines.sorted(by: { $0.z > $1.z }) {
            let y = CGPoint(x: 0, y: warp(ref.z)).applying(t).y
            guard y >= 0, y <= size.height else { continue }
            var line = Path()
            line.move(to: CGPoint(x: padX, y: y))
            line.addLine(to: CGPoint(x: size.width - 6, y: y))
            if ref.emphasized {
                context.stroke(line, with: .color(.primary.opacity(0.45)), lineWidth: 1)
            } else {
                context.stroke(line, with: .color(.secondary.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            }
            if y - lastLabelY >= 11 {
                lastLabelY = y
                context.draw(
                    Text("\(ref.label) \(UnitSystem.current.length(ref.z))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary),
                    at: CGPoint(x: padX - 4, y: y),
                    anchor: .trailing
                )
            }
        }

        // Toolpath (ghost + prefix while scrubbed, full otherwise).
        // Head travel is always yellow, matching the top view.
        if playback.isEngaged {
            context.stroke(cache.travelFull, with: .color(Color.yellow.opacity(0.12)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            context.stroke(cache.cutFull, with: .color(color.opacity(0.13)), lineWidth: 1.4)
            let prefix = cache.prefix(playback.completedMoves)
            context.stroke(prefix.travel, with: .color(Color.yellow.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            context.stroke(prefix.cut, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        } else {
            context.stroke(cache.travelFull, with: .color(Color.yellow.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
            context.stroke(cache.cutFull, with: .color(color.opacity(0.85)), lineWidth: 1.4)
        }

        // In-progress move (partial) + playback marker, interpolated along the move.
        if playback.displayedKind != nil, let move = playback.currentMove {
            let previousDistance = move.cumulativeDistance - moveLength(move)
            let (mappedStart, mappedEnd) = mapMove(move, previousDistance: previousDistance, warp: warp)
            let fraction = playback.progressIndex == nil ? 1.0 : playback.progressFraction
            let interpolated = CGPoint(
                x: mappedStart.x + (mappedEnd.x - mappedStart.x) * fraction,
                y: mappedStart.y + (mappedEnd.y - mappedStart.y) * fraction
            )
            let p0 = mappedStart.applying(t)
            let p = interpolated.applying(t)

            if playback.progressIndex != nil {
                var partial = Path()
                partial.move(to: p0)
                partial.addLine(to: p)
                switch move.kind {
                case .cut, .plunge:
                    context.stroke(partial, with: .color(color.opacity(0.85)), lineWidth: 1.4)
                case .rapid:
                    context.stroke(partial, with: .color(Color.yellow.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                }
            }

            var marker = Path()
            marker.move(to: CGPoint(x: p.x, y: padTop))
            marker.addLine(to: CGPoint(x: p.x, y: size.height - padBottom))
            context.stroke(marker, with: .color(.red.opacity(0.5)), lineWidth: 0.8)
            var dot = Path()
            dot.addEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(.red))
        }

        // The machine's live Z: a blue line across the plot (and, in the
        // projections, a dot at its X or Y), distinct from the red playback
        // marker that follows the planned position.
        if let machine {
            let zView = CGPoint(x: 0, y: warp(machine.z)).applying(t).y
            let clampedY = min(max(zView, padTop), size.height - padBottom)
            var line = Path()
            line.move(to: CGPoint(x: padX, y: clampedY))
            line.addLine(to: CGPoint(x: size.width - 6, y: clampedY))
            context.stroke(line, with: .color(.blue.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
            context.draw(
                Text("machine \(UnitSystem.current.length(machine.z))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Color.blue),
                at: CGPoint(x: size.width - 8, y: clampedY - 2),
                anchor: .bottomTrailing
            )
            if mode != "profile" {
                let xy = reflected(CGPoint(x: machine.x, y: machine.y))
                let h = mode == "projY" ? xy.y : xy.x
                let p = CGPoint(x: h, y: warp(machine.z)).applying(t)
                if p.x >= padX, p.x <= size.width - 6 {
                    var dot = Path()
                    dot.addEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                    context.stroke(dot, with: .color(.white.opacity(0.8)), lineWidth: 2.5)
                    context.stroke(dot, with: .color(.blue), lineWidth: 1.2)
                }
            }
        }

        // Scale note.
        let xSpan = domains.x.upperBound - domains.x.lowerBound
        let zSpan = domains.z.upperBound - domains.z.lowerBound
        let sx = (size.width - padX * 2) / xSpan
        let sy = (size.height - padTop - padBottom) / zSpan
        if sx > 0 {
            let ratio = sy / sx
            context.draw(
                Text("Z scale ×\(ratio, specifier: ratio >= 10 ? "%.0f" : "%.1f")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary),
                at: CGPoint(x: size.width - 8, y: size.height - 8),
                anchor: .bottomTrailing
            )
        }
    }

    private func moveLength(_ move: ToolpathMove) -> Double {
        let dx = move.end.x - move.start.x
        let dy = move.end.y - move.start.y
        let dz = move.zEnd - move.zStart
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
