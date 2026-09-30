import SwiftUI
import AppKit

/// The tape measure: click (or drag) between two points in the 2D view to
/// read the distance, ΔX, ΔY and angle. Works on every layer — Gerber
/// programs and drawn ones — and snaps to toolpath corners, drill holes,
/// drawn shapes' points, the origin, guides and (with Snap to Grid) the grid.
/// Points are kept in the view's world frame, i.e. the coordinates the
/// rulers show.
extension ToolpathCanvasView {

    struct Measurement {
        var a: CGPoint
        /// Nil while the second point still follows the cursor.
        var b: CGPoint?
    }

    struct MeasureSnap {
        var point: CGPoint
        var label: String?
    }

    func toggleMeasuring() {
        measuring.toggle()
        measurement = nil
        if measuring {
            if playback.placingOrigin { playback.placingOrigin = false }
            canvasFocused = true
        }
    }

    // MARK: - Snapping

    /// The programs currently drawn, with the transform they are drawn under.
    private func shownLayers() -> [(layer: ParsedLayer, transform: CGAffineTransform)] {
        guard let doc = preview.document else { return [] }
        let layers: [ParsedLayer]
        if showAllLayers {
            layers = doc.layers
        } else if editorActive {
            layers = doc.layers.filter { $0.id == editorLayerKind }
        } else {
            layers = selectedLayer(in: doc).map { [$0] } ?? []
        }
        return layers.map { ($0, displayTransform(for: $0.id) ?? .identity) }
    }

