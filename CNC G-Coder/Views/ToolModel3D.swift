import SwiftUI
import SceneKit

/// The physical shape of a cutter, in millimetres — enough to draw it at
/// real size: in the 3D preview (following the toolpath, spinning while it
/// plays), in the tool library editor, and as the library's list icons.
nonisolated struct ToolGeometry: Equatable, Sendable {
    enum Kind: Sendable { case endMill, ball, vBit, drill }

    var kind: Kind
    /// Cutting diameter (end mill, ball, drill). V-bits use tip + angle.
    var diameter: Double
    var tipDiameter: Double = 0.1
    /// Included angle of a V-bit, degrees.
    var angle: Double = 30
    /// PCB tooling is almost all 1/8″ shank, 38 mm long.
    var shank: Double = 3.175
    var length: Double = 38

    var shankDiameter: Double { max(shank, kind == .vBit ? 0 : diameter) }

    /// Length of the cutting part (flutes / cone / point).
    var cuttingLength: Double {
        switch kind {
        case .vBit:
            let half = max(angle, 1) / 2 * .pi / 180
            return min(20, max(0.5, (shankDiameter - tipDiameter) / 2 / tan(half)))
        case .drill:
            return min(12, max(3, diameter * 8))
        case .endMill, .ball:
            return min(12, max(2.5, diameter * 3))
        }
    }

    /// Height of a drill's 118° point.
    var pointHeight: Double { diameter / 2 / tan(59 * .pi / 180) }

    /// Taper from the cutting diameter up to the shank.
    var neckLength: Double {
        guard kind != .vBit, diameter < shankDiameter - 0.05 else { return 0 }
        return max(1.5, (shankDiameter - diameter) * 1.2)
    }

    /// Side profile, tip to top: (height, radius) pairs. Drawn as the list
    /// icon; the 3D model is built from the same numbers.
    var profile: [(y: Double, r: Double)] {
        let s = shankDiameter / 2
        var points: [(Double, Double)] = []
        switch kind {
        case .vBit:
            points = [(0, tipDiameter / 2), (cuttingLength, s)]
        case .drill:
            points = [(0, 0), (pointHeight, diameter / 2), (cuttingLength, diameter / 2)]
        case .ball:
            let r = diameter / 2
            points = (0...6).map { i in
                let a = Double(i) / 6 * .pi / 2
                return (r - r * cos(a), r * sin(a))
            } + [(cuttingLength, r)]
        case .endMill:
            points = [(0, diameter / 2), (cuttingLength, diameter / 2)]
        }
        let top = points.last!.0
        if neckLength > 0 { points.append((top + neckLength, s)) }
        points.append((length, s))
        return points
    }

    /// A short description for the library editor.
    var summary: String {
        let f = ParametersStore.format
        switch kind {
        case .vBit:
            return "V-bit \(f(angle))° · tip \(f(tipDiameter)) mm · cone \(String(format: "%.1f", cuttingLength)) mm · shank \(f(shankDiameter)) mm"
        case .drill:
            return "Drill Ø \(f(diameter)) mm · flutes \(String(format: "%.1f", cuttingLength)) mm · shank \(f(shankDiameter)) mm"
        case .ball:
            return "Ball nose Ø \(f(diameter)) mm · flutes \(String(format: "%.1f", cuttingLength)) mm · shank \(f(shankDiameter)) mm"
        case .endMill:
            return "End mill Ø \(f(diameter)) mm · flutes \(String(format: "%.1f", cuttingLength)) mm · shank \(f(shankDiameter)) mm"
        }
    }

    /// Colour of the depth-stop ring PCB bits carry, by type.
    var ringColor: NSColor {
        switch kind {
        case .vBit: NSColor(red: 0.95, green: 0.75, blue: 0.10, alpha: 1)
        case .drill: NSColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)
        case .ball: NSColor(red: 0.55, green: 0.30, blue: 0.85, alpha: 1)
        case .endMill: NSColor(red: 0.15, green: 0.45, blue: 0.90, alpha: 1)
        }
    }
}

extension ToolGeometry {
    /// The shape of a library tool.
    init(tool: MachineTool) {
        switch tool.shape {
        case .vBit:
            self.init(kind: .vBit, diameter: tool.listDiameter, tipDiameter: tool.tipDiameter, angle: tool.tipAngle)
        case .ball:
            self.init(kind: .ball, diameter: tool.diameter)
        case .flat:
            self.init(kind: tool.use == .drilling ? .drill : .endMill, diameter: tool.diameter)
        }
    }
}

