import SwiftUI
import SceneKit
import Combine
import simd

// MARK: - Coordinates and views

/// Machine space is Z-up (X right, Y away from the operator). SceneKit's
/// turntable orbit wants Y-up, so machine (x, y, z) maps to scene (x, z, −y).
nonisolated private func scenePoint(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
    SIMD3(Float(x), Float(z), Float(-y))
}

/// Where the camera looks from, Blender-style.
enum ViewDirection: String, CaseIterable, Identifiable {
    case top, bottom, front, back, right, left, iso
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .front: "Front"
        case .back: "Back"
        case .right: "Right"
        case .left: "Left"
        case .iso: "Isometric"
        }
    }

    /// From the target towards the camera, in machine coordinates.
    var direction: SIMD3<Double> {
        switch self {
        case .top: [0, 0, 1]
        case .bottom: [0, 0, -1]
        case .front: [0, -1, 0]
        case .back: [0, 1, 0]
        case .right: [1, 0, 0]
        case .left: [-1, 0, 0]
        case .iso: simd_normalize(SIMD3(1, -1, 1))
        }
    }

    /// Screen-up for this view, in machine coordinates.
    var up: SIMD3<Double> {
        self == .top || self == .bottom ? [0, 1, 0] : [0, 0, 1]
    }
}

// MARK: - Viewport state (camera + gizmo)

/// Camera state shared by the SceneKit view and the navigation gizmo.
@MainActor
final class Viewport3D: ObservableObject {
    /// One gizmo ball: an axis direction as seen from the camera.
    struct AxisDot: Identifiable {
        let id: String
        let label: String
        let color: Color
        let positive: Bool
        /// Screen offset from the gizmo centre, unit length (y down).
        let x: CGFloat
        let y: CGFloat
        /// Towards the viewer is larger; drawn back to front.
        let depth: CGFloat
        let view: ViewDirection
    }

    @Published private(set) var dots: [AxisDot] = []
    @Published var orthographic = false {
        didSet { applyProjection() }
    }

    weak var view: SCNView?
    let cameraNode: SCNNode = {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 20_000
        camera.fieldOfView = 40
        node.camera = camera
        return node
    }()

    /// What the camera frames, machine coordinates.
    private var center = SIMD3<Double>(0, 0, 0)
    private var radius = 50.0
    private(set) var lastView: ViewDirection = .iso

    /// Frames `bounds` (machine min/max corners) from the current direction.
    func frame(min lo: SIMD3<Double>, max hi: SIMD3<Double>, from view: ViewDirection? = nil, animated: Bool) {
        center = (lo + hi) / 2
        radius = Swift.max(simd_length(hi - lo) / 2, 1)
        snap(view ?? lastView, animated: animated)
    }

    func fit() { snap(lastView, animated: true) }

    func snap(_ direction: ViewDirection, animated: Bool = true) {
        lastView = direction
        let fov = Double(cameraNode.camera?.fieldOfView ?? 40) * .pi / 180
        let distance = radius / sin(fov / 2) * 1.05
        let eye = center + direction.direction * distance
        let target = scenePoint(center.x, center.y, center.z)
        let up = scenePoint(direction.up.x, direction.up.y, direction.up.z)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.simdPosition = scenePoint(eye.x, eye.y, eye.z)
        cameraNode.simdLook(at: target, up: up, localFront: SIMD3(0, 0, -1))
        cameraNode.camera?.orthographicScale = radius * 1.05
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(target)
    }

    private func applyProjection() {
        cameraNode.camera?.usesOrthographicProjection = orthographic
        cameraNode.camera?.orthographicScale = radius * 1.05
    }

