import SwiftUI

/// A ruler guide: a world X (vertical) or Y (horizontal), in millimetres —
/// the same positions the canvas stores, draws and snaps to.
enum PreviewGuide: Hashable {
    case vertical(Double)
    case horizontal(Double)

    static let xKey = "previewGuidesX", yKey = "previewGuidesY"

    var title: String {
        let units = UnitSystem.current
        return switch self {
        case .vertical(let x): "X \(units.length(x)) \(units.lengthSymbol)"
        case .horizontal(let y): "Y \(units.length(y)) \(units.lengthSymbol)"
        }
    }

    static var all: [PreviewGuide] {
        let d = UserDefaults.standard
        return ToolpathCanvasView.decodeGuides(d.string(forKey: xKey) ?? "").map { .vertical($0) }
            + ToolpathCanvasView.decodeGuides(d.string(forKey: yKey) ?? "").map { .horizontal($0) }
    }

    /// Adds a guide through the centre of a design-space box (and shows guides).
    @discardableResult
    static func addThroughCentre(of box: CGRect, designToWorld: CGAffineTransform, vertical: Bool) -> PreviewGuide {
        let centre = CGPoint(x: box.midX, y: box.midY).applying(designToWorld)
        let key = vertical ? xKey : yKey
        let value = vertical ? centre.x : centre.y
        let d = UserDefaults.standard
        var values = ToolpathCanvasView.decodeGuides(d.string(forKey: key) ?? "")
        if !values.contains(where: { abs($0 - value) < 1e-4 }) {
            values.append(value)
            d.set(ToolpathCanvasView.encodeGuides(values), forKey: key)
        }
        d.set(true, forKey: "previewShowGuides")
        return vertical ? .vertical(value) : .horizontal(value)
    }

    /// The reflection across this guide, in design space. Program frames are
    /// axis-aligned, so a vertical guide stays vertical there.
    func reflection(designToWorld: CGAffineTransform) -> CGAffineTransform {
        let inverse = designToWorld.inverted()
        switch self {
        case .vertical(let x):
            let g = CGPoint(x: x, y: 0).applying(inverse).x
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * g, ty: 0)
        case .horizontal(let y):
            let g = CGPoint(x: 0, y: y).applying(inverse).y
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * g)
        }
    }
}

/// Toolbar items shared by both editors: guides through the selection's
/// centre, and a menu mirroring the selection across a guide.
struct GuideToolbarItems: View {
    let hasSelection: Bool
    let addGuide: (_ vertical: Bool) -> Void
    /// Nil hides the mirror menu (imported Gerber layers cannot be mirrored).
    let mirror: ((_ guide: PreviewGuide, _ copy: Bool) -> Void)?
    // Read so the menu updates when guides are added, moved or removed.
    @AppStorage(PreviewGuide.xKey) private var guidesXRaw = ""
    @AppStorage(PreviewGuide.yKey) private var guidesYRaw = ""

    var body: some View {
        Button { addGuide(true) } label: { Image(systemName: "align.horizontal.center") }
            .disabled(!hasSelection)
            .help("Vertical guide through the centre of the selection — select the left and right board edges to find the board's centre line. Drag a guide back into the ruler to remove it.")
        Button { addGuide(false) } label: { Image(systemName: "align.vertical.center") }
            .disabled(!hasSelection)
            .help("Horizontal guide through the centre of the selection — select the top and bottom board edges to find the board's centre line.")
        if let mirror { mirrorMenu(mirror) }
    }

    private func mirrorMenu(_ mirror: @escaping (PreviewGuide, Bool) -> Void) -> some View {
        let guides = guidesXRaw.isEmpty && guidesYRaw.isEmpty ? [] : PreviewGuide.all
        return Menu {
            if guides.isEmpty {
                Text("No guides — add one through the centre of a selection, or drag one out of a ruler")
            }
            Section("Mirror Copy") {
                ForEach(guides, id: \.self) { guide in
                    Button("Across \(guide.title)") { mirror(guide, true) }
                }
            }
            Section("Mirror (Move)") {
                ForEach(guides, id: \.self) { guide in
                    Button("Across \(guide.title)") { mirror(guide, false) }
                }
            }
        } label: {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!hasSelection)
        .help("Mirror the selection across a guide: Mirror Copy adds the reflection (e.g. the other side of the board), Mirror moves it.")
    }
}
