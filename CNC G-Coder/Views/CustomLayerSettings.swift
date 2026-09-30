import SwiftUI

/// Sidebar sections for a drawn layer: its name, side and operation, the
/// tool that machines it, the list of its shapes, and an inspector for the
/// selected shapes' numbers (position, size, stroke width, text…).
struct CustomLayerSections: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: ShapeEditor
    let layerID: UUID
    let openLibrary: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @State private var confirmDelete = false

    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }
    private var layer: CustomLayer? { model.customLayers.first { $0.id == layerID } }

    private func update(_ action: String, _ change: (inout CustomLayer) -> Void) {
        guard var layer else { return }
        change(&layer)
        editor.setLayer(layer, actionName: action)
    }

    private func field<T>(_ keyPath: WritableKeyPath<CustomLayer, T>, action: String) -> Binding<T> {
        Binding(
            get: { (layer ?? CustomLayer(name: ""))[keyPath: keyPath] },
            set: { value in update(action) { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        if let layer {
            layerSection(layer)
            toolSection(layer)
            shapesSection(layer)
        }
    }

    // MARK: - Layer

    private func layerSection(_ layer: CustomLayer) -> some View {
        Section {
            TextField("Name", text: field(\.name, action: "Rename Layer"))
                .help("The program is named after it: \"my-label.ngc\".")
            Picker("Side", selection: field(\.back, action: "Change Side")) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Front: machined with the front copper. Back: machined after flipping the board — the program is mirrored like back copper, and you draw it as seen from the front (un-mirror the back side in View Options to check).")
            Picker("Operation", selection: field(\.operation, action: "Change Operation")) {
                ForEach(CustomLayer.Operation.allCases) { op in Text(op.title).tag(op) }
            }
            .help("Engrave: the tool follows the drawn line itself. Cut outside / inside: closed shapes are offset by half the tool so what you drew is the size that comes out — outside for a part you keep, inside for a hole. Open lines are always engraved.")
            HStack {
                Button {
                    model.duplicateCustomLayer(id: layer.id)
                } label: {
                    Label("Duplicate Layer", systemImage: "plus.square.on.square")
                }
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete Layer", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .confirmationDialog("Delete \"\(layer.name)\"?", isPresented: $confirmDelete) {
                Button("Delete Layer", role: .destructive) { model.removeCustomLayer(id: layer.id) }
            } message: {
                Text("Its \(layer.shapes.count) shape\(layer.shapes.count == 1 ? "" : "s") go with it. Undo brings it back.")
            }
        } header: {
            Label("Custom layer", systemImage: "pencil.and.outline")
                .foregroundStyle(.red)
        } footer: {
            Text(operationFooter(layer))
        }
    }

    private func operationFooter(_ layer: CustomLayer) -> String {
        switch layer.operation {
        case .engrave:
            return "The tool centre runs along every drawn line. A shape's stroke width wider than the tool is cleared with overlapping passes; filled shapes are pocketed."
        case .outside:
            return "Closed shapes are cut around the outside, so the piece inside comes out at the drawn size (a cutout, an island). Open lines are engraved."
        case .inside:
            return "Closed shapes are cut around the inside, so the hole comes out at the drawn size. Open lines are engraved."
        }
    }

    // MARK: - Tool

    private func toolSection(_ layer: CustomLayer) -> some View {
        let current = model.tools.tool(id: layer.toolID)
        return Section {
            LabeledContent("Tool") {
                Menu {
                    let choices = model.tools.tools(for: .custom)
                    if choices.isEmpty { Text("No milling tools in the library") }
                    ForEach(choices) { tool in
                        Toggle(isOn: Binding(
                            get: { current?.id == tool.id },
                            set: { _ in model.applyTool(tool, toCustomLayer: layer.id) }
                        )) {
                            Text("\(tool.name)  ·  \(toolDetail(tool))")
                        }
                    }
                    Divider()
                    Toggle("Custom", isOn: Binding(
                        get: { current == nil },
                        set: { _ in update("Change Tool") { $0.toolID = "" } }
                    ))
                    Button("Edit Tool Library…", action: openLibrary)
                } label: {
                    Text(current?.name ?? "Custom")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fixedSize()
            }
            .help("Pick a tool from the library to fill in diameter, depth, feeds and spindle; the fields stay editable afterwards.")
            valueRow("Tool diameter", \.toolDiameter, .length, minimum: 0.01,
                     help: "Effective cutting diameter at depth — for a V-bit, tip + 2 × |depth| × tan(angle ÷ 2). Everything is offset and cleared by this width.")
            valueRow("Cut depth", \.cutDepth, .length,
                     help: "Final Z of the cut, negative. Engraving labels: −0.05…−0.1 mm. Cutting through 1.6 mm stock: −1.8 mm.")
            valueRow("Depth per pass", \.depthPerPass, .length, minimum: 0,
                     help: "Reach the cut depth in several passes of at most this depth; 0 = one pass. Closed shapes stay down and go round again deeper; open lines run back and forth.")
            valueRow("Pass overlap", \.overlap, .plain("%"), minimum: 0,
                     help: "Overlap between neighbouring passes when a stroke width or a filled shape needs more than one. 40–50 % leaves no ridges.")
            valueRow("XY feed", \.feedXY, .feed, minimum: 1, help: "Horizontal cutting speed.")
            valueRow("Z feed", \.feedZ, .feed, minimum: 1, help: "Plunge speed into the material.")
            valueRow("Spindle", \.spindle, .plain("rpm"), minimum: 0, help: "Spindle speed written as the S-word.")
            valueRow("Spindle dwell", \.dwell, .plain("s"), minimum: 0,
                     help: "Pause after the spindle starts and stops (G4 P, seconds). 0 = none.")
        } header: {
            Text("Tool")
        } footer: {
            if let problem = layer.validationError {
                Text(problem).foregroundStyle(.orange)
            } else {
                Text("One program per layer, machined with this one tool. Programs are written by Generate and by the CNC export below, like every other layer.")
            }
        }
    }

    private func toolDetail(_ tool: MachineTool) -> String {
        let size = "\(units.length(tool.listDiameter)) \(units.lengthSymbol)"
        return tool.shape == .vBit ? "V \(ParametersStore.format(tool.tipAngle))° → \(size)" : "Ø \(size)"
    }

    private func valueRow(_ label: String, _ keyPath: WritableKeyPath<CustomLayer, Double>, _ kind: ParamKind,
                          minimum: Double? = nil, help: String) -> some View {
        ParamRowLayout(label) {
            MeasureField(value: field(keyPath, action: "Edit \(label)"), kind: kind, minimum: minimum, plain: true)
        }
        .help(help)
    }

    // MARK: - Shapes

    private func shapesSection(_ layer: CustomLayer) -> some View {
        Section {
            if layer.shapes.isEmpty {
                Text("No shapes yet — pick a tool in the bar above the preview and draw. Shapes snap to the grid, guides and each other.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(layer.shapes) { shape in
                let selected = editor.selection.contains(shape.id)
                HStack(spacing: 8) {
                    Image(systemName: shape.geometry.icon)
                        .frame(width: 16)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(shape.name)
                        .lineLimit(1)
                    Spacer()
                    Text(sizeText(shape))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.shift) {
                        if selected { editor.selection.remove(shape.id) } else { editor.selection.insert(shape.id) }
                    } else {
                        editor.selection = [shape.id]
                    }
                    editor.tool = .select
                }
                .listRowBackground(selected ? Color.accentColor.opacity(0.16) : nil)
                .contextMenu {
                    Button("Duplicate") { editor.selection = [shape.id]; editor.duplicateSelection() }
                    Button("Delete", role: .destructive) { editor.selection = [shape.id]; editor.deleteSelection() }
                }
            }
            if layer.shapes.count > 1 {
                HStack {
                    Button("Select All") { editor.selectAll() }
                    Spacer()
                    Text("\(layer.shapes.count) shapes")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        } header: {
            Text("Shapes")
        }
    }

    private func sizeText(_ shape: DrawnShape) -> String {
        let u = units.lengthSymbol
        switch shape.geometry {
        case .rect(_, let size, _, _): return "\(units.length(size.width)) × \(units.length(size.height)) \(u)"
        case .circle(_, let d): return "⌀ \(units.length(d)) \(u)"
        case .line(let points, _): return "\(points.count) pts"
        case .text(_, _, let height, _, _): return "h \(units.length(height)) \(u)"
        }
    }
}

// MARK: - Inspector

/// Floating panel over the drawing canvas with the selected shapes'
/// geometry. It appears while something is selected and hides otherwise.
struct ShapeInspectorPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: ShapeEditor

    var body: some View {
        if let layer = editor.activeLayer,
           layer.shapes.contains(where: { editor.selection.contains($0.id) }) {
            VStack(spacing: 0) {
                HStack {
                    Label("Properties", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button {
                        editor.selection = []
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Deselect (Esc)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
                Form {
                    ShapeInspector(editor: editor, layer: layer)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .controlSize(.small)
            }
            .frame(width: 290)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

/// Numbers of the selected shape(s), editable, with undo.
struct ShapeInspector: View {
    @ObservedObject var editor: ShapeEditor
    let layer: CustomLayer

    var body: some View {
        let selected = layer.shapes.filter { editor.selection.contains($0.id) }
        if selected.count == 1, let shape = selected.first {
            single(shape)
        } else if selected.count > 1 {
            multiple(selected)
        }
    }

    private func value(_ id: UUID, _ keyPath: WritableKeyPath<DrawnShape, Double>) -> Binding<Double> {
        Binding(
            get: { layer.shapes.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { v in editor.updateShape(id, actionName: "Edit Shape") { $0[keyPath: keyPath] = v } }
        )
    }

    private func row(_ label: String, _ id: UUID, _ keyPath: WritableKeyPath<DrawnShape, Double>, _ kind: ParamKind,
                     minimum: Double? = nil, help: String = "") -> some View {
        ParamRowLayout(label) {
            MeasureField(value: value(id, keyPath), kind: kind, minimum: minimum, plain: true)
        }
        .help(help)
    }

    @ViewBuilder
    private func single(_ shape: DrawnShape) -> some View {
        let id = shape.id
        Section {
            switch shape.geometry {
            case .rect:
                row("X", id, \.positionX, .length, help: "Lower-left corner, design coordinates.")
                row("Y", id, \.positionY, .length)
                row("Width", id, \.width, .length, minimum: 0.01)
                row("Height", id, \.height, .length, minimum: 0.01)
                row("Corner radius", id, \.cornerRadius, .length, minimum: 0,
                    help: "Rounds the corners; clamped to half the shorter side.")
                row("Rotation", id, \.rotation, .plain("°"), help: "About the centre. Resize handles are hidden while rotated.")
            case .circle:
                row("Centre X", id, \.positionX, .length)
                row("Centre Y", id, \.positionY, .length)
                row("Diameter", id, \.diameter, .length, minimum: 0.01)
            case .line(let points, let closed):
                row("Start X", id, \.positionX, .length, help: "Moves the whole line.")
                row("Start Y", id, \.positionY, .length)
                ParamRowLayout("Points") { ParamReadout(value: "\(points.count)", unit: "") }
                .help("Drag the vertex handles in the view to reshape the line.")
                Toggle("Closed (polygon)", isOn: Binding(
                    get: { closed },
                    set: { v in editor.updateShape(id, actionName: "Edit Shape") { $0.isClosedLine = v } }
                ))
                .disabled(points.count < 3)
            case .text(_, let string, _, _, let style):
                TextField("Text", text: Binding(
                    get: { string },
                    set: { v in editor.updateShape(id, actionName: "Edit Text") { $0.textString = v } }
                ))
                LabeledContent("Font") {
                    FontMenu(style: Binding(
                        get: { style },
                        set: { v in editor.updateShape(id, actionName: "Change Font") { $0.textStyle = v } }
                    ))
                }
                if !style.isStrokeFont {
                    HStack {
                        Toggle("Bold", isOn: Binding(
                            get: { style.bold },
                            set: { v in editor.updateShape(id, actionName: "Change Font") { $0.textStyle.bold = v } }
                        ))
                        Toggle("Italic", isOn: Binding(
                            get: { style.italic },
                            set: { v in editor.updateShape(id, actionName: "Change Font") { $0.textStyle.italic = v } }
                        ))
                    }
                }
                row("Height", id, \.textHeight, .length, minimum: 0.1, help: "Cap height of the letters.")
                row("Spacing", id, \.textSpacing, .length, help: "Extra space between letters (negative tightens).")
                row("X", id, \.positionX, .length, help: "Start of the baseline.")
                row("Y", id, \.positionY, .length)
                row("Rotation", id, \.rotation, .plain("°"), help: "About the start of the baseline.")
            }
            row("Stroke width", id, \.strokeWidth, .length, minimum: 0,
                help: "Width of the engraved line. 0 = one pass of the tool; wider is cleared with overlapping passes.")
            if shape.geometry.isClosed, !shape.isText {
                Toggle("Filled (pocket)", isOn: Binding(
                    get: { shape.filled },
                    set: { v in editor.updateShape(id, actionName: "Edit Shape") { $0.filled = v } }
                ))
                .help("Clear the whole inside with concentric passes, inside out.")
            }
        } header: {
            Label(shape.geometry.kindName, systemImage: shape.geometry.icon)
        } footer: {
            if shape.isText {
                Text("Outline fonts are engraved along their contours; the single-stroke font as one line per stroke. Letters cannot be pocketed.")
            }
        }
    }

    @ViewBuilder
    private func multiple(_ shapes: [DrawnShape]) -> some View {
        Section {
            ParamRowLayout("Stroke width") {
                MeasureField(value: Binding(
                    get: { shapes.first?.strokeWidth ?? 0 },
                    set: { v in editor.updateSelectedShapes(actionName: "Edit Shapes") { $0.strokeWidth = v } }
                ), kind: .length, minimum: 0, plain: true)
            }
            Toggle("Filled (pocket)", isOn: Binding(
                get: { shapes.allSatisfy(\.filled) },
                set: { v in editor.updateSelectedShapes(actionName: "Edit Shapes") { if $0.geometry.isClosed, !$0.isText { $0.filled = v } } }
            ))
            HStack(spacing: 4) {
                ForEach(ShapeEditor.AlignEdge.allCases) { edge in
                    Button { editor.align(edge) } label: { Image(systemName: edge.icon) }
                        .help(edge.title)
                }
                Spacer()
                ForEach(ShapeEditor.DistributeAxis.allCases) { axis in
                    Button { editor.distribute(axis) } label: { Image(systemName: axis.icon) }
                        .help(axis.title)
                        .disabled(shapes.count < 3)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            HStack {
                Button("Duplicate") { editor.duplicateSelection() }
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } header: {
            Text("\(shapes.count) shapes selected")
        } footer: {
            Text("Align moves shapes to the edges or centres of the selection's box; distribute spaces them with equal gaps.")
        }
    }
}

/// Inspector accessors: each reads the matching value of the geometry and
/// writes it back, leaving other shape kinds untouched.
extension DrawnShape {
    var isText: Bool {
        if case .text = geometry { return true }
        return false
    }

    var positionX: Double {
        get { anchor.x }
        set { self = moved(by: CGVector(dx: newValue - anchor.x, dy: 0)) }
    }

    var positionY: Double {
        get { anchor.y }
        set { self = moved(by: CGVector(dx: 0, dy: newValue - anchor.y)) }
    }

    var width: Double {
        get { if case .rect(_, let s, _, _) = geometry { return s.width }; return bounds.map { Double($0.width) } ?? 0 }
        set { if case .rect(let o, let s, let r, let rot) = geometry {
            geometry = .rect(origin: o, size: CGSize(width: max(newValue, 0.01), height: s.height), cornerRadius: r, rotation: rot) } }
    }

    var height: Double {
        get { if case .rect(_, let s, _, _) = geometry { return s.height }; return bounds.map { Double($0.height) } ?? 0 }
        set { if case .rect(let o, let s, let r, let rot) = geometry {
            geometry = .rect(origin: o, size: CGSize(width: s.width, height: max(newValue, 0.01)), cornerRadius: r, rotation: rot) } }
    }

    var cornerRadius: Double {
        get { if case .rect(_, _, let r, _) = geometry { return r }; return 0 }
        set { if case .rect(let o, let s, _, let rot) = geometry {
            geometry = .rect(origin: o, size: s, cornerRadius: max(newValue, 0), rotation: rot) } }
    }

    var rotation: Double {
        get {
            switch geometry {
            case .rect(_, _, _, let rot): rot
            case .text(_, _, _, let rot, _): rot
            default: 0
            }
        }
        set {
            switch geometry {
            case .rect(let o, let s, let r, _): geometry = .rect(origin: o, size: s, cornerRadius: r, rotation: newValue)
            case .text(let o, let str, let h, _, let style): geometry = .text(origin: o, string: str, height: h, rotation: newValue, style: style)
            default: break
            }
        }
    }

    var diameter: Double {
        get { if case .circle(_, let d) = geometry { return d }; return 0 }
        set { if case .circle(let c, _) = geometry { geometry = .circle(center: c, diameter: max(newValue, 0.01)) } }
    }

    var isClosedLine: Bool {
        get { if case .line(_, let closed) = geometry { return closed }; return false }
        set { if case .line(let pts, _) = geometry { geometry = .line(points: pts, closed: newValue) } }
    }

    var textString: String {
        get { if case .text(_, let s, _, _, _) = geometry { return s }; return "" }
        set { if case .text(let o, _, let h, let rot, let style) = geometry {
            geometry = .text(origin: o, string: newValue, height: h, rotation: rot, style: style) } }
    }

    var textHeight: Double {
        get { if case .text(_, _, let h, _, _) = geometry { return h }; return 0 }
        set { if case .text(let o, let s, _, let rot, let style) = geometry {
            geometry = .text(origin: o, string: s, height: max(newValue, 0.1), rotation: rot, style: style) } }
    }

    var textStyle: TextStyle {
        get { if case .text(_, _, _, _, let style) = geometry { return style }; return TextStyle() }
        set { if case .text(let o, let s, let h, let rot, _) = geometry {
            geometry = .text(origin: o, string: s, height: h, rotation: rot, style: newValue) } }
    }

    var textSpacing: Double {
        get { textStyle.spacing }
        set { textStyle.spacing = newValue }
    }
}
