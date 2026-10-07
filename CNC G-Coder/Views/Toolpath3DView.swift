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
        reclaimPointOfView()
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
        // A standard view always comes back with the chosen projection and
        // the standard lens, whatever the camera controller did meanwhile.
        cameraNode.camera?.usesOrthographicProjection = orthographic
        cameraNode.camera?.fieldOfView = 40
        SCNTransaction.commit()
        view?.defaultCameraController.target = SCNVector3(target)
    }

    /// SceneKit's camera control renders through its own copy of the camera
    /// once the user orbits, so moving `cameraNode` alone changes nothing on
    /// screen. Take the view back, starting from where the user left it.
    private func reclaimPointOfView() {
        guard let view else { return }
        view.defaultCameraController.stopInertia()
        guard let live = view.pointOfView, live !== cameraNode else { return }
        cameraNode.simdWorldTransform = live.presentation.simdWorldTransform
        if let lens = live.camera { cameraNode.camera?.orthographicScale = lens.orthographicScale }
        view.pointOfView = cameraNode
    }

    private func applyProjection() {
        reclaimPointOfView()
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
    /// The connected controller, for the live machine marker (nil = none).
    var machine: MachineController? = nil
    /// The height map to draw over the board (the shown side's, live while
    /// probing — see `AppModel.heightMapOverlay`), nil for none.
    var heightMap: HeightMapOverlay? = nil
    /// Z stretch of that surface, so a 0.1 mm warp is visible.
    var heightMapExaggeration: Double = 10
    /// Drill programs as holes (View Options → Drill Holes).
    var showHoles: Bool = true
    var showPaths: Bool = true
    /// Material removal painted on the board faces (View Options → Material Removal).
    var showCuts: Bool = true
    @StateObject private var viewport = Viewport3D()
    @AppStorage(HeightMapSurface.interpolationXKey) private var heightMapLinesX = HeightMapSurface.interpolationDefault
    @AppStorage(HeightMapSurface.interpolationYKey) private var heightMapLinesY = HeightMapSurface.interpolationDefault
    @AppStorage("previewShowMachineTravel") private var showMachineTravel = true

    /// The machine's travel box (work coordinates): the bed at the bottom of
    /// the Z travel and the top of the travel, while connected and known.
    private var machineTravel: (rect: CGRect, bottom: Double, top: Double)? {
        guard showMachineTravel, let machine, machine.isConnected, let rect = machine.workTravelRect else { return nil }
        return (rect, machine.workTravelBottomZ ?? 0, machine.workTravelTopZ ?? 0)
    }

    @AppStorage("previewShowAllLayers") private var showAllLayers = false
    @AppStorage("preview3DShowRapids") private var showRapids = true
    @AppStorage("previewFollowTool") private var followTool = false

    /// The bit model is the machine: connected, a position has been
    /// reported, and the board side on the machine is the one shown (the
    /// same rules as the 2D marker). Only coarse flags are read here, never
    /// the position itself — the scene samples `machine.motion` per frame,
    /// and reading the position in the body would re-render the view on
    /// every status report.
    private var machineLive: Bool {
        guard let machine, machine.isConnected, machine.positionKnown,
              let shown = playback.displayedKind else { return false }
        if let job = playback.job, job.kind.boardSide != shown.boardSide { return false }
        return true
    }

    /// The spindle is reported running (S > 0, or the accessory flags say
    /// CW/CCW): the tool model spins at the machine position then.
    private var spindleOn: Bool {
        guard let machine, machine.isConnected else { return false }
        return machine.spindleRunning
    }

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        BodyCounter.count("Toolpath3DView.body")
        return SceneRepresentable(preview: preview, playback: playback, clock: playback.clock, viewport: viewport,
                           showAllLayers: showAllLayers, showRapids: showRapids, tool: tool,
                           machineLive: machineLive, spindleOn: spindleOn,
                           heightMap: heightMap, heightMapExaggeration: heightMapExaggeration,
                           heightMapLines: (heightMapLinesX, heightMapLinesY), machineTravel: machineTravel,
                           followTool: followTool, motion: machine?.isConnected == true ? machine?.motion : nil, showHoles: showHoles, showCuts: showCuts, showPaths: showPaths)
            // View tools at the top left, the navigation gizmo at the top right.
            .overlay(alignment: .topLeading) {
                viewButtons
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                NavigationGizmo(viewport: viewport)
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
            Button { viewport.fit() } label: { Image(systemName: "arrow.down.left.and.arrow.up.right") }
                .help("Frame everything again, keeping the view direction")
            Toggle(isOn: $followTool) {
                Image(systemName: "scope")
            }
            .toggleStyle(.button)
            .help("Follow the tool head: the view keeps the bit centred while it moves (dragging the view turns this off)")
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

    /// Projected depth (0…1) of the surface grabbed at drag start, so the
    /// scene point under the pointer follows it exactly at any zoom.
    private var panDepth: CGFloat?

    private func beginPan(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastPanPoint = point
        // Grab what is under the pointer; fall back to the orbit target.
        if let hit = hitTest(point, options: [.ignoreHiddenNodes: true, .firstFoundOnly: true]).first {
            panDepth = CGFloat(projectPoint(hit.worldCoordinates).z)
        } else {
            panDepth = CGFloat(projectPoint(defaultCameraController.target).z)
        }
    }

    private func continuePan(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastPanPoint = point }
        guard let last = lastPanPoint, let camera = pointOfView else { return }
        guard let depth = panDepth else {
            pan(dx: point.x - last.x, dy: last.y - point.y)
            return
        }
        // Unproject both pointer positions at the grabbed depth; the camera
        // and its orbit target move by the opposite of the world shift.
        let before = unprojectPoint(SCNVector3(last.x, last.y, depth))
        let after = unprojectPoint(SCNVector3(point.x, point.y, depth))
        let shift = SIMD3<Float>(Float(before.x - after.x), Float(before.y - after.y), Float(before.z - after.z))
        guard shift.x.isFinite, shift.y.isFinite, shift.z.isFinite else { return }
        defaultCameraController.stopInertia()
        camera.simdWorldPosition += shift
        let target = SIMD3<Float>(defaultCameraController.target)
        defaultCameraController.target = SCNVector3(target + shift)
    }

    override func mouseDragged(with event: NSEvent) {
        // Orbiting by hand ends tool following.
        if UserDefaults.standard.bool(forKey: "previewFollowTool") { UserDefaults.standard.set(false, forKey: "previewFollowTool") }
        super.mouseDragged(with: event)
    }
    override func rightMouseDown(with event: NSEvent) { beginPan(event) }   // no context menu
    override func rightMouseDragged(with event: NSEvent) { continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { lastPanPoint = nil; panDepth = nil }
    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { lastPanPoint = nil; panDepth = nil }

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
    let machineLive: Bool
    let spindleOn: Bool
    let heightMap: HeightMapOverlay?
    let heightMapExaggeration: Double
    let heightMapLines: (Int, Int)
    let machineTravel: (rect: CGRect, bottom: Double, top: Double)?
    let followTool: Bool
    /// The live machine motion (connected); the bit samples it per frame.
    let motion: MotionInterpolator?
    let showHoles: Bool
    let showCuts: Bool
    let showPaths: Bool

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
                                   showAllLayers: showAllLayers, showRapids: showRapids, tool: tool,
                                   machineLive: machineLive, spindleOn: spindleOn,
                                   heightMap: heightMap, heightMapExaggeration: heightMapExaggeration,
                                   heightMapLines: heightMapLines, machineTravel: machineTravel,
                                   followTool: followTool, motion: motion, showHoles: showHoles, showCuts: showCuts, showPaths: showPaths)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private let viewport: Viewport3D
        weak var view: SCNView?
        private let content = SCNNode()
        /// Follows the tool tip; `spinner` holds the bit model and turns while playing.
        private let toolMarker = SCNNode()
        private let spinner = SCNNode()
        /// The machine's live position (blue), beside the planned tool marker.
        private let machineMarker = SCNNode()
        private var markerTool: ToolGeometry?
        private var contentKey = ""
        /// What the camera was last fitted to: the program shown and overlay mode.
        private var framedSelection: String?
        /// The selected program's bright path; its shader reveals it up to the
        /// playback position (see `revealShader`).
        private var progressMaterial: SCNMaterial?
        private var progressNode: SCNNode?
        private var ghostNode: SCNNode?
        /// Line nodes of the other overlaid programs (hidden with Toolpath Lines).
        private var overlayPathNodes: [SCNNode] = []
        private var pathsVisible = true
        /// The selected drill program's holes (cylinders under `holesNode`,
        /// pivot at the top face), revealed with playback.
        private var holeNodes: [(node: SCNNode, hole: DrillHole, drawnDepth: Double)] = []
        /// Material removal on the board faces (see BoardSurfaceTexture):
        /// the copper-up face and the underside, their slab materials, and
        /// the program painted progressively (the selected one).
        private var frontSurface: BoardSurfaceTexture?
        private var backSurface: BoardSurfaceTexture?
        private var boardTopMaterial: SCNMaterial?
        private var boardBottomMaterial: SCNMaterial?
        private var progressiveSurface: (surface: BoardSurfaceTexture, layer: ParsedLayer,
                                         transform: CGAffineTransform, token: String)?
        /// The faces' textures, updated in place (`BoardSurfaceTexture.upload`).
        private var topTexture: (any MTLTexture)?
        private var bottomTexture: (any MTLTexture)?
        private let metalDevice: (any MTLDevice)? = MTLCreateSystemDefaultDevice()
        /// Frames rendered since the last FPS print (`-debugDumpViews`).
        private var frameCount = 0
        private var snapshotTaken = false
        private var snapshotSince: TimeInterval = 0
        private var frameCountSince: TimeInterval = 0
        /// `-debugDumpViews`: where the per-tick time goes.
        private let profiler = TickProfiler()
        private var markerTransform: (CGPoint, Double) -> SIMD3<Float> = { p, z in scenePoint(p.x, p.y, z) } {
            didSet { liveTransform = markerTransform }
        }
        /// The live machine motion while connected; the bit is placed from it
        /// once per screen refresh by `displayLink` (main thread — SceneKit's
        /// scene graph must only be touched from one side).
        private var liveMotion: MotionInterpolator?
        private var liveTransform: (CGPoint, Double) -> SIMD3<Float> = { p, z in scenePoint(p.x, p.y, z) }
        /// True while the bit model is the machine (connected, not simulating).
        private var liveBit = false {
            didSet { if liveBit != oldValue { liveBit ? startDisplayLink() : stopDisplayLink() } }
        }
        private var displayLink: CADisplayLink?
        /// Follow tool head: the camera tracks the live bit each tick too.
        private var followLive = false
        /// The playback whose clock the reveal follows, for the per-frame tick.
        private weak var livePlayback: PlaybackState?
        private var lastRevealTime = -1.0

        private func startDisplayLink() {
            guard displayLink == nil, let view else { return }
            let link = view.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// One screen refresh: the bit goes where the machine is now.
        @objc private func displayTick(_ link: CADisplayLink) {
            guard liveBit, let motion = liveMotion,
                  let p = motion.position(at: ProcessInfo.processInfo.systemUptime) else { return }
            // The reveal (channel, holes, copper) follows the job clock,
            // which the streamer advances from the same interpolator once
            // per frame: apply it here, in the frame, rather than waiting
            // for SwiftUI's transaction to reach `updateNSView`.
            if let playback = livePlayback, playback.job != nil, playback.currentTime != lastRevealTime {
                lastRevealTime = playback.currentTime
                _ = updatePlayback(playback)   // also parks the bit at the planned point; placed below
            }
            let at = liveTransform(CGPoint(x: p.x, y: p.y), p.z)
            guard simd_length(at - toolMarker.simdPosition) > 1e-5 else { return }
            place(p)
            if followLive { follow(at) }
            if UserDefaults.standard.bool(forKey: "debugMotionLog") {
                print(String(format: "[marker] %.4f %.4f %.4f %.4f", ProcessInfo.processInfo.systemUptime, p.x, p.y, p.z))
            }
        }
        private var lastOrientation: simd_quatf?

        nonisolated static let boardThickness = 1.6

        init(viewport: Viewport3D) {
            self.viewport = viewport
        }

        func attach(to scene: SCNScene) {
            scene.rootNode.addChildNode(content)
            scene.rootNode.addChildNode(toolMarker)
            toolMarker.addChildNode(spinner)
            toolMarker.isHidden = true
            if machineMarker.childNodes.isEmpty { machineMarker.addChildNode(Self.machineMarkerNode()) }
            scene.rootNode.addChildNode(machineMarker)
            machineMarker.isHidden = true
        }

        // Camera moves (orbit, animation) happen on the render thread; the
        // gizmo follows from here.
        nonisolated func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let q = renderer.pointOfView?.presentation.simdWorldOrientation else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.countFrame(at: time)
                if let last = self.lastOrientation, simd_length(last.vector - q.vector) < 1e-5 { return }
                self.lastOrientation = q
                self.viewport.updateGizmo(orientation: q)
            }
        }

        @MainActor
        func update(document: PreviewDocument?, playback: PlaybackState, showAllLayers: Bool, showRapids: Bool,
                    tool: ToolGeometry?, machineLive: Bool, spindleOn: Bool,
                    heightMap: HeightMapOverlay?, heightMapExaggeration: Double, heightMapLines: (Int, Int),
                    machineTravel: (rect: CGRect, bottom: Double, top: Double)?, followTool: Bool = false,
                    motion: MotionInterpolator? = nil,
                    showHoles: Bool = true, showCuts: Bool = true, showPaths: Bool = true) {
            profiler.beginUpdate()
            defer { profiler.endUpdate() }
            pathsVisible = showPaths
            liveMotion = motion
            followLive = followTool
            livePlayback = playback
            if tool != markerTool {
                markerTool = tool
                spinner.childNodes.forEach { $0.removeFromParentNode() }
                spinner.addChildNode(ToolModel.node(tool ?? ToolGeometry(kind: .endMill, diameter: 1)))
            }
            // `renderToken` is the job's token while one streams (the sent
            // program's geometry), else the document's; the document token is
            // kept too so overlay layers follow a refresh.
            let selected = playback.displayedKind
            // The map's identity: side, probe date, points in, geometry — so
            // the surface follows a probe run point by point.
            let mapKey = heightMap.map {
                "\($0.side.rawValue)|\($0.map.probedAt?.timeIntervalSinceReferenceDate ?? 0)|\($0.map.probedCount)|\($0.map.rect)|\($0.map.nx)x\($0.map.ny)|\(heightMapExaggeration)|\(heightMapLines.0)x\(heightMapLines.1)|\($0.frame)"
            } ?? "-"
            let travelKey = machineTravel.map { "\($0.rect)|\($0.bottom)|\($0.top)" } ?? "-"
            let key = "\(playback.renderToken?.uuidString ?? "-")|\(document?.token.uuidString ?? "-")|\(String(describing: selected))|\(showAllLayers)|\(showRapids)|\(mapKey)|\(travelKey)|\(showHoles)|\(showCuts)"
            if key != contentKey {
                contentKey = key
                if profiler.enabled { print("[debug] 3D rebuild (key changed)") }
                rebuild(document: document, program: playback.layer, selected: selected,
                        backToFront: playback.job?.backToFront ?? document?.backToFront,
                        showAllLayers: showAllLayers, showRapids: showRapids,
                        heightMap: heightMap, heightMapExaggeration: heightMapExaggeration,
                        heightMapLines: heightMapLines, machineTravel: machineTravel, showHoles: showHoles, showCuts: showCuts)
            }
            let playbackSpinning = updatePlayback(playback)
            profiler.measure("markers") {
                // A live job puts the bit on the machine itself; the simulation drives it otherwise.
            let simulating = playback.job == nil && (playback.isPlaying || playback.currentTime > 0)
                if simulating {
                    liveBit = false
                    showMachineSphere(machineLive ? liveMotion?.position(at: ProcessInfo.processInfo.systemUptime) : nil)
                    updateSpinner(spinning: playbackSpinning)
                } else {
                    let machineSpinning = updateMachineMarker(live: machineLive, spindleOn: spindleOn)
                    updateSpinner(spinning: machineLive ? machineSpinning : playbackSpinning)
                }
            }
            profiler.measure("follow") {
                if followTool, !toolMarker.isHidden { follow(toolMarker.simdPosition) }
            }
        }

        // MARK: Scene content

        /// `program` is the selected program's geometry — the job's parsed
        /// text while one streams (it may have no document layer at all).
        @MainActor
        private func rebuild(document: PreviewDocument?, program: ParsedLayer?, selected: LayerKind?,
                             backToFront: CGAffineTransform?, showAllLayers: Bool, showRapids: Bool,
                             heightMap: HeightMapOverlay?, heightMapExaggeration: Double, heightMapLines: (Int, Int),
                             machineTravel: (rect: CGRect, bottom: Double, top: Double)?, showHoles: Bool = true,
                             showCuts: Bool = true) {
            content.childNodes.forEach { $0.removeFromParentNode() }
            progressMaterial = nil
            progressNode = nil
            ghostNode = nil
            overlayPathNodes = []
            holeNodes = []
            frontSurface = nil
            backSurface = nil
            boardTopMaterial = nil
            boardBottomMaterial = nil
            progressiveSurface = nil
            topTexture = nil
            bottomTexture = nil
            let layer = program ?? document?.layers.first { $0.id == selected } ?? document?.layers.first
            guard document != nil || layer != nil else {
                toolMarker.isHidden = true
                return
            }
            let t = Self.boardThickness

            // Overlaid, every program sits on the physical board: back-side
            // programs un-mirrored onto the underside (the board was flipped
            // to cut them). A single program is shown as it is machined.
            let physical = showAllLayers
            func transform(for kind: LayerKind) -> (CGPoint, Double) -> SIMD3<Float> {
                if physical, kind.isBackSide, let flip = backToFront {
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

            var topPrograms: [(layer: ParsedLayer, transform: CGAffineTransform)] = []
            var bottomPrograms: [(layer: ParsedLayer, transform: CGAffineTransform)] = []
            var progressivePlan: (layer: ParsedLayer, underside: Bool, transform: CGAffineTransform)?

            // Overlaid: the document's other programs, then the selected one
            // (the job's own geometry replaces its document layer).
            let others = (document?.layers ?? []).filter { $0.id != layer?.id }
            let shown = showAllLayers ? others + (layer.map { [$0] } ?? []) : (layer.map { [$0] } ?? [])
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
                    let overlay = Self.lineNode(program.moves, color: color, alpha: 0.35,
                                                rapids: false, map: map).node
                    overlay.isHidden = !pathsVisible
                    overlayPathNodes.append(overlay)
                    content.addChildNode(overlay)
                }
                for move in program.moves where move.kind != .rapid {
                    include(map(move.start, move.zStart))
                    include(map(move.end, move.zEnd))
                }
                // Drill holes: cylinders from the board top down, under the
                // same per-side transform as the paths.
                if showHoles, !program.drillHoles.isEmpty {
                    let holesNode = SCNNode()
                    holesNode.name = "holes-\(program.id.fileSlug)"
                    for (index, hole) in program.drillHoles.enumerated() {
                        let node = Self.holeNode(hole, index: index, map: map)
                        holesNode.addChildNode(node)
                        if isSelected { holeNodes.append((node, hole, min(hole.depth, Self.drawnHoleDepth))) }
                    }
                    content.addChildNode(holesNode)
                }
                // The grooves: the removed area per depth as one region
                // (union of all slots), extruded; the copper mask reveals it.
                if showCuts, !program.id.isDrill {
                    let onUnderside = physical && program.id.isBackSide && backToFront != nil
                    if let groove = GrooveMesh.build(layer: program, planar: onUnderside ? backToFront! : .identity,
                                                     underside: onUnderside, thickness: t) {
                        groove.node.name = "grooves-\(program.id.fileSlug)"
                        content.addChildNode(groove.node)
                        if UserDefaults.standard.bool(forKey: "debugDumpViews") {
                            print(String(format: "[debug] grooves %@: %d moves → %d depth bins, %d rings (%d vertices), ~%d triangles (estimate); union %.1f ms, shape creation %.1f ms (tessellated lazily by SceneKit)",
                                         program.id.fileSlug as NSString, program.moves.count, groove.bins, groove.rings,
                                         groove.ringVertices, groove.triangles, groove.unionTime * 1000, groove.tessellationTime * 1000))
                        }
                    }
                }
                // Which board face this program cuts, and in which frame it
                // is painted there (back programs un-mirrored onto the
                // underside when overlaid; as machined otherwise).
                let onUnderside = physical && program.id.isBackSide && backToFront != nil
                let paintTransform = onUnderside ? backToFront! : .identity
                if isSelected {
                    progressivePlan = (program, onUnderside, paintTransform)
                } else if onUnderside {
                    bottomPrograms.append((program, paintTransform))
                } else {
                    topPrograms.append((program, paintTransform))
                }
            }

            // The board: from the cutout (pulled in by half the cutter), else
            // the extent of what is shown.
            let shownBounds = shown.compactMap { $0.cutBounds }.reduce(CGRect?.none) { $0?.union($1) ?? $1 }
            if var rect = document.flatMap({ ArtworkExport.boardRect(in: $0) })
                ?? document?.layers.compactMap({ $0.cutBounds }).reduce(CGRect?.none, { $0?.union($1) ?? $1 })
                ?? shownBounds {
                if !physical, let kind = layer?.id, kind.isBackSide, let flip = backToFront {
                    rect = rect.applying(flip.inverted())   // the board as seen for this program
                }
                let board = Self.boardNode(rect: rect, thickness: t, textured: showCuts)
                content.addChildNode(board.node)
                include(scenePoint(rect.minX, rect.minY, -t))
                include(scenePoint(rect.maxX, rect.maxY, 0))
                if showCuts {
                    boardTopMaterial = board.top
                    boardBottomMaterial = board.bottom
                    frontSurface = BoardSurfaceTexture(rect: rect)
                    backSurface = bottomPrograms.isEmpty && progressivePlan?.underside != true ? nil : BoardSurfaceTexture(rect: rect)
                    frontSurface?.setStatic(topPrograms)
                    backSurface?.setStatic(bottomPrograms)
                    if let plan = progressivePlan, let surface = plan.underside ? backSurface : frontSurface {
                        let token = "\(plan.layer.fileURL.path)|\(plan.layer.moves.count)|\(contentKey)"
                        progressiveSurface = (surface, plan.layer, plan.transform, token)
                    }
                    // One texture per face, handed to the material once; from
                    // here on only the painted rectangle is copied into it.
                    if let device = metalDevice {
                        if let surface = frontSurface, let material = board.top, let texture = surface.makeTexture(device: device) {
                            topTexture = texture
                            material.diffuse.contents = texture
                            material.transparent.contents = texture
                        }
                        if let surface = backSurface, let material = board.bottom, let texture = surface.makeTexture(device: device) {
                            bottomTexture = texture
                            material.diffuse.contents = texture
                            material.transparent.contents = texture
                        }
                    }
                    uploadSurfaces(throttled: false)
                    if UserDefaults.standard.bool(forKey: "debugDumpViews"), let texture = topTexture {
                        // Read a corner pixel and the centre pixel back from the GPU texture (B G R A).
                        for (x, y) in [(5, 5), (texture.width / 2, texture.height / 2)] {
                            var px = [UInt8](repeating: 0, count: 4)
                            texture.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                            print("[debug] mask texel (\(x),\(y)) BGRA = \(px)  format \(texture.pixelFormat.rawValue) \(texture.width)×\(texture.height)")
                        }
                        if let m = board.top {
                            print("[debug] top material: transparencyMode \(m.transparencyMode.rawValue) transparency \(m.transparency) blend \(m.blendMode.rawValue) diffuse \(type(of: m.diffuse.contents as Any)) transparent \(type(of: m.transparent.contents as Any)) contentsTransform \(m.diffuse.contentsTransform)")
                        }
                    }
                }
            }
            content.addChildNode(Self.originNode(size: 6))

            // The height map's wireframe, in the shown program's frame (on the
            // underside with an overlaid back-side program, like its paths).
            if let heightMap {
                let toScene = transform(for: layer?.id ?? .front)
                let frame = heightMap.frame
                content.addChildNode(Self.heightMapNode(heightMap.map, exaggeration: heightMapExaggeration,
                                                        lines: heightMapLines, map: { p, z in toScene(p.applying(frame), z) }))
            }
            // The machine's travel box, as Candle draws its bounds: the bed
            // (bottom of the Z travel) as a dashed outline, the top outline
            // fainter, and the four vertical edges (not part of the framing).
            if let machineTravel {
                let map = transform(for: layer?.id ?? .front)
                if UserDefaults.standard.bool(forKey: "debugDumpViews") {
                    let v = map(CGPoint(x: machineTravel.rect.minX, y: machineTravel.rect.minY), machineTravel.bottom)
                    print("[debug] travel box: rect \(machineTravel.rect) bottom \(machineTravel.bottom) top \(machineTravel.top) → scene corner \(v)")
                }
                content.addChildNode(Self.travelNode(rect: machineTravel.rect, z: machineTravel.bottom, map: map))
                let top = Self.travelNode(rect: machineTravel.rect, z: machineTravel.top, map: map)
                top.geometry?.materials.first?.transparency = 0.35
                content.addChildNode(top)
                content.addChildNode(Self.travelEdgesNode(rect: machineTravel.rect, bottom: machineTravel.bottom,
                                                          top: machineTravel.top, map: map))
            }

            // Fit when a different program (or overlay mode) is shown, like the
            // 2D view; a refresh of the same program keeps the camera put.
            let selection = "\(String(describing: layer?.id))|\(showAllLayers)"
            if lo.x <= hi.x, framedSelection != selection {
                let first = framedSelection == nil
                framedSelection = selection
                viewport.frame(min: lo, max: hi, from: first ? .iso : nil, animated: !first)
            }
        }

        /// Places the tool model at the playback position; returns whether
        /// the spindle should turn (the program is playing).
        @MainActor
        @discardableResult
        private func updatePlayback(_ playback: PlaybackState) -> Bool {
            profiler.measure("holes") { updateHoles(playback) }
            updateSurfaces(playback)
            guard let material = progressMaterial else {
                toolMarker.isHidden = true
                return false
            }
            // Reveal every finished move, and the move in progress up to the
            // tool — the line grows under the bit, exactly as in 2D.
            let engaged = playback.isEngaged
            let move = engaged ? Float(playback.progressIndex ?? playback.moveCount) : .greatestFiniteMagnitude
            let fraction = engaged ? Float(playback.progressFraction) : 1
            material.setValue(NSNumber(value: move), forKey: "revealMove")
            material.setValue(NSNumber(value: fraction), forKey: "revealFraction")
            ghostNode?.isHidden = !engaged || !pathsVisible
            progressNode?.isHidden = !pathsVisible
            for node in overlayPathNodes where node.isHidden != !pathsVisible { node.isHidden = !pathsVisible }
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
            return playback.isPlaying && !toolMarker.isHidden
        }

        /// Holes appear as the bit plunges: finished holes at full depth, the
        /// one being drilled as deep as the bit is now (scaled about its top
        /// face), the rest hidden. Nothing engaged (no playback, no job): the
        /// finished board. One pass per tick; no geometry is rebuilt.
        @MainActor
        private func updateHoles(_ playback: PlaybackState) {
            guard !holeNodes.isEmpty else { return }
            let engaged = playback.isEngaged
            guard engaged, let index = playback.progressIndex else {
                for (node, _, _) in holeNodes {
                    node.isHidden = false
                    node.simdScale = SIMD3(1, 1, 1)
                }
                return
            }
            let toolZ = playback.toolZ ?? 0
            for (node, hole, drawnDepth) in holeNodes {
                if hole.lastMoveIndex < index {
                    node.isHidden = false
                    node.simdScale = SIMD3(1, 1, 1)
                } else if hole.moveIndex <= index {
                    let depth = min(max(0, -toolZ), drawnDepth)
                    let fraction = drawnDepth > 1e-9 ? Float(depth / drawnDepth) : 1
                    node.isHidden = fraction < 1e-3
                    node.simdScale = SIMD3(1, max(fraction, 1e-3), 1)
                } else {
                    node.isHidden = true
                }
            }
        }

        /// Paints the selected program onto its board face as far as playback
        /// (or the live job) has come — only the delta per tick — and hands
        /// the faces their new images (throttled while playing).
        @MainActor
        private func updateSurfaces(_ playback: PlaybackState) {
            guard let p = progressiveSurface else { return }
            let engaged = playback.isEngaged
            let completed = engaged ? playback.completedMoves : p.layer.moves.count
            let fraction = engaged ? playback.progressFraction : 0
            profiler.measure("maskPaint") {
                p.surface.paintProgressive(layer: p.layer, token: p.token, transform: p.transform,
                                           completed: completed, fraction: fraction)
            }
            uploadSurfaces(throttled: playback.isPlaying || playback.job != nil)
        }

        @MainActor
        private func uploadSurfaces(throttled: Bool) {
            if let surface = frontSurface, let texture = topTexture, surface.needsUpload {
                profiler.measure("maskUpload") { surface.upload(to: texture, throttled: throttled) }
            }
            if let surface = backSurface, let texture = bottomTexture, surface.needsUpload {
                profiler.measure("maskUpload") { surface.upload(to: texture, throttled: throttled) }
            }
        }

        /// `-debugDumpViews`: the rendering rate, once every 5 s.
        @MainActor
        private func countFrame(at time: TimeInterval) {
            frameCount += 1
            // `-debugMotionLog 1`: the bit's scene position every frame.
            if UserDefaults.standard.bool(forKey: "debugMotionLog"), !toolMarker.isHidden {
                let p = toolMarker.presentation.simdPosition
                print(String(format: "[motion] %.4f %.4f %.4f %.4f", time, p.x, p.y, p.z))
            }
            // `-debugSnapshot3D /path.png` writes the rendered view ~8 s after
            // the first frame (an offscreen render, nothing of the screen).
            if !snapshotTaken, let path = UserDefaults.standard.string(forKey: "debugSnapshot3D") {
                if snapshotSince == 0 { snapshotSince = time }
                let after = max(UserDefaults.standard.double(forKey: "debugSnapshot3DAfter"), 8)
                if time - snapshotSince > after, let view {
                    snapshotTaken = true
                    // `-debugSnapshot3DClose 1`: frame the bit from close by.
                    if UserDefaults.standard.bool(forKey: "debugSnapshot3DClose"), !toolMarker.isHidden, let camera = view.pointOfView {
                        let tip = toolMarker.simdPosition
                        camera.simdPosition = tip + SIMD3<Float>(4, 5, 6)
                        camera.simdLook(at: tip, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))
                        view.defaultCameraController.target = SCNVector3(tip)
                    }
                    let image = view.snapshot()
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        print("[debug] 3D snapshot written to \(path) (\(Int(image.size.width))×\(Int(image.size.height)))")
                    }
                }
            }
            if frameCountSince == 0 { frameCountSince = time; return }
            let elapsed = time - frameCountSince
            guard elapsed >= 5 else { return }
            if UserDefaults.standard.bool(forKey: "debugDumpViews") {
                print(String(format: "[debug] 3D render: %.1f fps over %.1f s", Double(frameCount - 1) / elapsed, elapsed))
                profiler.report()
            }
            frameCount = 1
            frameCountSince = time
        }

        /// Keeps the bit centred: the orbit target moves to the tool and the
        /// camera moves by the same amount, so direction and distance stay.
        @MainActor
        private func follow(_ position: SIMD3<Float>) {
            guard let view, let camera = view.pointOfView else { return }
            let target = SIMD3<Float>(view.defaultCameraController.target)
            let delta = position - target
            guard simd_length(delta) > 1e-4 else { return }
            view.defaultCameraController.stopInertia()
            camera.simdWorldPosition += delta
            view.defaultCameraController.target = SCNVector3(position)
        }

        /// While a simulation plays, the machine is the small blue sphere
        /// and the bit model stays with playback.
        @MainActor
        private func showMachineSphere(_ position: MachinePosition?) {
            guard let position else { machineMarker.isHidden = true; return }
            machineMarker.isHidden = false
            machineMarker.simdPosition = markerTransform(CGPoint(x: position.x, y: position.y), position.z)
        }

        /// Connected: the tool model follows the machine's reported position
        /// (as in Candle) through the same mapping as the planned marker, so
        /// it lands on the underside for an overlaid back-side program too;
        /// the small blue marker is redundant then. Returns whether the
        /// spindle should turn (the machine reports it running).
        @MainActor
        @discardableResult
        private func updateMachineMarker(live: Bool, spindleOn: Bool) -> Bool {
            machineMarker.isHidden = true
            guard live, let motion = liveMotion else { liveBit = false; return false }
            toolMarker.isHidden = false
            liveBit = true   // the display link places it every frame from here on
            if let p = motion.position(at: ProcessInfo.processInfo.systemUptime) { place(p) }
            return spindleOn
        }

        /// Puts the bit at a machine work position (the mapping of the shown program).
        @MainActor
        private func place(_ p: MachinePosition) {
            let at = liveTransform(CGPoint(x: p.x, y: p.y), p.z)
            toolMarker.simdPosition = at
            let tip = liveTransform(CGPoint(x: p.x, y: p.y), p.z - 1)
            toolMarker.simdOrientation = tip.y > at.y ? simd_quatf(angle: .pi, axis: [1, 0, 0]) : simd_quatf(angle: 0, axis: [1, 0, 0])
        }

        /// The spindle animation. Rendering runs continuously only while it
        /// spins (actions need frames).
        @MainActor
        private func updateSpinner(spinning: Bool) {
            if spinning {
                if spinner.action(forKey: "spin") == nil { spinner.runAction(ToolModel.spinAction(), forKey: "spin") }
            } else {
                spinner.removeAction(forKey: "spin")
            }
            let continuous = spinning || liveBit   // a live bit needs a frame every frame
            if view?.isPlaying != continuous { view?.isPlaying = continuous }
        }

        /// A small blue sphere with a crosshair: the machine, as opposed to
        /// the bit model that follows the planned program.
        nonisolated private static func machineMarkerNode() -> SCNNode {
            let node = SCNNode()
            let sphere = SCNSphere(radius: 0.6)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.systemBlue
            sphere.materials = [material]
            node.addChildNode(SCNNode(geometry: sphere))
            let arm = 3.0
            let vertices: [SIMD3<Float>] = [
                scenePoint(-arm, 0, 0), scenePoint(arm, 0, 0),
                scenePoint(0, -arm, 0), scenePoint(0, arm, 0),
                scenePoint(0, 0, -arm), scenePoint(0, 0, arm)
            ]
            let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let source = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: vertices.count,
                                           usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                           dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let element = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .line)
            let lines = SCNGeometry(sources: [source], elements: [element])
            let lineMaterial = SCNMaterial()
            lineMaterial.lightingModel = .constant
            lineMaterial.diffuse.contents = NSColor.systemBlue
            lines.materials = [lineMaterial]
            node.addChildNode(SCNNode(geometry: lines))
            node.renderingOrder = 3
            return node
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

        /// The board face as a cut-out: where the mask is transparent the
        /// fragment is discarded, so it neither draws nor writes depth and
        /// the grooves and holes beneath show through at any rendering order.
        nonisolated private static let cutoutShader: [SCNShaderModifierEntryPoint: String] = [
            .fragment: """
            #pragma body
            if (_surface.diffuse.a < 0.5) { discard_fragment(); }
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

        /// The height map as Candle's wireframe interpolation grid: line
        /// primitives with vertex colours (rainbow by height, the neutral
        /// colour where nothing is probed), flat at Z 0 over unprobed cells,
        /// Z stretched by `exaggeration`; plus the border.
        nonisolated private static func heightMapNode(_ heightMap: HeightMap, exaggeration: Double, lines: (Int, Int),
                                                      map: (CGPoint, Double) -> SIMD3<Float>) -> SCNNode {
            let node = SCNNode()
            let range = HeightMapSurface.range(heightMap)
            let coloured = HeightMapSurface.hasSpread(range)
            var vertices: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ rgb: SIMD3<Float>) {
                vertices.append(a); vertices.append(b)
                colors.append(SIMD4(rgb.x, rgb.y, rgb.z, 1)); colors.append(SIMD4(rgb.x, rgb.y, rgb.z, 1))
            }
            func height(_ p: CGPoint) -> Double {
                (HeightMapSurface.displayZ(heightMap, x: p.x, y: p.y) ?? 0) * exaggeration
            }
            for segment in HeightMapSurface.wireframe(heightMap, linesX: lines.0, linesY: lines.1) {
                let rgb = coloured && segment.z != nil
                    ? HeightMapSurface.rgb(unit: HeightMapSurface.unit(segment.z!, in: range!)) : HeightMapSurface.neutralRGB
                add(map(segment.a, height(segment.a)), map(segment.b, height(segment.b)), rgb)
            }
            // The border, on the surface.
            let r = heightMap.rect
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                add(map(a, height(a)), map(b, height(b)), HeightMapSurface.neutralRGB)
            }
            guard !vertices.isEmpty else { return node }
            let stride = MemoryLayout<SIMD3<Float>>.stride
            let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let positions = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count,
                                              usesFloatComponents: true, componentsPerVector: 3,
                                              bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let element = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [positions, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.white
            material.isDoubleSided = true
            material.blendMode = .alpha
            material.transparency = 0.85
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            let mesh = SCNNode(geometry: geometry)
            mesh.renderingOrder = 4
            node.addChildNode(mesh)
            return node
        }

        /// The bed outline as dashes (SceneKit draws no dashed lines: 5 mm
        /// segments with 3 mm gaps along each edge), grey, at `z`.
        nonisolated private static func travelNode(rect: CGRect, z: Double,
                                                   map: (CGPoint, Double) -> SIMD3<Float>) -> SCNNode {
            var vertices: [SIMD3<Float>] = []
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            let dash = 5.0, gap = 3.0
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { continue }
                var s = 0.0
                while s < length {
                    let e = min(s + dash, length)
                    let pa = CGPoint(x: a.x + (b.x - a.x) * s / length, y: a.y + (b.y - a.y) * s / length)
                    let pb = CGPoint(x: a.x + (b.x - a.x) * e / length, y: a.y + (b.y - a.y) * e / length)
                    vertices.append(map(pa, z))
                    vertices.append(map(pb, z))
                    s += dash + gap
                }
            }
            let node = SCNNode()
            guard !vertices.isEmpty else { return node }
            let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let source = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: vertices.count,
                                           usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                           dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let element = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.systemGray
            material.blendMode = .alpha
            material.transparency = 0.8
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            node.geometry = geometry
            node.renderingOrder = 2
            return node
        }

        /// The four vertical edges of the travel box, faint.
        nonisolated private static func travelEdgesNode(rect: CGRect, bottom: Double, top: Double,
                                                        map: (CGPoint, Double) -> SIMD3<Float>) -> SCNNode {
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            var vertices: [SIMD3<Float>] = []
            for c in corners {
                vertices.append(map(c, bottom))
                vertices.append(map(c, top))
            }
            let node = SCNNode()
            let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let source = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: vertices.count,
                                           usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                           dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
            let element = SCNGeometryElement(indices: (0..<UInt32(vertices.count)).map { $0 }, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = NSColor.systemGray
            material.blendMode = .alpha
            material.transparency = 0.3
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            node.geometry = geometry
            node.renderingOrder = 2
            return node
        }

        /// A hole: a dark, lit cylinder of the bit's diameter and the drilling
        /// depth, its pivot at the top face so the node sits at Z0 and scaling
        /// its height keeps the top in place. On the underside (an overlaid
        /// back-side program) it points up, like the bit.
        /// How far a hole is drawn into the slab: through the board plus a
        /// little, whatever the program's plunge depth (a 30 mm plunge is
        /// still a hole in a 1.6 mm board, not a rod).
        nonisolated static let drawnHoleDepth = boardThickness + 0.6

        nonisolated private static func holeNode(_ hole: DrillHole, index: Int,
                                                 map: (CGPoint, Double) -> SIMD3<Float>) -> SCNNode {
            let depth = max(min(hole.depth, drawnHoleDepth), 0.01)
            let cylinder = SCNCylinder(radius: max(hole.diameter, 0.05) / 2, height: depth)
            cylinder.radialSegmentCount = 24
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = NSColor(white: 0.07, alpha: 1)
            material.specular.contents = NSColor(white: 0.35, alpha: 1)
            material.shininess = 0.4
            cylinder.materials = [material]
            let node = SCNNode(geometry: cylinder)
            node.name = "hole-\(index)"
            // SCNCylinder is centred on its node and runs along local Y
            // (= machine Z in the scene): move the pivot to the top face.
            node.pivot = SCNMatrix4MakeTranslation(0, CGFloat(depth / 2), 0)
            let top = map(hole.center, 0)
            node.simdPosition = top
            let below = map(hole.center, -1)
            if below.y > top.y { node.simdOrientation = simd_quatf(angle: .pi, axis: [1, 0, 0]) }
            node.renderingOrder = 2
            return node
        }

        /// A translucent FR4 slab, top face at Z0. Textured, the top (+Y,
        /// SCNBox material index 4) and bottom (index 5) faces get their own
        /// materials for the board surface images, mapped so world X/Y land
        /// where they are on the slab; the sides stay FR4 green.
        nonisolated private static func boardNode(rect: CGRect, thickness: Double, textured: Bool)
            -> (node: SCNNode, top: SCNMaterial?, bottom: SCNMaterial?) {
            let box = SCNBox(width: rect.width, height: thickness, length: rect.height, chamferRadius: 0)
            func fr4() -> SCNMaterial {
                let m = SCNMaterial()
                m.diffuse.contents = NSColor(red: 0.16, green: 0.42, blue: 0.24, alpha: 1)
                m.transparency = textured ? 0.85 : 0.55
                m.transparencyMode = .dualLayer
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                return m
            }
            guard textured else {
                box.materials = [fr4()]
                let node = SCNNode(geometry: box)
                node.simdPosition = scenePoint(rect.midX, rect.midY, -thickness / 2)
                node.renderingOrder = 1
                return (node, nil, nil)
            }
            func face(top: Bool) -> SCNMaterial {
                let m = SCNMaterial()
                m.lightingModel = .blinn
                m.diffuse.contents = NSColor(red: 0.72, green: 0.45, blue: 0.2, alpha: 1)   // copper until painted
                m.diffuse.wrapS = .clamp
                m.diffuse.wrapT = .clamp
                m.diffuse.contentsTransform = faceTransform(box: box, top: top)
                m.transparent.wrapS = .clamp
                m.transparent.wrapT = .clamp
                m.transparent.contentsTransform = m.diffuse.contentsTransform
                m.transparencyMode = .aOne
                m.blendMode = .alpha
                m.transparency = 0.92
                m.writesToDepthBuffer = true
                m.isDoubleSided = true
                m.shaderModifiers = cutoutShader
                return m
            }
            let topMaterial = face(top: true)
            let bottomMaterial = face(top: false)
            box.materials = [fr4(), fr4(), fr4(), fr4(), topMaterial, bottomMaterial]
            let node = SCNNode(geometry: box)
            node.simdPosition = scenePoint(rect.midX, rect.midY, -thickness / 2)
            node.renderingOrder = 1
            return (node, topMaterial, bottomMaterial)
        }

        /// The texture transform that puts a board image (u → world X, image
        /// top = world max Y = scene −Z) onto a face: read from the box's own
        /// texture coordinates, so it does not depend on SceneKit's face
        /// conventions. Identity when they cannot be read.
        nonisolated private static func faceTransform(box: SCNBox, top: Bool) -> SCNMatrix4 {
            guard let positions = box.sources(for: .vertex).first, let coords = box.sources(for: .texcoord).first,
                  positions.vectorCount == coords.vectorCount, positions.usesFloatComponents, coords.usesFloatComponents,
                  positions.bytesPerComponent == 4, coords.bytesPerComponent == 4 else { return SCNMatrix4Identity }
            var sx = 0.0, sz = 0.0, su = 0.0, sv = 0.0, n = 0.0
            var samples: [(x: Double, z: Double, u: Double, v: Double)] = []
            positions.data.withUnsafeBytes { pb in
                coords.data.withUnsafeBytes { cb in
                    for i in 0..<positions.vectorCount {
                        let po = positions.dataOffset + i * positions.dataStride
                        let co = coords.dataOffset + i * coords.dataStride
                        let y = Double(pb.loadUnaligned(fromByteOffset: po + 4, as: Float.self))
                        guard top ? y > 0 : y < 0 else { continue }
                        let x = Double(pb.loadUnaligned(fromByteOffset: po, as: Float.self))
                        let z = Double(pb.loadUnaligned(fromByteOffset: po + 8, as: Float.self))
                        let u = Double(cb.loadUnaligned(fromByteOffset: co, as: Float.self))
                        let v = Double(cb.loadUnaligned(fromByteOffset: co + 4, as: Float.self))
                        samples.append((x, z, u, v))
                        sx += x; sz += z; su += u; sv += v; n += 1
                    }
                }
            }
            guard n >= 3 else { return SCNMatrix4Identity }
            let mx = sx / n, mz = sz / n, mu = su / n, mv = sv / n
            var ux = 0.0, vz = 0.0
            for s in samples {
                ux += (s.u - mu) * (s.x - mx)
                vz += (s.v - mv) * (s.z - mz)
            }
            // Wanted: u grows with +X, v grows with +Z (v = 0 at −Z = world max Y, the image top).
            var m = SCNMatrix4Identity
            if ux < 0 { m.m11 = -1; m.m41 = 1 }
            if vz < 0 { m.m22 = -1; m.m42 = 1 }
            if UserDefaults.standard.bool(forKey: "debugDumpViews") {
                print("[debug] board \(top ? "top" : "bottom") face texture: u·x \(ux > 0 ? "+" : "−"), v·z \(vz > 0 ? "+" : "−") → flipU \(ux < 0), flipV \(vz < 0)")
            }
            return m
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


/// `-debugDumpViews`: how long the 3D view's per-tick `update` takes and
/// where it goes. Sections are accumulated (avg / max per 5 s report);
/// a single update over 8 ms is printed on its own as a stall.
@MainActor
final class TickProfiler {
    let enabled = UserDefaults.standard.bool(forKey: "debugDumpViews")
    private var sections: [String: (total: Double, max: Double, count: Int)] = [:]

    init() {
        // Headless runs are killed: a fully buffered stdout would lose the
        // numbers, so flush per line while profiling.
        if enabled { setvbuf(stdout, nil, _IOLBF, 0) }
    }
    private var order: [String] = []
    private var updateStart: TimeInterval = 0
    private var lastUpdateStart: TimeInterval = 0
    private var gaps: (total: Double, max: Double, min: Double, count: Int) = (0, 0, .infinity, 0)
    private var updates: (total: Double, max: Double, count: Int) = (0, 0, 0)
    private var current: [(String, Double)] = []

    func beginUpdate() {
        guard enabled else { return }
        updateStart = CACurrentMediaTime()
        if lastUpdateStart > 0 {
            let gap = updateStart - lastUpdateStart
            gaps.total += gap; gaps.max = max(gaps.max, gap); gaps.min = min(gaps.min, gap); gaps.count += 1
        }
        lastUpdateStart = updateStart
        current = []
    }

    func endUpdate() {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - updateStart) * 1000
        updates.total += ms; updates.max = max(updates.max, ms); updates.count += 1
        if ms > 8 {
            let parts = current.map { String(format: "%@ %.1f", $0.0 as NSString, $0.1) }.joined(separator: ", ")
            print(String(format: "[debug] 3D update stall: %.1f ms [%@]", ms, parts as NSString))
        }
    }

    @discardableResult
    func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        let ms = (CACurrentMediaTime() - start) * 1000
        var entry = sections[name] ?? (0, 0, 0)
        if entry.count == 0 { order.append(name) }
        entry.total += ms; entry.max = max(entry.max, ms); entry.count += 1
        sections[name] = entry
        current.append((name, ms))
        return result
    }

    func report() {
        guard enabled, updates.count > 0 else { return }
        var line = String(format: "[debug] 3D update: %d calls, avg %.2f ms, max %.1f ms; gap avg %.1f ms (min %.1f, max %.1f)",
                          updates.count, updates.total / Double(updates.count), updates.max,
                          gaps.count > 0 ? gaps.total / Double(gaps.count) * 1000 : 0,
                          gaps.count > 0 ? gaps.min * 1000 : 0, gaps.max * 1000)
        for name in order {
            guard let e = sections[name], e.count > 0 else { continue }
            line += String(format: "; %@ avg %.2f max %.1f (%d)", name as NSString, e.total / Double(e.count), e.max, e.count)
        }
        print(line)
        sections = [:]
        order = []
        gaps = (0, 0, .infinity, 0)
        updates = (0, 0, 0)
    }
}