    /// Resolves a view location to a world point, snapped to the nearest
    /// feature within a few points of the cursor.
    func measurePoint(at location: CGPoint, map: Mapping, from anchor: CGPoint? = nil) -> MeasureSnap {
        let raw = CGPoint(x: map.worldX(location.x), y: map.worldY(location.y))
        let tolerance = 8 / map.scale

        // Shift: keep the line horizontal, vertical or at 45° from the first point.
        if let anchor, NSEvent.modifierFlags.contains(.shift) {
            let dx = raw.x - anchor.x, dy = raw.y - anchor.y
            let length = hypot(dx, dy)
            guard length > 1e-9 else { return MeasureSnap(point: raw, label: nil) }
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return MeasureSnap(point: CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle)),
                               label: nil)
        }

        var best: (distance: CGFloat, point: CGPoint, label: String)?
        func consider(_ p: CGPoint, _ label: String) {
            // Cheap reject before the square root: most points are far away.
            guard abs(p.x - raw.x) <= tolerance, abs(p.y - raw.y) <= tolerance else { return }
            let d = hypot(p.x - raw.x, p.y - raw.y)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (d, p, label) }
        }

        consider(displayedOrigin, "origin")
        for (layer, transform) in shownLayers() {
            let identity = transform.isIdentity
            for hit in layer.drillHits { consider(identity ? hit : hit.applying(transform), "hole") }
            for move in layer.moves where move.kind != .rapid {
                consider(identity ? move.end : move.end.applying(transform), "path")
            }
        }
        if editorActive {
            let toWorld = editorTransform()
            for shape in editor.displayedShapes {
                for p in shape.snapPoints() { consider(p.applying(toWorld), "point") }
            }
        }
        if let best { return MeasureSnap(point: best.point, label: best.label) }

        var point = raw
        var label: String?
        if snapToGrid {
            let step = tickStep(scale: map.scale).mm / 2
            point = CGPoint(x: (raw.x / step).rounded() * step, y: (raw.y / step).rounded() * step)
            label = "grid"
        }
        if showGuides {
            if let gx = guidesX.min(by: { abs($0 - raw.x) < abs($1 - raw.x) }), abs(gx - raw.x) <= tolerance {
                point.x = gx; label = "guide"
            }
            if let gy = guidesY.min(by: { abs($0 - raw.y) < abs($1 - raw.y) }), abs(gy - raw.y) <= tolerance {
                point.y = gy; label = "guide"
            }
        }
        return MeasureSnap(point: point, label: label)
    }

    // MARK: - Input

    /// First click sets the start, second the end; a third starts over.
    func measureClick(at location: CGPoint) {
        guard let map = mapping(in: canvasSize), map.plot.contains(location) else { return }
        canvasFocused = true
        if let current = measurement, current.b == nil {
            measurement?.b = measurePoint(at: location, map: map, from: current.a).point
        } else {
            measurement = Measurement(a: measurePoint(at: location, map: map).point, b: nil)
        }
    }

    /// Dragging measures from press to release.
    func measureDragBegan(at location: CGPoint, map: Mapping) {
        measurement = Measurement(a: measurePoint(at: location, map: map).point, b: nil)
        canvasFocused = true
    }

    func measureDragEnded(at location: CGPoint) {
        guard let map = mapping(in: canvasSize), let current = measurement else { return }
        let end = measurePoint(at: location, map: map, from: current.a).point
        // A press without real movement is just the first click.
        if hypot(end.x - current.a.x, end.y - current.a.y) * map.scale >= 3 { measurement?.b = end }
    }

    // MARK: - Drawing

    private static let measureColor = Color(red: 1.0, green: 0.8, blue: 0.1)

    func drawMeasurement(_ context: GraphicsContext, map: Mapping) {
        guard measuring else { return }
        var ctx = context
        ctx.clip(to: Path(map.plot))
        let color = Self.measureColor
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: map.viewX(p.x), y: map.viewY(p.y)) }
        func ring(_ snap: MeasureSnap) {
            guard let label = snap.label else { return }
            let v = view(snap.point)
            ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)), with: .color(.green), lineWidth: 1.5)
            ctx.draw(Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.green),
                     at: CGPoint(x: v.x + 9, y: v.y - 9), anchor: .bottomLeading)
        }

        let hovering = hover.flatMap { map.plot.contains($0) ? $0 : nil }
        guard let current = measurement else {
            // Nothing started: show what the first click would snap to.
            if let hovering { ring(measurePoint(at: hovering, map: map)) }
            return
        }

        let end: CGPoint
        if let b = current.b {
            end = b
        } else if let hovering {
            let snap = measurePoint(at: hovering, map: map, from: current.a)
            ring(snap)
            end = snap.point
        } else {
            end = current.a
        }

        let va = view(current.a), vb = view(end)
        var line = Path()
        line.move(to: va)
        line.addLine(to: vb)
        ctx.stroke(line, with: .color(.black.opacity(0.55)), lineWidth: 3)
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: current.b == nil ? [5, 3] : []))
        // ΔX / ΔY legs, faint, when the line is neither horizontal nor vertical.
        if abs(va.x - vb.x) > 6, abs(va.y - vb.y) > 6 {
            var legs = Path()
            legs.move(to: va)
            legs.addLine(to: CGPoint(x: vb.x, y: va.y))
            legs.addLine(to: vb)
            ctx.stroke(legs, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 3]))
        }
        for v in [va, vb] {
            let r: CGFloat = 3.5
            ctx.fill(Path(ellipseIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            ctx.stroke(Path(ellipseIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r)), with: .color(.black.opacity(0.6)), lineWidth: 0.8)
        }

        // Readout at the middle of the line, nudged off it.
        let dx = Double(end.x - current.a.x), dy = Double(end.y - current.a.y)
        let distance = hypot(dx, dy)
        guard distance * Double(map.scale) > 2 else { return }
        let decimals = units.lengthDecimals + 1
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        let title = "\(units.length(distance, decimals: decimals)) \(units.lengthSymbol)"
        let detail = "ΔX \(units.length(abs(dx), decimals: decimals))  ΔY \(units.length(abs(dy), decimals: decimals))  \(String(format: "%.1f", angle))°"
        let width = max(CGFloat(detail.count) * 5.6 + 14, CGFloat(title.count) * 8 + 14)
        let mid = CGPoint(x: (va.x + vb.x) / 2, y: (va.y + vb.y) / 2)
        var rect = CGRect(x: mid.x - width / 2, y: mid.y - 44, width: width, height: 32)
        rect.origin.x = min(max(rect.minX, map.plot.minX + 4), map.plot.maxX - width - 4)
        rect.origin.y = min(max(rect.minY, map.plot.minY + 4), map.plot.maxY - 36)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.black.opacity(0.78)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(color.opacity(0.7)), lineWidth: 1)
        ctx.draw(Text(title).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(color),
                 at: CGPoint(x: rect.midX, y: rect.minY + 10))
        ctx.draw(Text(detail).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.white.opacity(0.85)),
                 at: CGPoint(x: rect.midX, y: rect.minY + 24))
    }

    @ViewBuilder
    var measureBanner: some View {
        if measuring {
            HStack(spacing: 10) {
                Image(systemName: "ruler")
                Text(measurement == nil ? "Click the first point" :
                        (measurement?.b == nil ? "Click the second point — Shift keeps it straight" : "Click to measure again"))
                Button("Done") { toggleMeasuring() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect()
        }
    }
}
