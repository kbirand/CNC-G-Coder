import SwiftUI
import AppKit

/// Floating glass bar over the toolpath canvas while a drawn layer is
/// selected: the drawing tools, snapping, align/distribute, duplicate,
/// delete and undo/redo — plus the text and stroke settings for new shapes.
struct ShapeEditorToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: ShapeEditor
    @AppStorage(SettingsKeys.snapToGrid) private var snapToGrid = false
    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    private var undoManager: UndoManager? { model.history }

    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                if let layer = editor.activeLayer {
                    Label(layer.name, systemImage: "pencil.and.outline")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                        .help("Drawing on \(layer.name) (\(layer.back ? "back" : "front") side). Pick another program in the sidebar to leave the editor.")
                    divider
                }
                ForEach(ShapeEditor.Tool.allCases) { tool in
                    toolButton(tool)
                }
                divider
                Toggle(isOn: $snapToGrid) {
                    Image(systemName: "squareshape.split.3x3")
                }
                .help("Snap to Grid (⌘'): points land on the grid lines shown in the view.")
                Toggle(isOn: $editor.snapToObjects) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .help("Snap to Objects: points land on other shapes' corners, vertices, centres and quadrants, and on guides.")
                divider
                Menu {
                    ForEach(ShapeEditor.AlignEdge.allCases) { edge in
                        Button { editor.align(edge) } label: { Label(edge.title, systemImage: edge.icon) }
                    }
                } label: {
                    Image(systemName: "align.horizontal.left")
                }
                .menuIndicator(.hidden)
                .disabled(editor.selection.count < 2)
                .help("Align the selected shapes' edges or centres to the selection's bounding box.")
                Menu {
                    ForEach(ShapeEditor.DistributeAxis.allCases) { axis in
                        Button { editor.distribute(axis) } label: { Label(axis.title, systemImage: axis.icon) }
                    }
                } label: {
                    Image(systemName: "distribute.horizontal.center")
                }
                .menuIndicator(.hidden)
                .disabled(editor.selection.count < 3)
                .help("Space the selected shapes with equal gaps between them; the outermost two stay put.")
                divider
                GuideToolbarItems(hasSelection: !editor.selection.isEmpty,
                                  addGuide: { editor.addGuideAtSelectionCentre(vertical: $0) },
                                  mirror: { editor.mirrorSelection(across: $0, copy: $1) })
                divider
                Button { editor.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(editor.selection.isEmpty)
                    .help("Duplicate the selection (⌘D)")
                Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                    .disabled(editor.selection.isEmpty)
                    .help("Delete the selection (⌫)")
                divider
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!(undoManager?.canUndo ?? false))
                    .help("Undo (⌘Z)")
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!(undoManager?.canRedo ?? false))
                    .help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.borderless)
            .toggleStyle(.button)
            .controlSize(.small)

            if editor.tool == .text { textRow }
            if editor.tool == .hole { holeRow }
            if editor.tool != .select, editor.tool != .hole { strokeRow }

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

    private func toolButton(_ tool: ShapeEditor.Tool) -> some View {
        Button {
            editor.tool = tool
        } label: {
            Image(systemName: tool.icon)
                .frame(width: 22, height: 20)
                .background(editor.tool == tool ? Color.accentColor.opacity(0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .help(tool.help)
    }

    private var status: String {
        let shapes = editor.displayedShapes.count
        let selected = editor.selection.count
        var parts = ["\(shapes) shape\(shapes == 1 ? "" : "s")"]
        if selected > 0 { parts.append("\(selected) selected") }
        if let draft = editor.draft, editor.tool == .line, !draft.points.isEmpty {
            parts.append("\(draft.points.count) point\(draft.points.count == 1 ? "" : "s") — double-click or ⏎ to finish, click the first point to close")
        } else {
            parts.append(editor.tool.help.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - New-shape settings

    private var textRow: some View {
        HStack(spacing: 8) {
            TextField("Text", text: $editor.textString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .help("The text to place. Lowercase is engraved as capitals in the single-stroke font.")
            LabeledContent("Height") {
                MeasureField(value: $editor.textHeight, kind: .length, minimum: 0.1)
            }
            .help("Cap height of the letters.")
            FontMenu(style: $editor.textStyle)
            Toggle(isOn: $editor.textStyle.bold) { Image(systemName: "bold") }
                .disabled(editor.textStyle.isStrokeFont)
            Toggle(isOn: $editor.textStyle.italic) { Image(systemName: "italic") }
                .disabled(editor.textStyle.isStrokeFont)
        }
        .controlSize(.small)
        .toggleStyle(.button)
        .font(.caption)
    }

    private var holeRow: some View {
        HStack(spacing: 8) {
            LabeledContent("Hole diameter") {
                MeasureField(value: $editor.holeDiameter, kind: .length, minimum: 0.05)
            }
            .help("Diameter of the holes you place. Change one later in the sidebar like any circle.")
        }
        .controlSize(.small)
        .font(.caption)
    }

    private var strokeRow: some View {
        HStack(spacing: 8) {
            LabeledContent("Stroke width") {
                MeasureField(value: $editor.newStrokeWidth, kind: .length, minimum: 0)
            }
            .help("Width of the engraved line for new shapes. 0 = a single pass of the tool; wider strokes are cleared with overlapping passes. Change it later per shape in the sidebar.")
            Text(editor.newStrokeWidth > 0 ? "" : "(one tool pass)")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .font(.caption)
    }
}

/// Picks the font family for new or selected text: the built-in
/// single-stroke font first, then every installed family.
struct FontMenu: View {
    @Binding var style: TextStyle

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Menu {
            Toggle("Single stroke (engraving)", isOn: Binding(
                get: { style.isStrokeFont },
                set: { if $0 { style.family = "" } }
            ))
            Divider()
            ForEach(Self.families, id: \.self) { family in
                Toggle(family, isOn: Binding(
                    get: { style.family == family },
                    set: { if $0 { style.family = family } }
                ))
            }
        } label: {
            Text(style.isStrokeFont ? String(localized: "Single stroke") : style.family)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
        .fixedSize()
        .help("Single stroke: one engraved line per stroke, the classic way to label a board with a fine bit. Installed fonts are engraved along their outlines (letters come out as outlines).")
    }
}

/// A numeric field bound to a millimetre (or mm/min) value, shown and typed
/// in the display unit system, committed on every valid edit.
struct MeasureField: View {
    @Binding var value: Double
    var kind: ParamKind
    var minimum: Double? = nil
    /// Sidebar style: borderless field with a fixed-width unit label, like ParamRow.
    var plain = false
    var width: CGFloat = 60
    /// Commit on Return or when the field loses focus, not on every keystroke
    /// — for values whose every change is expensive (a layer file rewrite).
    var deferred = false

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @State private var text = ""
    @FocusState private var focused: Bool

    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    private func display(_ mm: Double) -> String {
        switch kind {
        case .length: units.length(mm, decimals: units.lengthDecimals + 1)
        case .feed: units.feed(mm)
        case .plain: ParametersStore.format(mm)
        }
    }

    private func parse(_ typed: String) -> Double? {
        guard let entered = Double(typed.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch kind {
        case .length, .feed: return units == .imperial ? entered / units.perMM : entered
        case .plain: return entered
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: plain ? ParamColumns.spacing : 4) {
            Group {
                if plain {
                    TextField("", text: $text).textFieldStyle(.plain)
                } else {
                    TextField("", text: $text).textFieldStyle(.roundedBorder)
                }
            }
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: plain ? ParamColumns.value : width)
            .focused($focused)
            if plain {
                ParamUnit(unitLabel)
            } else {
                Text(unitLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { text = display(value) }
        .onChange(of: text) { if !deferred { apply() } }
        .onSubmit { if deferred { apply() } }
        .onChange(of: value) { if !focused { text = display(value) } }
        .onChange(of: unitRaw) { text = display(value) }
        .onChange(of: focused) {
            guard !focused else { return }
            if deferred { apply() }
            text = display(value)
        }
    }

    private func apply() {
        guard text != display(value), var parsed = parse(text) else { return }
        if let minimum { parsed = max(minimum, parsed) }
        if abs(parsed - value) > 1e-9 { value = parsed }
    }

    private var unitLabel: String {
        switch kind {
        case .length: units.lengthSymbol
        case .feed: units.feedSymbol
        case .plain(let s): s
        }
    }
}
