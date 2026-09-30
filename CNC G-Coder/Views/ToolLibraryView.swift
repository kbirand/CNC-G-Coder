import SwiftUI
import UniformTypeIdentifiers

/// The tool library window: every cutter you own with the cutting data that
/// goes with it. Layers pick from here (the Tool menu at the top of each
/// settings group); FlatCAM Tools Database exports import straight in.
struct ToolLibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: MachineTool.ID?
    @State private var importMessage: String?

    private var library: ToolLibrary { model.tools }

    var body: some View {
        ToolLibraryContent(library: model.tools, selection: $selection, importMessage: $importMessage,
                           importAction: importFlatCAM)
            .frame(minWidth: 760, minHeight: 520)
    }

    private func importFlatCAM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .json]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a FlatCAM Tools Database export (Tools Database → Export, a JSON .TXT file)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try library.importFlatCAM(from: url)
            importMessage = "Imported \(count) tool\(count == 1 ? "" : "s") from \(url.lastPathComponent)."
            model.appendLog("\nImported \(count) tools from FlatCAM database \(url.path)\n")
        } catch {
            importMessage = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

private struct ToolLibraryContent: View {
    @ObservedObject var library: ToolLibrary
    @Binding var selection: MachineTool.ID?
    @Binding var importMessage: String?
    let importAction: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(MachineTool.Use.allCases) { use in
                        let group = library.tools.filter { $0.use == use }
                            .sorted { ($0.listDiameter, $0.name) < ($1.listDiameter, $1.name) }
                        if !group.isEmpty {
                            Section(use.title) {
                                ForEach(group) { tool in
                                    row(tool).tag(tool.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 4) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add a new tool")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate the selected tool")
                        .disabled(selection == nil)
                    Button { delete() } label: { Image(systemName: "minus") }
                        .help("Delete the selected tool. Layers set from it keep their values.")
                        .disabled(selection == nil)
                    Spacer()
                    Button("Import FlatCAM…", action: importAction)
                        .help("Merge a FlatCAM Tools Database export. Tools with an existing name are updated, the rest added.")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)

            Group {
                if let index = library.tools.firstIndex(where: { $0.id == selection }) {
                    ToolEditor(tool: $library.tools[index])
                        .id(library.tools[index].id)
                } else {
                    ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver",
                                           description: Text("Pick a tool on the left, add one, or import a FlatCAM Tools Database."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if let message = importMessage ?? library.lastError {
                HStack {
                    Text(message).font(.callout)
                    Spacer()
                    Button("Dismiss") { importMessage = nil; library.lastError = nil }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private func row(_ tool: MachineTool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tool.name).lineLimit(1)
            Text(summary(tool))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func summary(_ tool: MachineTool) -> String {
        let length = "\(units.length(tool.listDiameter)) \(units.lengthSymbol)"
        switch tool.shape {
        case .vBit:
            return "V \(ParametersStore.format(tool.tipAngle))° · \(length) at \(units.length(tool.cutDepth))"
        case .ball:
            return "Ball · \(length)"
        case .flat:
            return "Ø \(length) · Z \(units.length(tool.cutDepth))"
        }
    }

    private func add() {
        var tool = MachineTool(name: "New tool")
        if let current = library.tools.first(where: { $0.id == selection }) { tool.use = current.use }
        library.tools.append(tool)
        selection = tool.id
    }

    private func duplicate() {
        guard let current = library.tools.first(where: { $0.id == selection }) else { return }
        var copy = current
        copy.id = UUID()
        copy.name = current.name + " copy"
        library.tools.append(copy)
        selection = copy.id
    }

    private func delete() {
        guard let index = library.tools.firstIndex(where: { $0.id == selection }) else { return }
        library.tools.remove(at: index)
        selection = nil
    }
}

/// Edits one tool in place.
private struct ToolEditor: View {
    @Binding var tool: MachineTool

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    /// Bridges a Double field to ParamRow's string storage (mm, unit-converted for display).
    private func text(_ path: WritableKeyPath<MachineTool, Double>) -> Binding<String> {
        Binding(
            get: { ParametersStore.format(tool[keyPath: path]) },
            set: { if let value = Double($0.trimmingCharacters(in: .whitespaces)) { tool[keyPath: path] = value } }
        )
    }

    private var isDrill: Bool { tool.use == .drilling }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $tool.name)
                Picker("Used for", selection: $tool.use) {
                    ForEach(MachineTool.Use.allCases) { Text($0.title).tag($0) }
                }
                .help("Which layers offer this tool. General tools are offered everywhere; isolation bits are also offered for mask etch and silkscreen.")
                Picker("Shape", selection: $tool.shape) {
                    ForEach(MachineTool.Shape.allCases) { Text($0.title).tag($0) }
                }
                .help("V-bits cut wider the deeper they go; their cutting width is worked out from tip, angle and depth.")
                if tool.shape == .vBit {
                    ParamRow("Tip diameter", value: text(\.tipDiameter), kind: .length,
                             help: "Flat width at the very point of the V-bit, as printed on the bit.")
                    ParamRow("Included angle", value: text(\.tipAngle), kind: .plain("°"),
                             help: "Full angle of the cone: a \"30°\" bit has 15° each side of the axis.")
                    LabeledContent("Width at cut depth") {
                        Text("\(units.length(tool.listDiameter, decimals: units.lengthDecimals + 1)) \(units.lengthSymbol)")
                            .monospacedDigit()
                    }
                    .help("tip + 2 × |cut depth| × tan(angle ÷ 2) — the diameter layers use for this bit.")
                } else {
                    ParamRow("Diameter", value: text(\.diameter), kind: .length,
                             help: "Cutting diameter, as printed on the bit.")
                }
            } header: {
                Text("Tool")
            }

            if isDrill {
                Section {
                    ParamRow("Holes from", value: text(\.toleranceMin), kind: .length,
                             help: "Smallest designed hole this bit may drill. Leave both at 0 to use the drilling layer's bit tolerance around the bit diameter.")
                    ParamRow("Holes up to", value: text(\.toleranceMax), kind: .length,
                             help: "Largest designed hole this bit may drill.")
                } header: {
                    Text("Hole range")
                } footer: {
                    Text("Used when this bit is checked under Bits on hand: every hole in the range is drilled with this bit instead of an exact-size one. FlatCAM calls this the diameter tolerance.")
                }
            }

            Section("Cutting data") {
                ParamRow(isDrill ? "Drill depth" : "Cut depth", value: text(\.cutDepth), kind: .length,
                         help: "Final Z. Copper isolation: −0.05…−0.1 mm. Drills and cutout: board thickness plus ~0.2 mm.")
                ParamRow(isDrill ? "Peck depth" : "Depth per pass", value: text(\.depthPerPass), kind: .length,
                         help: isDrill
                            ? "Drill in pecks of this depth, clearing chips between them. 0 drills straight through."
                            : "Cut in several passes of at most this depth. 0 cuts the full depth in one pass.")
                if !isDrill {
                    ParamRow("XY feed", value: text(\.feedXY), kind: .feed,
                             help: "Horizontal cutting speed.")
                }
                ParamRow(isDrill ? "Drill feed" : "Z feed", value: text(\.feedZ), kind: .feed,
                         help: isDrill ? "Downward feed while drilling." : "Plunge speed.")
                ParamRow("Spindle", value: text(\.spindle), kind: .plain("rpm"),
                         help: "Spindle speed. 0 leaves the layer's own spindle speed unchanged when this tool is picked.")
                ParamRow("Spindle dwell", value: text(\.dwell), kind: .plain("s"),
                         help: "Pause after the spindle starts so it reaches speed before cutting. 0 leaves the layer's own dwell unchanged when this tool is picked.")
                if tool.use != .cutout && !isDrill {
                    ParamRow("Pass overlap", value: text(\.overlap), kind: .plain("%"),
                             help: "How much adjacent clearing passes overlap. Higher = cleaner floor, more passes.")
                }
            }

            Section("Notes") {
                TextField("Notes", text: $tool.notes, axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }
}
