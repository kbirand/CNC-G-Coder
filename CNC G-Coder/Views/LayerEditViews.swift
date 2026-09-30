import SwiftUI

// MARK: - Toolbar

/// Floating glass bar over the canvas while an imported layer file is being
/// edited: selection helpers, delete, grid snapping, undo/redo and Done.
struct LayerEditToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: LayerFileEditor
    @AppStorage(SettingsKeys.snapToGrid) private var snapToGrid = false
    private var undoManager: UndoManager? { model.history }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                Label(title, systemImage: "square.and.pencil")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240)
                    .help("Editing \(editor.fileURL?.lastPathComponent ?? "the layer file"). Each change writes an edited copy — the original file is never modified. The toolpaths regenerate from it when you press Done.")
                divider
                Button { editor.selectAll() } label: { Image(systemName: "rectangle.dashed") }
                    .help("Select All (⌘A)")
                Button { editor.selectSimilar() } label: { Image(systemName: "wand.and.stars") }
                    .disabled(editor.selection.isEmpty)
                    .help("Select Similar: every track of the same width, pad of the same aperture, or hole of the same size as the selection.")
                Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                    .disabled(editor.selection.isEmpty)
                    .help("Delete the selection (⌫)")
                divider
                Toggle(isOn: $snapToGrid) {
                    Image(systemName: "squareshape.split.3x3")
                }
                .help("Snap to Grid (⌘'): dragged objects land on the grid lines shown in the view.")
                divider
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!(undoManager?.canUndo ?? false))
                    .help("Undo (⌘Z)")
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!(undoManager?.canRedo ?? false))
                    .help("Redo (⇧⌘Z)")
                divider
                Button("Done") { editor.end() }
                    .help("Stop editing and regenerate the toolpaths from the edited file (also Esc with nothing selected). The edits stay; Undo still steps back through them.")
            }
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .controlSize(.small)

            if let message = editor.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Divider().frame(height: 16).padding(.horizontal, 3)
    }

    private var title: String {
        guard let target = editor.target else { return "" }
        return "\(target.title) · \(editor.fileURL?.lastPathComponent ?? "")"
    }

    private var status: String {
        var parts: [String] = []
        switch editor.displayed {
        case .gerber(let image):
            let pads = image.objects.filter(\.isFlash).count
            let tracks = image.objects.filter(\.isTrack).count
            let areas = image.objects.count - pads - tracks
            parts.append("\(pads) pad\(pads == 1 ? "" : "s")")
            parts.append("\(tracks) track\(tracks == 1 ? "" : "s")")
            if areas > 0 { parts.append("\(areas) area\(areas == 1 ? "" : "s")") }
        case .drill(let image):
            parts.append("\(image.holes.count) hole\(image.holes.count == 1 ? "" : "s")")
        case nil:
            break
        }
        if !editor.selection.isEmpty { parts.append("\(editor.selection.count) selected") }
        parts.append("click to select, ⇧-click adds, drag a box or move, arrows nudge · toolpaths update on Done")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inspector

/// Floating panel with the selected objects' sizes and position, shown
/// while something is selected.
struct LayerEditInspectorPanel: View {
    @ObservedObject var editor: LayerFileEditor

    var body: some View {
        if let artwork = editor.artwork, !editor.selection.isEmpty {
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
                    LayerEditInspector(editor: editor, artwork: artwork)
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

struct LayerEditInspector: View {
    @ObservedObject var editor: LayerFileEditor
    let artwork: LayerArtwork

    var body: some View {
        switch artwork {
        case .gerber(let image): gerber(image)
        case .drill(let image): drill(image)
        }
    }

    private func field(_ label: String, _ value: Double, minimum: Double? = nil, help: String = "",
                       set: @escaping (Double) -> Void) -> some View {
        ParamRowLayout(label) {
            MeasureField(value: Binding(get: { value }, set: set), kind: .length, minimum: minimum,
                         plain: true, deferred: true)
        }
        .help(help)
    }

    @ViewBuilder
    private func position(_ anchor: CGPoint?, x: String, y: String, help: String) -> some View {
        if editor.selection.count == 1, let id = editor.selection.first, let anchor {
            field(x, anchor.x, help: help) { editor.setPosition(of: id, x: $0) }
            field(y, anchor.y, help: help) { editor.setPosition(of: id, y: $0) }
        }
    }

    // MARK: Gerber

    @ViewBuilder
    private func gerber(_ image: GerberImage) -> some View {
        let selected = image.objects.filter { editor.selection.contains($0.id) }
        let tracks = selected.filter(\.isTrack)
        let pads = selected.filter(\.isFlash)
        let trackIDs = Set(tracks.map(\.id)), padIDs = Set(pads.map(\.id))
        let areas = selected.count - tracks.count - pads.count

        Section {
            let only = selected.count == 1 ? selected.first : nil
            position(only?.anchor,
                     x: only?.isFlash == true ? "Centre X" : "Start X",
                     y: only?.isFlash == true ? "Centre Y" : "Start Y",
                     help: "Design coordinates of the Gerber file (not the machine origin). Moves the whole object.")
        } header: {
            Text(summary(pads: pads.count, tracks: tracks.count, areas: areas))
        }

        if !tracks.isEmpty {
            let widths = tracks.compactMap { $0.aperture.map { image.trackWidth(aperture: $0) } }
            Section {
                field("Width", widths.first ?? 0, minimum: 0.01,
                      help: "Track width. The tracks get a round aperture of this size; the isolation around them is recomputed when you press Done.") {
                    editor.setTrackWidth($0, of: trackIDs)
                }
            } header: {
                Text("Track\(tracks.count == 1 ? "" : "s")")
            } footer: {
                if Set(widths.map { ($0 * 1e4).rounded() }).count > 1 {
                    Text("Mixed widths — a new value sets them all.")
                }
            }
        }

        if !pads.isEmpty {
            let apertures = pads.compactMap { $0.aperture.flatMap { image.apertures[$0] } }
            let shapes = Set(apertures.map(\.template))
            Section {
                if let first = apertures.first, first.isStandard, shapes.count == 1, let size = first.size {
                    let unit = image.unit
                    switch first.shape {
                    case .circle, .polygon:
                        field("Diameter", size.width * unit, minimum: 0.01, help: "Pad diameter.") {
                            editor.setPadSize(width: $0, height: $0, of: padIDs)
                        }
                    default:
                        field("Width", size.width * unit, minimum: 0.01, help: "Pad size along X.") {
                            editor.setPadSize(width: $0, of: padIDs)
                        }
                        field("Height", size.height * unit, minimum: 0.01, help: "Pad size along Y.") {
                            editor.setPadSize(height: $0, of: padIDs)
                        }
                    }
                }
            } header: {
                Text(padHeader(apertures, count: pads.count, unit: image.unit))
            } footer: {
                if apertures.contains(where: { !$0.isStandard }) {
                    Text("Custom-shaped (macro) pads can be moved or deleted, but not resized.")
                } else if shapes.count > 1 {
                    Text("Pads of different shapes are selected — select one shape to resize.")
                } else if Set(apertures.map(\.code)).count > 1 {
                    Text("Mixed sizes — a new value sets them all.")
                } else {
                    Text("Only the selected pads change; other pads of this size keep theirs.")
                }
            }
        }

        if areas > 0 {
            Section {
                EmptyView()
            } footer: {
                Text("Filled areas (copper pours, custom pad shapes) can be moved or deleted.")
            }
        }

        actions
    }

    private func summary(pads: Int, tracks: Int, areas: Int) -> String {
        var parts: [String] = []
        if pads > 0 { parts.append("\(pads) pad\(pads == 1 ? "" : "s")") }
        if tracks > 0 { parts.append("\(tracks) track\(tracks == 1 ? "" : "s")") }
        if areas > 0 { parts.append("\(areas) area\(areas == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func padHeader(_ apertures: [GerberAperture], count: Int, unit: Double) -> String {
        let codes = Set(apertures.map(\.code))
        let noun = "Pad\(count == 1 ? "" : "s")"
        guard codes.count == 1, let a = apertures.first else { return noun }
        return "\(noun) — \(a.title(units: UnitSystem.current, unit: unit))"
    }

    // MARK: Drill

    @ViewBuilder
    private func drill(_ image: ExcellonImage) -> some View {
        let holes = image.holes.filter { editor.selection.contains($0.id) }
        let holeIDs = Set(holes.map(\.id))
        let diameters = holes.map { image.diameter($0.tool) }
        Section {
            position(holes.count == 1 ? holes.first?.at : nil, x: "Centre X", y: "Centre Y",
                     help: "Design coordinates of the drill file (not the machine origin).")
            field("Hole diameter", diameters.first ?? 0, minimum: 0.05,
                  help: "The selected holes are drilled with a tool of this size — one already in the file, or a new one added to its tool table.") {
                editor.setHoleDiameter($0, of: holeIDs)
            }
        } header: {
            Text("\(holes.count) hole\(holes.count == 1 ? "" : "s")"
                 + (holes.contains { $0.slotEnd != nil } ? " (slots included)" : ""))
        } footer: {
            if Set(diameters.map { ($0 * 1e4).rounded() }).count > 1 {
                Text("Mixed sizes — a new value sets them all.")
            } else {
                Text("Only the selected holes change. To resize every hole of a size, use the tool table in the sidebar.")
            }
        }
        actions
    }

    private var actions: some View {
        Section {
            HStack {
                Button("Select Similar") { editor.selectSimilar() }
                    .help("Every track of the same width, pad of the same aperture, or hole of the same size.")
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }
            }
        }
    }
}

// MARK: - Sidebar

/// The layer file behind the selected program: an Edit button, and while it
/// is being edited, its aperture or drill-tool table for changing sizes
/// everywhere at once.
struct LayerFileSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: LayerFileEditor
    /// The file behind the program selected in the sidebar.
    let selected: LayerEditTarget?

    var body: some View {
        if let target = editor.target ?? selected, let url = model.detectedFiles[target] {
            if editor.target == target, let artwork = editor.artwork {
                switch artwork {
                case .gerber(let image): apertureTable(image, url: url)
                case .drill(let image): toolTable(image, url: url)
                }
            } else {
                Section {
                    HStack {
                        Label {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: LayerFileEditor.isEditedCopy(url) ? "pencil.circle.fill" : "doc")
                                .foregroundStyle(LayerFileEditor.isEditedCopy(url) ? .orange : .secondary)
                        }
                        Spacer()
                        Button("Edit") { editor.begin(target) }
                            .help("Edit this file in the preview: track widths, pad and hole sizes, moving or deleting features.")
                    }
                } header: {
                    Text("Layer file")
                } footer: {
                    Text(LayerFileEditor.isEditedCopy(url)
                         ? "Edited in this session — Undo steps back through the edits; saving the project keeps them."
                         : "Change track widths, pad and hole sizes, or move and delete features. The original file is left as it is.")
                }
            }
        }
    }

    private func header(_ url: URL) -> some View {
        HStack {
            Label("Editing \(url.lastPathComponent)", systemImage: "square.and.pencil")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Done") { editor.end() }
                .controlSize(.small)
                .help("Stop editing and regenerate the toolpaths from the edited file.")
        }
    }

    // MARK: Apertures

    private func apertureTable(_ image: GerberImage, url: URL) -> some View {
        let use = image.apertureUse
        let codes = image.apertures.keys.sorted().filter { use[$0] != nil }
        return Section {
            ForEach(codes, id: \.self) { code in
                if let aperture = image.apertures[code] {
                    ApertureRow(editor: editor, aperture: aperture, unit: image.unit,
                                tracks: use[code]?.tracks ?? 0, pads: use[code]?.pads ?? 0)
                }
            }
        } header: {
            header(url)
        } footer: {
            Text("Each aperture is a size used across the layer. Changing one resizes every pad or track drawn with it — e.g. all 0.25 mm tracks at once. To change only some, select them in the preview. The toolpaths regenerate when you press Done.")
        }
    }

    // MARK: Drill tools

    private func toolTable(_ image: ExcellonImage, url: URL) -> some View {
        let use = image.toolUse
        let tools = image.tools.keys.sorted().filter { use[$0] != nil }
        return Section {
            ForEach(tools, id: \.self) { tool in
                HStack(alignment: .firstTextBaseline, spacing: ParamColumns.spacing) {
                    Button {
                        editor.selectTool(tool)
                    } label: {
                        Image(systemName: "circle.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Select these holes in the preview")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(String(format: "T%02d", tool)).lineLimit(1)
                        Text("\(use[tool] ?? 0) hole\(use[tool] == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    MeasureField(value: Binding(get: { image.tools[tool] ?? 0 },
                                                set: { editor.setToolDiameter(tool, $0) }),
                                 kind: .length, minimum: 0.05, plain: true, deferred: true)
                        .help("Hole diameter for every hole this tool drills.")
                }
            }
            if tools.isEmpty {
                Text("No holes in this file.").foregroundStyle(.secondary)
            }
        } header: {
            header(url)
        } footer: {
            Text("One row per drill size. Changing a size changes every hole drilled with it. To change only some holes, select them in the preview. The toolpaths regenerate when you press Done.")
        }
    }
}

/// One aperture: its shape, editable size, and how much uses it — in the
/// sidebar's value/unit columns, one line per dimension.
private struct ApertureRow: View {
    @ObservedObject var editor: LayerFileEditor
    let aperture: GerberAperture
    let unit: Double
    let tracks: Int
    let pads: Int

    var body: some View {
        let size = aperture.size
        row(label: "D\(aperture.code) \(shapeName)", detail: usage, select: true) {
            if let size {
                switch aperture.shape {
                case .circle, .polygon:
                    field(size.width * unit) { editor.setAperture(aperture.code, width: $0, height: $0) }
                        .help(aperture.shape == .circle ? "Diameter" : "Outer diameter")
                default:
                    field(size.width * unit) { editor.setAperture(aperture.code, width: $0, height: size.height * unit) }
                        .help("Width (X)")
                }
            } else {
                ParamReadout(value: "—", unit: "")
            }
        }
        if let size, aperture.shape == .rectangle || aperture.shape == .obround {
            row(label: "height", detail: "", select: false) {
                field(size.height * unit) { editor.setAperture(aperture.code, width: size.width * unit, height: $0) }
                    .help("Height (Y)")
            }
        }
    }

    private func row<Content: View>(label: String, detail: String, select: Bool,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ParamColumns.spacing) {
            if select {
                Button {
                    editor.selectAperture(aperture.code)
                } label: {
                    Image(systemName: icon)
                }
                .buttonStyle(.borderless)
                .help("Select everything drawn with D\(aperture.code) in the preview")
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(label)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
            Spacer(minLength: 8)
            content()
        }
    }

    private func field(_ value: Double, set: @escaping (Double) -> Void) -> some View {
        MeasureField(value: Binding(get: { value }, set: set), kind: .length, minimum: 0.01, plain: true, deferred: true)
    }

    private var icon: String {
        switch aperture.shape {
        case .circle: "circle"
        case .rectangle: "square"
        case .obround: "capsule"
        case .polygon: "hexagon"
        case .macro: "seal"
        }
    }

    private var shapeName: String {
        switch aperture.shape {
        case .circle: "round"
        case .rectangle: "rect"
        case .obround: "oval"
        case .polygon: "polygon"
        case .macro: aperture.template
        }
    }

    private var usage: String {
        var parts: [String] = []
        if tracks > 0 { parts.append("\(tracks) track\(tracks == 1 ? "" : "s")") }
        if pads > 0 { parts.append("\(pads) pad\(pads == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