/// Builds the SceneKit model of a bit: tip at the node origin, axis along +Y
/// (the spindle axis, machine Z). Everything is real size in millimetres.
nonisolated enum ToolModel {

    static func node(_ g: ToolGeometry) -> SCNNode {
        let root = SCNNode()
        let carbide = fluteMaterial(g)
        let steel = plainMaterial(white: 0.82, shininess: 0.8)
        let s = g.shankDiameter / 2
        var y = 0.0

        func add(_ geometry: SCNGeometry, from y0: Double, height: Double, material: SCNMaterial) {
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(0, y0 + height / 2, 0)
            root.addChildNode(node)
        }

        switch g.kind {
        case .vBit:
            let h = g.cuttingLength
            add(SCNCone(topRadius: s, bottomRadius: max(g.tipDiameter / 2, 0.01), height: h), from: 0, height: h, material: carbide)
            y = h
        case .drill:
            let ph = g.pointHeight
            add(SCNCone(topRadius: g.diameter / 2, bottomRadius: 0.001, height: ph), from: 0, height: ph, material: carbide)
            add(SCNCylinder(radius: g.diameter / 2, height: g.cuttingLength - ph), from: ph,
                height: g.cuttingLength - ph, material: carbide)
            y = g.cuttingLength
        case .ball:
            let r = g.diameter / 2
            let sphere = SCNSphere(radius: r)
            sphere.segmentCount = 32
            sphere.materials = [carbide]
            let ball = SCNNode(geometry: sphere)
            ball.position = SCNVector3(0, r, 0)
            root.addChildNode(ball)
            add(SCNCylinder(radius: r, height: g.cuttingLength - r), from: r, height: g.cuttingLength - r, material: carbide)
            y = g.cuttingLength
        case .endMill:
            add(SCNCylinder(radius: g.diameter / 2, height: g.cuttingLength), from: 0, height: g.cuttingLength, material: carbide)
            y = g.cuttingLength
        }
        if g.neckLength > 0 {
            add(SCNCone(topRadius: s, bottomRadius: g.diameter / 2, height: g.neckLength), from: y,
                height: g.neckLength, material: steel)
            y += g.neckLength
        }
        add(SCNCylinder(radius: s, height: g.length - y), from: y, height: g.length - y, material: steel)

        // Depth-stop ring, where PCB bits carry it (~21 mm from the tip).
        let ringY = min(max(y + 2, 21), g.length - 4)
        let ring = SCNTube(innerRadius: s, outerRadius: max(s + 1.2, 3.4), height: 3)
        let plastic = plainMaterial(white: 1, shininess: 0.3)
        plastic.diffuse.contents = g.ringColor
        ring.materials = [plastic]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, ringY + 1.5, 0)
        root.addChildNode(ringNode)
        return root
    }

    private static func plainMaterial(white: CGFloat, shininess: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: white, alpha: 1)
        m.specular.contents = NSColor(white: 1, alpha: 1)
        m.shininess = shininess
        return m
    }

    /// Carbide with a helical flute pattern, so the spin is visible.
    private static func fluteMaterial(_ g: ToolGeometry) -> SCNMaterial {
        let m = plainMaterial(white: 1, shininess: 0.5)
        m.diffuse.contents = stripeImage
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        // Two flutes around; helix pitch ≈ 1.5 × diameter.
        let d = max(g.kind == .vBit ? g.shankDiameter : g.diameter, 0.2)
        let turns = max(1, g.cuttingLength / (d * 1.5))
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(2, CGFloat(turns), 1)
        return m
    }

    /// A diagonal two-tone tile: repeated around a cylinder it reads as flutes.
    private static let stripeImage: NSImage = {
        let size = 128
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(white: 0.62, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor(white: 0.28, alpha: 1).setFill()
        let band = NSBezierPath()
        let w = CGFloat(size) * 0.34
        for offset in [-CGFloat(size), 0, CGFloat(size)] {
            band.move(to: NSPoint(x: offset, y: 0))
            band.line(to: NSPoint(x: offset + w, y: 0))
            band.line(to: NSPoint(x: offset + w + CGFloat(size), y: CGFloat(size)))
            band.line(to: NSPoint(x: offset + CGFloat(size), y: CGFloat(size)))
            band.close()
        }
        band.fill()
        image.unlockFocus()
        return image
    }()

    /// Clockwise seen from above (M3): negative about +Y.
    static func spinAction() -> SCNAction {
        .repeatForever(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 0.4))
    }
}

// MARK: - Library views

/// The bit's side profile as a small icon for the tool list.
struct ToolSilhouette: View {
    let geometry: ToolGeometry