    /// Re-projects the six axis directions for the current camera orientation.
    func updateGizmo(orientation q: simd_quatf) {
        let inverse = q.inverse
        let axes: [(String, String, Color, Bool, SIMD3<Double>, ViewDirection)] = [
            ("+x", "X", .red, true, [1, 0, 0], .right),
            ("-x", "", .red, false, [-1, 0, 0], .left),
            ("+y", "Y", .green, true, [0, 1, 0], .back),
            ("-y", "", .green, false, [0, -1, 0], .front),
            ("+z", "Z", .blue, true, [0, 0, 1], .top),
            ("-z", "", .blue, false, [0, 0, -1], .bottom)
        ]
        let new = axes.map { id, label, color, positive, axis, view -> AxisDot in
            let v = inverse.act(scenePoint(axis.x, axis.y, axis.z))
            return AxisDot(id: id, label: label, color: color, positive: positive,
                           x: CGFloat(v.x), y: CGFloat(-v.y), depth: CGFloat(v.z), view: view)
        }
        // Skip republishing sub-pixel changes: this runs every rendered frame.
        if dots.count == new.count,
           zip(dots, new).allSatisfy({ abs($0.x - $1.x) < 0.002 && abs($0.y - $1.y) < 0.002 }) { return }
        dots = new
    }
}

// MARK: - SwiftUI view

/// The 3D preview: toolpaths as lines above/in a translucent board, orbit /
/// pan / zoom like any 3D app, and a Blender-style navigation gizmo.
struct Toolpath3DView: View {
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    /// The bit that cuts the selected program, drawn at real size.
    var tool: ToolGeometry?
    @StateObject private var viewport = Viewport3D()

    @AppStorage("previewShowAllLayers") private var showAllLayers = false
    @AppStorage("preview3DShowRapids") private var showRapids = true

    var body: some View {
        SceneRepresentable(preview: preview, playback: playback, clock: playback.clock, viewport: viewport,
                           showAllLayers: showAllLayers, showRapids: showRapids, tool: tool)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    NavigationGizmo(viewport: viewport)
                    viewButtons
                }
                .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if preview.document == nil {
                    Text("No preview yet — choose a project folder, then Refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
    }

    private var viewButtons: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(ViewDirection.allCases) { view in
                    Button(view.title) { viewport.snap(view) }
                }
            } label: {
                Image(systemName: "cube")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Jump to a standard view: top, bottom, front, back, left, right or isometric. Clicking the gizmo's balls does the same.")
            Button { viewport.snap(.iso) } label: { Text("Iso").font(.caption.weight(.semibold)) }
                .help("Isometric view")
            Button { viewport.fit() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right") }
                .help("Frame everything again, keeping the view direction")
            Toggle(isOn: $viewport.orthographic) {
                Image(systemName: viewport.orthographic ? "square" : "perspective")
            }
            .toggleStyle(.button)
            .help(viewport.orthographic ? "Orthographic — switch to perspective" : "Perspective — switch to orthographic")
            Toggle(isOn: $showRapids) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            }
            .toggleStyle(.button)
            .help("Show head travel (rapid moves, yellow)")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}

/// Blender-style axis gizmo: the balls turn with the camera; click one to
/// look along that axis (Z → top, −Z → bottom, −Y → front…).
private struct NavigationGizmo: View {
    @ObservedObject var viewport: Viewport3D
    @State private var hovering = false

