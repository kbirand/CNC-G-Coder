import SwiftUI
import UniformTypeIdentifiers

/// The tool library window: every cutter you own with the cutting data that
/// goes with it. Layers pick from here (the Tool menu at the top of each
/// settings group); FlatCAM Tools Database exports import straight in.
struct ToolLibraryView: View {
    @EnvironmentObject var model: AppModel
    /// Several tools can be selected (shift / ⌘-click, ⌘A) to delete them
    /// together; the editor shows when exactly one is.
    @State private var selection: Set<MachineTool.ID> = []
    @State private var importMessage: String?

    private var library: ToolLibrary { model.tools }

    var body: some View {
        ToolLibraryContent(library: model.tools, params: model.parameters, selection: $selection, importMessage: $importMessage,
                           importAction: importTools, importMakeraAction: importMakeraStudio, exportAction: exportTools,
                           setMaterial: model.setMaterial)
            .frame(minWidth: 760, minHeight: 520)
            .onAppear {
                // Dev hook: `-debugSelectTool "name"` opens with that tool selected.
                if let name = UserDefaults.standard.string(forKey: "debugSelectTool") {
                    selection = library.tools.first { $0.name == name }.map { [$0.id] } ?? []
                }
            }
    }

    private func importTools() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .commaSeparatedText, .zip, .database]
            + [UTType(filenameExtension: "tools"), UTType(filenameExtension: "db")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = String(localized: "Choose a tool library exported from CNC G-Coder (.json), a FlatCAM Tools Database export (.TXT), a Fusion / Makera tool library (.tools, tools.json or .csv), or Makera Studio's makera_library.db.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLibrary(at: url)
    }

    /// Makera Studio's library, straight from the app: the user's copy
    /// (with their own tools and materials) when it can be read, else the
    /// one inside the app bundle, else a panel pointed at it.
    private func importMakeraStudio() {
        for url in [MakeraLibraryImport.userURL, MakeraLibraryImport.bundledURL]
        where FileManager.default.isReadableFile(atPath: url.path) {
            if importLibrary(at: url) { return }
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database] + [UTType(filenameExtension: "db")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = MakeraLibraryImport.bundledURL.deletingLastPathComponent()
        panel.message = String(localized: "Choose Makera Studio's makera_library.db — inside the app (Contents/MacOS) or under ~/Library/Application Support/MakeraStudio, which also holds the tools you added in Studio.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLibrary(at: url)
    }

    @discardableResult
    private func importLibrary(at url: URL) -> Bool {
        do {
            let r = try library.importTools(from: url)
            importMessage = "\(r.source): \(r.added) added, \(r.updated) updated from \(url.lastPathComponent)."
            model.appendLog("\nImported tools from \(url.path) (\(r.source)): \(r.added) added, \(r.updated) updated.\n")
            return true
        } catch {
            importMessage = "Could not import \(url.lastPathComponent): it is neither a CNC G-Coder tool library, a FlatCAM Tools Database, a Fusion / Makera tool library nor a Makera Studio library (\(error.localizedDescription))."
            return false
        }
    }

    private func exportTools() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "CNC G-Coder Tools.json"
        panel.message = String(localized: "Export the whole tool library, to import on another computer.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportLibrary(to: url)
            let count = library.tools.count
            importMessage = "Exported \(count) tool\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            importMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}

private struct ToolLibraryContent: View {
    @ObservedObject var library: ToolLibrary
    @ObservedObject var params: ParametersStore
    @Binding var selection: Set<MachineTool.ID>
    @Binding var importMessage: String?
    /// A whole group about to be deleted, pending confirmation.
    @State private var groupToDelete: String?
    @State private var showToolChanger = false
    @EnvironmentObject private var model: AppModel
    let importAction: () -> Void
    let importMakeraAction: () -> Void
    let exportAction: () -> Void
    let setMaterial: (String) -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    /// Search text and the group shown ("" = all, `mineFilter` = hand-made
    /// tools only): a Makera import is ninety bits, the list needs them.
    @State private var query = ""
    @State private var groupFilter = ""
    private static let mineFilter = "\u{0}mine"

    private var filteredTools: [MachineTool] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return library.tools.filter { tool in
            if groupFilter == Self.mineFilter, !tool.group.isEmpty { return false }
            if !groupFilter.isEmpty, groupFilter != Self.mineFilter, tool.group != groupFilter { return false }
            if needle.isEmpty { return true }
            return tool.name.localizedCaseInsensitiveContains(needle) || tool.group.localizedCaseInsensitiveContains(needle)
                || tool.notes.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Distinct groups of `tools` in the order they should be listed: the
    /// hand-made tools ("") first, then alphabetically.
    static func groups(of tools: [MachineTool]) -> [String] {
        var seen: [String] = []
        for tool in tools where !seen.contains(tool.group) { seen.append(tool.group) }
        return seen.sorted { a, b in
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                List(selection: $selection) {
                    let tools = filteredTools
                    ForEach(MachineTool.Use.allCases) { use in
                        let inUse = tools.filter { $0.use == use }
                        let groups = Self.groups(of: inUse)
                        ForEach(groups, id: \.self) { group in
                            let items = inUse.filter { $0.group == group }
                                .sorted { ($0.listDiameter, $0.name) < ($1.listDiameter, $1.name) }
                            Section {
                                ForEach(items) { tool in
                                    row(tool)
                                        .tag(tool.id)
                                        .contextMenu { rowMenu(tool, group: group) }
                                }
                            } header: {
                                if groups.count == 1, group.isEmpty {
                                    Text(use.title)
                                } else {
                                    Text("\(use.title) · \(group.isEmpty ? String(localized: "My tools") : group)")
                                }
                            }
                        }
                    }
                    if tools.isEmpty, !library.tools.isEmpty {
                        Text("No tool matches.")
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { delete() }
                .confirmationDialog(
                    "Delete every tool of \u{201C}\(groupToDelete ?? "")\u{201D}?",
                    isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Delete \(library.tools.filter { $0.group == (groupToDelete ?? "") }.count) tools", role: .destructive) {
                        if let group = groupToDelete { deleteGroup(group) }
                        groupToDelete = nil
                    }
                    Button("Cancel", role: .cancel) { groupToDelete = nil }
                } message: {
                    Text("Layers set from these tools keep their values. Importing the library again brings the tools back.")
                }
                Divider()
                HStack(spacing: 4) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add a new tool")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate the selected tool")
                        .disabled(selection.count != 1)
                    Button { delete() } label: { Image(systemName: "minus") }
                        .help("Delete the selected tools (shift-click or ⌘-click to select several, ⌘A for all shown; the Delete key works too). Layers set from them keep their values.")
                        .disabled(selection.isEmpty)
                    Spacer()
                    if params.profile.toolChange.automaticSlots != nil {
                        Button { showToolChanger = true } label: {
                            Label(library.rack.isEmpty ? "Tool Changer" : "Tool Changer · \(library.rack.count)", systemImage: "square.grid.3x3.square")
                        }
                        .help("Assign a bit to each slot of the machine's tool changer. Loaded bits keep their slot in every job and come first in the Tool menus.")
                        .sheet(isPresented: $showToolChanger) {
                            ToolChangerView(model: model, params: params)
                        }
                    }
                    // Import, export and Makera's sets in one pull-down: the
                    // bar stays one line however narrow the list is.
                    Menu {
                        Button("Import Library…", action: importAction)
                            .help("Merge tools from a library exported by CNC G-Coder on another computer, from a FlatCAM Tools Database export, from a Fusion / Makera tool library (.tools or .csv), or from Makera Studio's makera_library.db. Tools already here (same tool, or same name) are updated; the rest are added.")
                        Button("Export Library…", action: exportAction)
                            .disabled(library.tools.isEmpty)
                            .help("Save the whole library as a .json file to import on another computer.")
                        Divider()
                        if MakeraLibraryImport.isInstalled {
                            Button("Import from Makera Studio…", action: importMakeraAction)
                                .help("Imports Makera Studio's whole tool library from the app on this Mac: every Carvera bit with its shank, tip, angle and one row of cutting data per material (PCB, Copper, Brass, 6061 and 7075 Aluminum, Delrin, Acrylic…), filed in Studio's groups — plus the tools and materials you added in Studio. Tools with the same name are updated, not duplicated.")
                        }
                        Button(library.missingBundledMakeraTools > 0 ? "Restore Makera Bits (\(library.missingBundledMakeraTools))" : "Restore Makera Bits") {
                            let added = library.addBundledMakeraTools()
                            importMessage = String(localized: "\(added) Makera bits added from the set shipped with the app.")
                        }
                        .disabled(library.missingBundledMakeraTools == 0)
                        .help("Adds the Makera Carvera bits shipped with the app — Makera Studio's library: every bit with its cutting data for fifteen materials, in Studio's groups. Bits already here are left as they are. The library starts with them; this brings back the ones you removed.")
                    } label: {
                        Label("Import / Export", systemImage: "square.and.arrow.down.on.square")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Import or export the library, import Makera Studio's library, restore the bundled Makera bits")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 360)

            Group {
                if selection.count == 1, let index = library.tools.firstIndex(where: { $0.id == selection.first }) {
                    ToolEditor(tool: $library.tools[index], library: library, material: params.material)
                        .id(library.tools[index].id)
                } else if selection.count > 1 {
                    ContentUnavailableView {
                        Label("\(selection.count) Tools Selected", systemImage: "wrench.and.screwdriver")
                    } description: {
                        Text("Delete them together, or pick one to edit it.")
                    } actions: {
                        Button("Delete \(selection.count) Tools", role: .destructive) { delete() }
                    }
                } else {
                    ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver",
                                           description: Text("Pick a tool on the left, add one, or import a tool library."))
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

    /// Search, the group shown and the job's material: one row of pull-downs
    /// under the search field, the way Finder's filter bars read.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query, prompt: Text("Search tools"))
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear the search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .help("Filters the list by name, group or notes.")

            HStack(spacing: 8) {
                Menu {
                    Picker("Group", selection: $groupFilter) {
                        Text("All groups").tag("")
                        Text("My tools").tag(Self.mineFilter)
                        if !library.groups.isEmpty { Divider() }
                        ForEach(library.groups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    filterChip("square.grid.2x2", groupFilter.isEmpty ? String(localized: "All groups")
                               : (groupFilter == Self.mineFilter ? String(localized: "My tools") : groupFilter))
                }
                .help("Imported libraries file their tools under the file's name (\"Makera Drill Bits\"); My tools are the ones made by hand. The Group field in the editor moves a tool.")

                Menu {
                    if library.materials.isEmpty {
                        Text("No presets yet")
                    } else {
                        Picker("Material", selection: Binding(get: { params.material }, set: { setMaterial($0) })) {
                            ForEach(library.materials, id: \.self) { material in
                                Text(material).tag(material)
                            }
                            if !library.materials.contains(where: { $0.caseInsensitiveCompare(params.material) == .orderedSame }) {
                                Text(params.material).tag(params.material)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } label: {
                    filterChip("cube", String(localized: "Material: \(params.material)"))
                }
                .help(library.materials.isEmpty
                      ? "The job's material, also under Machine setup. Presets appear once a tool carries cutting data per material: import a Fusion / Makera library (.tools or .csv). Tools imported before this version have no presets — import the same files again; tools with the same name are updated, not duplicated."
                      : "The job's material, also under Machine setup. Tools with a preset for it (Makera's libraries carry one row per material) apply that row's feeds, plunge, spindle and depth per pass when picked for a layer — like Makera's own tool library — and every layer already set from such a tool is re-applied when it changes.")
                Spacer(minLength: 0)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// A pull-down's face: icon, text, chevron.
    private func filterChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func row(_ tool: MachineTool) -> some View {
        HStack(spacing: 8) {
            ToolSilhouette(geometry: ToolGeometry(tool: tool))
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).lineLimit(1)
                Text(summary(tool))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func summary(_ tool: MachineTool) -> String {
        let length = "\(units.length(tool.listDiameter)) \(units.lengthSymbol)"
        switch tool.shape {
        case .vBit:
            return "V \(ParametersStore.format(tool.tipAngle))° · \(length) at \(units.length(tool.cutDepth))"
        case .ball:
            return String(localized: "Ball · \(length)")
        case .flat:
            return "Ø \(length) · Z \(units.length(tool.cutDepth))"
        }
    }

    /// The context menu of a row: delete what is selected, or a whole group.
    @ViewBuilder
    private func rowMenu(_ tool: MachineTool, group: String) -> some View {
        let count = selection.contains(tool.id) ? selection.count : 1
        Button(count > 1 ? "Delete \(count) Selected Tools" : "Delete \u{201C}\(tool.name)\u{201D}", role: .destructive) {
            if !selection.contains(tool.id) { selection = [tool.id] }
            delete()
        }
        if !group.isEmpty {
            Button("Delete All of \u{201C}\(group)\u{201D}…", role: .destructive) { groupToDelete = group }
        }
    }

    private func add() {
        var tool = MachineTool(name: "New tool")
        if let current = library.tools.first(where: { $0.id == selection.first }) { tool.use = current.use }
        library.tools.append(tool)
        selection = [tool.id]
    }

    private func duplicate() {
        guard selection.count == 1, let current = library.tools.first(where: { $0.id == selection.first }) else { return }
        var copy = current
        copy.id = UUID()
        copy.name = current.name + " copy"
        library.tools.append(copy)
        selection = [copy.id]
    }

    /// Deletes every selected tool at once.
    private func delete() {
        guard !selection.isEmpty else { return }
        library.tools.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func deleteGroup(_ group: String) {
        library.tools.removeAll { $0.group == group }
        selection = []
    }
}

/// Edits one tool in place.
private struct ToolEditor: View {
    @Binding var tool: MachineTool
    @ObservedObject var library: ToolLibrary
    /// The job's material, to mark the preset in force.
    var material: String = ""
    @State private var addingMaterial = false

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

    // Column widths of the preset table.
    private static let nameWidth: CGFloat = 130
    private static let numberWidth: CGFloat = 62

    /// Captions over the preset columns, like the header of Makera's table.
    private var presetHeader: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 14)
            Text("Material").frame(width: Self.nameWidth, alignment: .leading)
            Text("rpm").frame(width: Self.numberWidth)
            if !isDrill { Text("XY feed").frame(width: Self.numberWidth) }
            Text(isDrill ? "Feed" : "Z feed").frame(width: Self.numberWidth)
            if !isDrill {
                Text("Pass").frame(width: Self.numberWidth)
                Text("Overlap %").frame(width: Self.numberWidth)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// One editable preset: name and its numbers.
    private func presetRow(_ index: Int) -> some View {
        let active = tool.presets[index].material.caseInsensitiveCompare(material) == .orderedSame
        return HStack(spacing: 6) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .font(.caption)
                .frame(width: 14)
                .help(active ? "The job's material (Machine setup → Material)" : "")
            TextField("Material", text: $tool.presets[index].material)
                .textFieldStyle(.roundedBorder)
                .frame(width: Self.nameWidth)
            number($tool.presets[index].spindle)
            if !isDrill { number($tool.presets[index].feedXY) }
            number($tool.presets[index].feedZ)
            if !isDrill {
                number($tool.presets[index].depthPerPass, decimals: 3)
                number($tool.presets[index].overlap)
            }
            Spacer()
            Button { tool.presets.remove(at: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this row")
        }
    }

    private func number(_ value: Binding<Double>, decimals: Int = 0) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...decimals)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: Self.numberWidth)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 4) {
                    ToolPreview3D(geometry: ToolGeometry(tool: tool))
                        .frame(height: 150)
                    Text(ToolGeometry(tool: tool).summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("The bit at its real proportions (1/8″ shank, 38 mm). Drag to turn it. The same model follows the toolpath in the 3D preview.")
            }
            Section {
                TextField("Name", text: $tool.name)
                TextField("Group", text: $tool.group, prompt: Text("My tools"))
                    .help("Where the tool is filed in the list: imported libraries use the file's name. Empty = My tools.")
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

            Section {
                if !tool.presets.isEmpty {
                    presetHeader
                    ForEach(tool.presets.indices, id: \.self) { index in
                        presetRow(index)
                    }
                }
                HStack {
                    Button("Add Material…") { addingMaterial = true }
                        .help("Adds a row for a material — to this tool, its group or the whole library — starting from an existing row (a new aluminium alloy from Aluminum) or from the cutting data below.")
                    if !tool.presets.isEmpty {
                        Button("Remove All Rows") { tool.presets = [] }
                            .help("Keeps only the cutting data below, whatever the material.")
                    }
                }
                .buttonStyle(.link)
            } header: {
                Text("Material presets")
            } footer: {
                Text(tool.presets.isEmpty
                     ? "No rows: the cutting data below is used for every material. Makera's libraries bring one row per stock; Add Material… makes your own."
                     : "One row per stock. Machine setup → Material picks the row whose values replace the cutting data below when the tool is applied to a layer (feeds in \(units.feedSymbol), pass in \(units.lengthSymbol)); a material without a row uses the fields below as they are.")
            }
            .sheet(isPresented: $addingMaterial) {
                AddMaterialSheet(library: library, tool: tool)
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

            Section {
                ParamRow("Travel Z", value: text(\.travelZ), kind: .length,
                         help: "Height for moves between cuts with this tool. 0 = Machine setup's Safe Z.")
                ParamRow("Tool-change Z", value: text(\.toolChangeZ), kind: .length,
                         help: "Height for the tool-change pause and the end of the program. 0 = Machine setup's Tool-change Z.")
                if !isDrill {
                    ParamRow("Extra cut", value: text(\.extraCut), kind: .length,
                             help: "Closed cuts run on this far past their start, so no copper sliver is left where the loop closes. 0 = off. Used by isolation, mask, silkscreen and custom layers.")
                    Picker("Milling direction", selection: $tool.direction) {
                        ForEach(MachineTool.Direction.allCases) { Text($0.title).tag($0) }
                    }
                    .help("Climb or conventional. Machine default follows Machine setup → Milling direction.")
                }
                Picker("Spindle", selection: $tool.spindleCCW) {
                    Text("Clockwise (M3)").tag(false)
                    Text("Counter-clockwise (M4)").tag(true)
                }
                .help("Almost every bit cuts clockwise; counter-clockwise is for left-hand tools.")
            } header: {
                Text("Heights & direction")
            } footer: {
                Text("Copied into the layer's Heights & direction when this tool is picked, like the cutting data above.")
            }

            Section {
                ParamRow("Shank diameter", value: text(\.shankDiameter), kind: .length,
                         help: "The shank the collet grips: 3.175 mm (1/8″) for most PCB bits. On a Carvera with the community firmware the tool change names the collet when it differs from the previous bit's.")
                Picker("Rack slot", selection: $tool.preferredSlot) {
                    Text("Automatic").tag(0)
                    ForEach(1...12, id: \.self) { slot in
                        Text("T\(slot)").tag(slot)
                    }
                }
                .help("Where this bit always sits in a tool changer's rack. Automatic: numbered in the order the job's stages use it (Machine setup → Machine can still fix it per project).")
            } header: {
                Text("Tool changer")
            } footer: {
                Text("Only the Makera Carvera profiles use these.")
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

/// Add Material…: a new preset row for one tool, a group or the whole
/// library, started from an existing material's row or the tool's own data.
private struct AddMaterialSheet: View {
    @ObservedObject var library: ToolLibrary
    let tool: MachineTool
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// "" = each tool's own cutting data.
    @State private var basedOn = ""
    @State private var scope = 0

    /// The stock list of Makera's controller, for the names menu.
    static let commonMaterials = [
        "PCB", "Copper", "Brass", "7075 Aluminum", "6061 Aluminum", "Aluminum", "Carbon Fiber",
        "Hardwood", "Softwood", "Bakelite", "Delrin", "Acrylic", "Polycarbonate", "ABS", "Epoxy Tooling",
        "Synthetic Stone", "Plastic"
    ]

    private var scopeValue: ToolLibrary.MaterialScope {
        switch scope {
        case 1: .group(tool.group)
        case 2: .all
        default: .tool(tool.id)
        }
    }

    /// How many tools the chosen scope would give a row.
    private var affected: Int {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return library.tools.filter { candidate in
            switch scopeValue {
            case .tool(let id): guard candidate.id == id else { return false }
            case .group(let group): guard candidate.group == group else { return false }
            case .all: break
            }
            return trimmed.isEmpty || candidate.preset(for: trimmed) == nil
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                HStack {
                    TextField("Material", text: $name, prompt: Text("7075 Aluminum"))
                        .help("The name the Material pickers will show. Any name you like; Makera's libraries use PCB, Copper, Aluminum, Brass…")
                    Menu {
                        ForEach(Self.commonMaterials, id: \.self) { material in
                            Button(material) { name = material }
                                .disabled(library.materials.contains { $0.caseInsensitiveCompare(material) == .orderedSame })
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("The materials of Makera's own tool library. Ones the library already knows are greyed out.")
                }
                Picker("Values from", selection: $basedOn) {
                    Text("Each tool's cutting data").tag("")
                    if !library.materials.isEmpty { Divider() }
                    ForEach(library.materials, id: \.self) { material in
                        Text("Its \(material) row").tag(material)
                    }
                }
                .help("What the new row starts from — a tool without the chosen row falls back to its own cutting data. Edit the numbers afterwards in the table.")
                Picker("Add to", selection: $scope) {
                    Text("This tool only").tag(0)
                    if !tool.group.isEmpty { Text("Every tool of \u{201C}\(tool.group)\u{201D}").tag(1) }
                    Text("Every tool in the library").tag(2)
                }
                .pickerStyle(.radioGroup)
                .help("Tools that already have a row for this material are left alone.")
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Text(affected == 1 ? "1 tool gets the row." : "\(affected) tools get the row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    library.addMaterial(name, basedOn: basedOn.isEmpty ? nil : basedOn, scope: scopeValue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || affected == 0)
            }
            .padding(12)
        }
        .frame(width: 420)
        .onAppear {
            if library.materials.contains(where: { $0.caseInsensitiveCompare("Aluminum") == .orderedSame }) { basedOn = "Aluminum" }
            if !tool.group.isEmpty { scope = 1 }
        }
    }
}