    var body: some View {
        Canvas { context, size in
            // Show the working end: tip up to a little past the cutting part.
            let visible = min(geometry.length, geometry.cuttingLength + geometry.neckLength + 4)
            let widest = max(geometry.shankDiameter, geometry.diameter)
            let scale = min(size.height / visible, size.width / widest)
            func point(_ y: Double, _ r: Double) -> CGPoint {
                CGPoint(x: size.width / 2 + r * scale, y: size.height - y * scale)
            }
            let profile = geometry.profile.filter { $0.y <= visible } + [(visible, geometry.shankDiameter / 2)]
            var path = Path()
            path.move(to: point(profile[0].y, -profile[0].r))
            for p in profile { path.addLine(to: point(p.y, -p.r)) }
            for p in profile.reversed() { path.addLine(to: point(p.y, p.r)) }
            path.closeSubpath()
            context.fill(path, with: .linearGradient(
                Gradient(colors: [Color(white: 0.45), Color(white: 0.85), Color(white: 0.5)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
        }
        .frame(width: 18, height: 30)
    }
}

/// A slowly turning 3D model of a bit, at real proportions, for the editor.
struct ToolPreview3D: NSViewRepresentable {
    let geometry: ToolGeometry

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = SCNScene()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.isPlaying = true   // the bit turns slowly all the time
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        view.scene?.rootNode.addChildNode(camera)
        view.pointOfView = camera
        context.coordinator.camera = camera
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.shown != geometry, let root = view.scene?.rootNode else { return }
        context.coordinator.shown = geometry
        context.coordinator.bit?.removeFromParentNode()
        let bit = ToolModel.node(geometry)
        bit.runAction(.repeatForever(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 4)))
        // Lie it down (tip to the right), like a catalogue photo.
        let holder = SCNNode()
        holder.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        holder.addChildNode(bit)
        root.addChildNode(holder)
        context.coordinator.bit = holder
        // Frame the whole bit, slightly from above.
        let length = geometry.length
        context.coordinator.camera?.camera?.orthographicScale = length * 0.17
        context.coordinator.camera?.position = SCNVector3(-length / 2, 8, 60)
        context.coordinator.camera?.look(at: SCNVector3(-length / 2, 0, 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: ToolGeometry?
        var bit: SCNNode?
        var camera: SCNNode?
    }
}

// MARK: - The bit each program uses

extension AppModel {
    /// The cutter that machines `kind`, from the current settings: what the
    /// 3D preview draws following the toolpath.
    func toolGeometry(for kind: LayerKind) -> ToolGeometry? {
        let p = parameters
        func value(_ s: String, _ fallback: Double) -> Double {
            Double(s.trimmingCharacters(in: .whitespaces)) ?? fallback
        }
        func milling(shape: String, diameter: String, tip: String, angle: String, toolID: String) -> ToolGeometry {
            if shape == "vbit" {
                return ToolGeometry(kind: .vBit, diameter: 0, tipDiameter: value(tip, 0.1), angle: value(angle, 30))
            }
            if let tool = tools.tool(id: toolID), tool.shape == .ball { return ToolGeometry(tool: tool) }
            return ToolGeometry(kind: .endMill, diameter: value(diameter, 1))
        }
        switch kind {
        case .front, .back:
            return milling(shape: p.millShape, diameter: p.millDiameter, tip: p.millVTip, angle: p.millVAngle, toolID: p.millToolID)
        case .maskTop, .maskBottom:
            return milling(shape: p.maskShape, diameter: p.maskTool, tip: p.maskVTip, angle: p.maskVAngle, toolID: p.maskToolID)
        case .silkTop, .silkBottom:
            return milling(shape: p.silkShape, diameter: p.silkTool, tip: p.silkVTip, angle: p.silkVAngle, toolID: p.silkToolID)
        case .outline:
            return ToolGeometry(kind: .endMill, diameter: value(p.cutterDiameter, 1))
        case .millDrill:
            return ToolGeometry(kind: .endMill, diameter: value(p.holeMillDiameter, 1))
        case .drill(let index, _):
            // The smallest hole in that drill file — the first bit it asks for.
            let file = index < detectedFiles.drills.count ? detectedFiles.drills[index] : nil
            let size = file.flatMap { drillHoleSizes[$0]?.first } ?? 0.8
            return ToolGeometry(kind: .drill, diameter: size)
        case .test:
            return ToolGeometry(kind: .vBit, diameter: 0, tipDiameter: 0.1, angle: 30)
        }
    }
}