    private let size: CGFloat = 96
    private var reach: CGFloat { size / 2 - 12 }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(hovering ? 0.10 : 0.0))
            ForEach(viewport.dots.filter(\.positive)) { dot in
                Path { path in
                    path.move(to: CGPoint(x: size / 2, y: size / 2))
                    path.addLine(to: point(dot))
                }
                .stroke(dot.color.opacity(0.9), lineWidth: 2)
            }
            ForEach(viewport.dots.sorted { $0.depth < $1.depth }) { dot in
                Button {
                    viewport.snap(dot.view)
                } label: {
                    ZStack {
                        Circle()
                            .fill(dot.positive ? dot.color : dot.color.opacity(hovering ? 0.35 : 0.22))
                        Circle()
                            .strokeBorder(dot.color.opacity(dot.positive ? 0 : 0.8), lineWidth: 1.5)
                        if dot.positive {
                            Text(dot.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                    }
                    .frame(width: dot.positive ? 18 : 15, height: dot.positive ? 18 : 15)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(point(dot))
                .help("View from \(dot.view.title.lowercased())")
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func point(_ dot: Viewport3D.AxisDot) -> CGPoint {
        CGPoint(x: size / 2 + dot.x * reach, y: size / 2 + dot.y * reach)
    }
}

// MARK: - Navigation

/// SCNView with explicit pan and zoom. SceneKit's built-in camera control
/// orbits well but has no dependable pan and scrolls unpredictably, so:
/// plain drag orbits (SceneKit), right- or middle-drag pans, and the scroll
/// wheel / two-finger scroll / pinch zooms.
final class NavigableSCNView: SCNView {

    /// Moves camera and orbit target together, so the scene follows the pointer.
    private func pan(dx: CGFloat, dy: CGFloat) {
        guard let camera = pointOfView, bounds.height > 0 else { return }
        let target = SIMD3<Float>(defaultCameraController.target)
        let worldPerPoint: Float
        if camera.camera?.usesOrthographicProjection == true {
            worldPerPoint = Float(camera.camera?.orthographicScale ?? 1) * 2 / Float(bounds.height)
        } else {
            let distance = simd_length(camera.simdWorldPosition - target)
            let fov = Float(camera.camera?.fieldOfView ?? 40) * .pi / 180
            worldPerPoint = distance * 2 * tan(fov / 2) / Float(bounds.height)
        }
        let shift = (-Float(dx) * camera.simdWorldRight + Float(dy) * camera.simdWorldUp) * worldPerPoint
        camera.simdWorldPosition += shift
        defaultCameraController.target = SCNVector3(target + shift)
    }

    /// Zooms towards the orbit centre: `factor` < 1 moves in.
    private func zoom(by factor: Float) {
        guard let camera = pointOfView, factor.isFinite, factor > 0 else { return }
        if let lens = camera.camera, lens.usesOrthographicProjection {
            lens.orthographicScale = min(max(lens.orthographicScale * Double(factor), 0.2), 5_000)
            return
        }
        let target = SIMD3<Float>(defaultCameraController.target)
        let offset = camera.simdWorldPosition - target
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        let newDistance = min(max(distance * factor, 0.5), 10_000)
        camera.simdWorldPosition = target + offset / distance * newDistance
    }

    /// Pointer position at the previous drag event (view coordinates, y up).
    private var lastPanPoint: CGPoint?

    private func beginPan(_ event: NSEvent) {
        lastPanPoint = convert(event.locationInWindow, from: nil)
    }

    private func continuePan(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let last = lastPanPoint {
            // NSView y grows upwards; pan() takes screen-style deltas (y down).
            pan(dx: point.x - last.x, dy: last.y - point.y)
        }
        lastPanPoint = point
    }

    override func rightMouseDown(with event: NSEvent) { beginPan(event) }   // no context menu
    override func rightMouseDragged(with event: NSEvent) { continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { lastPanPoint = nil }
    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { lastPanPoint = nil }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report precise (pixel) deltas, mouse wheels line deltas.
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
        zoom(by: Float(exp(-step)))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: Float(1 / (1 + event.magnification)))
    }
}

// MARK: - SceneKit bridge

private struct SceneRepresentable: NSViewRepresentable {
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    /// Playback position: only the scene updates per tick, not the overlays.
    @ObservedObject var clock: PlaybackClock
    let viewport: Viewport3D
    let showAllLayers: Bool
    let showRapids: Bool
    let tool: ToolGeometry?

    func makeCoordinator() -> Coordinator { Coordinator(viewport: viewport) }

    func makeNSView(context: Context) -> SCNView {
        let view = NavigableSCNView(frame: .zero)
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .underPageBackgroundColor
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.worldUp = SCNVector3(0, 1, 0)
        view.defaultCameraController.inertiaEnabled = true
        scene.rootNode.addChildNode(viewport.cameraNode)
        view.pointOfView = viewport.cameraNode
        view.delegate = context.coordinator
        viewport.view = view
        context.coordinator.view = view
        context.coordinator.attach(to: scene)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.update(document: preview.document, playback: playback,
                                   showAllLayers: showAllLayers, showRapids: showRapids, tool: tool)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private let viewport: Viewport3D
        weak var view: SCNView?
        private let content = SCNNode()
        /// Follows the tool tip; `spinner` holds the bit model and turns while playing.
        private let toolMarker = SCNNode()
        private let spinner = SCNNode()
        private var markerTool: ToolGeometry?
        private var contentKey = ""
        /// What the camera was last fitted to: the program shown and overlay mode.
        private var framedSelection: String?
        /// The selected program's bright path; its shader reveals it up to the
        /// playback position (see `revealShader`).
        private var progressMaterial: SCNMaterial?
        private var progressNode: SCNNode?
        private var ghostNode: SCNNode?
        private var markerTransform: (CGPoint, Double) -> SIMD3<Float> = { p, z in scenePoint(p.x, p.y, z) }
        private var lastOrientation: simd_quatf?

        static let boardThickness = 1.6

        init(viewport: Viewport3D) {
            self.viewport = viewport
        }

        func attach(to scene: SCNScene) {
            scene.rootNode.addChildNode(content)
            scene.rootNode.addChildNode(toolMarker)
            toolMarker.addChildNode(spinner)
            toolMarker.isHidden = true
        }

        // Camera moves (orbit, animation) happen on the render thread; the
        // gizmo follows from here.
        nonisolated func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let q = renderer.pointOfView?.presentation.simdWorldOrientation else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let last = self.lastOrientation, simd_length(last.vector - q.vector) < 1e-5 { return }
                self.lastOrientation = q
                self.viewport.updateGizmo(orientation: q)
            }
        }

        @MainActor
        func update(document: PreviewDocument?, playback: PlaybackState, showAllLayers: Bool, showRapids: Bool,
                    tool: ToolGeometry?) {
            if tool != markerTool {
                markerTool = tool
                spinner.childNodes.forEach { $0.removeFromParentNode() }
                spinner.addChildNode(ToolModel.node(tool ?? ToolGeometry(kind: .endMill, diameter: 1)))
            }
            let selected = playback.selectedLayer
            let key = "\(document?.token.uuidString ?? "-")|\(String(describing: selected))|\(showAllLayers)|\(showRapids)"
            if key != contentKey {
                contentKey = key
                rebuild(document: document, selected: selected, showAllLayers: showAllLayers, showRapids: showRapids)
            }
            updatePlayback(playback)
        }

        // MARK: Scene content

        @MainActor
        private func rebuild(document: PreviewDocument?, selected: LayerKind?, showAllLayers: Bool, showRapids: Bool) {
            content.childNodes.forEach { $0.removeFromParentNode() }
            progressMaterial = nil
            progressNode = nil
            ghostNode = nil
            guard let document else {
                toolMarker.isHidden = true
                return
            }
            let t = Self.boardThickness
            let layer = document.layers.first { $0.id == selected } ?? document.layers.first

            // Overlaid, every program sits on the physical board: back-side
            // programs un-mirrored onto the underside (the board was flipped
            // to cut them). A single program is shown as it is machined.
            let physical = showAllLayers
            func transform(for kind: LayerKind) -> (CGPoint, Double) -> SIMD3<Float> {
                if physical, kind.isBackSide {
                    let flip = document.backToFront
                    return { p, z in
                        let q = p.applying(flip)
                        return scenePoint(q.x, q.y, -t - z)
                    }
                }
                return { p, z in scenePoint(p.x, p.y, z) }
            }

            var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
            func include(_ v: SIMD3<Float>) {
                let m = SIMD3<Double>(Double(v.x), Double(-v.z), Double(v.y))   // back to machine
                lo = simd_min(lo, m)
                hi = simd_max(hi, m)
            }

            let shown = showAllLayers ? document.layers : (layer.map { [$0] } ?? [])
            for program in shown {
                let isSelected = program.id == layer?.id
                let map = transform(for: program.id)
                let color = NSColor(program.id.color).usingColorSpace(.sRGB) ?? .systemBlue
                if isSelected {
                    // Ghost of the whole program + the completed part on top.
                    let ghost = Self.lineNode(program.moves, color: color, alpha: 0.15, rapids: showRapids, map: map)
                    let bright = Self.lineNode(program.moves, color: color, alpha: 1, rapids: showRapids, map: map,
                                               reveal: true)
                    content.addChildNode(ghost.node)
                    content.addChildNode(bright.node)
                    ghostNode = ghost.node
                    progressNode = bright.node
                    progressMaterial = bright.node.geometry?.firstMaterial
                    markerTransform = map
                } else {
                    content.addChildNode(Self.lineNode(program.moves, color: color, alpha: 0.35,
                                                       rapids: false, map: map).node)
                }
                for move in program.moves where move.kind != .rapid {
                    include(map(move.start, move.zStart))
                    include(map(move.end, move.zEnd))
                }
            }

            // The board: from the cutout (pulled in by half the cutter), else
            // the extent of what is shown.
            if var rect = ArtworkExport.boardRect(in: document) ?? document.layers.compactMap({ $0.cutBounds }).reduce(nil, { $0?.union($1) ?? $1 }) {
                if !physical, let kind = layer?.id, kind.isBackSide {
                    rect = rect.applying(document.backToFront.inverted())   // the board as seen for this program
                }
                content.addChildNode(Self.boardNode(rect: rect, thickness: t))
                include(scenePoint(rect.minX, rect.minY, -t))
                include(scenePoint(rect.maxX, rect.maxY, 0))
            }
            content.addChildNode(Self.originNode(size: 6))

            // Fit when a different program (or overlay mode) is shown, like the
            // 2D view; a refresh of the same program keeps the camera put.
            let selection = "\(String(describing: layer?.id))|\(showAllLayers)"
            if lo.x <= hi.x, framedSelection != selection {
                let first = framedSelection == nil
                framedSelection = selection
                viewport.frame(min: lo, max: hi, from: first ? .iso : nil, animated: !first)
            }
        }

        @MainActor
        private func updatePlayback(_ playback: PlaybackState) {
            guard let material = progressMaterial else {
                toolMarker.isHidden = true
                return
            }
            // Reveal every finished move, and the move in progress up to the
            // tool — the line grows under the bit, exactly as in 2D.
            let engaged = playback.isEngaged
            let move = engaged ? Float(playback.progressIndex ?? playback.moveCount) : .greatestFiniteMagnitude
            let fraction = engaged ? Float(playback.progressFraction) : 1
            material.setValue(NSNumber(value: move), forKey: "revealMove")
            material.setValue(NSNumber(value: fraction), forKey: "revealFraction")
            ghostNode?.isHidden = !engaged
            if let p = playback.toolPosition, let z = playback.toolZ, engaged || playback.currentTime > 0 {
                toolMarker.isHidden = false
                toolMarker.simdPosition = markerTransform(p, z)
                // A back-side program shown on the underside points its bit up.
                let tip = markerTransform(p, z - 1)
                toolMarker.simdOrientation = tip.y > toolMarker.simdPosition.y
                    ? simd_quatf(angle: .pi, axis: [1, 0, 0]) : simd_quatf(angle: 0, axis: [1, 0, 0])
            } else {
                toolMarker.isHidden = true
            }
            // The spindle turns while the program plays.
            // Rendering runs continuously only while it spins (actions need frames).
            let spinning = playback.isPlaying && !toolMarker.isHidden
            if spinning {
                if spinner.action(forKey: "spin") == nil { spinner.runAction(ToolModel.spinAction(), forKey: "spin") }
            } else {
                spinner.removeAction(forKey: "spin")
            }
            if view?.isPlaying != spinning { view?.isPlaying = spinning }
        }

        // MARK: Geometry

        /// Hides what the tool has not reached yet. Every vertex carries its
        /// move number and its position along that move (0 at the start, 1 at
        /// the end, interpolated along the line); fragments past the current
        /// move, or past the tool within it, are discarded. Updating the two
        /// uniforms per tick is all playback costs.
        nonisolated private static let revealShader: [SCNShaderModifierEntryPoint: String] = [
            .geometry: """
            #pragma varyings
            float2 revealPos;
            #pragma body
            out.revealPos = _geometry.texcoords[0];
            """,
            .fragment: """
            #pragma arguments
            float revealMove;
            float revealFraction;
            #pragma body
            float2 p = in.revealPos;
            if (p.x > revealMove + 0.5 || (fabs(p.x - revealMove) < 0.5 && p.y > revealFraction)) {
                discard_fragment();
            }
            """
        ]

        nonisolated private static let whitePixel: NSImage = {
            let image = NSImage(size: NSSize(width: 1, height: 1))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            image.unlockFocus()
            return image
        }()

        /// All moves as line segments, in program order.
        nonisolated private static func lineNode(_ moves: [ToolpathMove], color: NSColor, alpha: CGFloat, rapids: Bool,
                                                 map: (CGPoint, Double) -> SIMD3<Float>,
                                                 reveal: Bool = false) -> (node: SCNNode, element: SCNGeometryElement) {
            var vertices: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            vertices.reserveCapacity(moves.count * 2)
            colors.reserveCapacity(moves.count * 2)
            // SceneKit ignores vertex-colour alpha: dimming is the material's
            // transparency (below), and hidden travel is simply left out.
            let cut = SIMD4<Float>(Float(color.redComponent), Float(color.greenComponent),
                                   Float(color.blueComponent), 1)
            let travel = SIMD4<Float>(0.55, 0.47, 0.08, 1)
            var progress: [SIMD2<Float>] = []
            if reveal { progress.reserveCapacity(moves.count * 2) }
            for (index, move) in moves.enumerated() {
                if move.kind == .rapid, !rapids { continue }
                let c = move.kind == .rapid ? travel : cut
                vertices.append(map(move.start, move.zStart))
                vertices.append(map(move.end, move.zEnd))
                colors.append(c)
                colors.append(c)
                if reveal {
                    progress.append(SIMD2(Float(index), 0))
                    progress.append(SIMD2(Float(index), 1))
                }
            }
            let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let stride = MemoryLayout<SIMD3<Float>>.stride
            let positions = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count,
                                              usesFloatComponents: true, componentsPerVector: 3,
                                              bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let indices = (0..<UInt32(vertices.count)).map { $0 }
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            var sources = [positions, colorSource]
            if reveal {
                let data = progress.withUnsafeBufferPointer { Data(buffer: $0) }
                sources.append(SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: progress.count,
                                                 usesFloatComponents: true, componentsPerVector: 2,
                                                 bytesPerComponent: 4, dataOffset: 0,
                                                 dataStride: MemoryLayout<SIMD2<Float>>.stride))
            }
            let geometry = SCNGeometry(sources: sources, elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.white
            material.isDoubleSided = true
            material.writesToDepthBuffer = alpha >= 1
            material.blendMode = .alpha
            material.transparency = alpha
            if reveal {
                // SceneKit only feeds a geometry's texture coordinates to the
                // shaders when the material samples a texture; a plain white
                // one keeps the colours as they are.
                material.diffuse.contents = Self.whitePixel
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .repeat
                material.shaderModifiers = revealShader
                material.setValue(NSNumber(value: Float.greatestFiniteMagnitude), forKey: "revealMove")
                material.setValue(NSNumber(value: Float(1)), forKey: "revealFraction")
            }
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = alpha >= 1 ? 10 : 5
            return (node, element)
        }

        /// A translucent FR4 slab, top face at Z0.
        nonisolated private static func boardNode(rect: CGRect, thickness: Double) -> SCNNode {
            let box = SCNBox(width: rect.width, height: thickness, length: rect.height, chamferRadius: 0)
            let fr4 = SCNMaterial()
            fr4.diffuse.contents = NSColor(red: 0.16, green: 0.42, blue: 0.24, alpha: 1)
            fr4.transparency = 0.55
            fr4.transparencyMode = .dualLayer
            fr4.writesToDepthBuffer = false
            fr4.isDoubleSided = true
            box.materials = [fr4]
            let node = SCNNode(geometry: box)
            node.simdPosition = scenePoint(rect.midX, rect.midY, -thickness / 2)
            node.renderingOrder = 1
            return node
        }

        /// X/Y/Z arrows at the origin, like the 2D marker.
        nonisolated private static func originNode(size: Double) -> SCNNode {
            let node = SCNNode()
            for (axis, color) in [(SIMD3<Double>(1, 0, 0), NSColor.systemRed),
                                  (SIMD3<Double>(0, 1, 0), NSColor.systemGreen),
                                  (SIMD3<Double>(0, 0, 1), NSColor.systemBlue)] {
                let end = axis * size
                let vertices = [SIMD3<Float>(0, 0, 0), scenePoint(end.x, end.y, end.z)]
                let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
                let source = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: 2, usesFloatComponents: true,
                                               componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                               dataStride: MemoryLayout<SIMD3<Float>>.stride)
                let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: [UInt32(0), 1], primitiveType: .line)])
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = color
                geometry.materials = [material]
                node.addChildNode(SCNNode(geometry: geometry))
            }
            return node
        }

    }
}
