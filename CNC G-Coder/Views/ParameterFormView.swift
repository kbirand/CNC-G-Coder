import SwiftUI
import Combine

/// Which group of machining parameters the sidebar shows.
enum SettingsSection: String, CaseIterable, Identifiable {
    case isolation, drilling, holeMill, cutout, mask, silk, custom, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolation: "Copper isolation"
        case .drilling: "Drilling"
        case .holeMill: "Hole milling"
        case .cutout: "Board cutout"
        case .mask: "Solder mask"
        case .silk: "Silkscreen"
        case .custom: "Custom layer"
        case .setup: "Machine setup"
        }
    }

    var icon: String {
        switch self {
        case .isolation: "pencil.tip"
        case .drilling: "smallcircle.filled.circle"
        case .holeMill: "circle.dashed"
        case .cutout: "scissors"
        case .mask: "paintbrush.pointed.fill"
        case .silk: "textformat"
        case .custom: "pencil.and.outline"
        case .setup: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .isolation: .blue
        case .drilling: .purple
        case .holeMill: .purple
        case .cutout: .orange
        case .mask: .cyan
        case .silk: .yellow
        case .custom: .red
        case .setup: .gray
        }
    }
}

extension LayerKind {
    /// The settings group that drives this program.
    var settingsSection: SettingsSection? {
        switch self {
        case .front, .back: .isolation
        case .drill: .drilling
        case .millDrill: .holeMill
        case .outline: .cutout
        case .maskTop, .maskBottom: .mask
        case .silkTop, .silkBottom: .silk
        case .custom: .custom
        case .test: nil
        }
    }
}

/// Sidebar: project, the layer picker, and ONLY the selected layer's settings.
/// Picking a layer here also selects the previewed/played program on the right.
struct ParameterFormView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var params: ParametersStore
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    /// While a layer file is being edited, the sidebar shows only its sizes.
    @ObservedObject var layerEditor: LayerFileEditor

    /// Non-empty: the user explicitly opened a settings group that is not tied
    /// to the previewed layer (Machine setup, or a group with no program yet).
    @AppStorage("ui.sectionOverride") private var sectionOverride = ""
    @AppStorage("ui.filesExpanded") private var filesExpanded = false
    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @Environment(\.openWindow) private var openWindow

    // Laser export options — remembered, and applied to whichever layer is selected.
    @AppStorage("export.format") private var exportFormat = ArtworkExport.Format.svg.rawValue
    @AppStorage("export.polarity") private var exportPolarity = ArtworkExport.Polarity.whiteOnBlack.rawValue
    @AppStorage("export.dpi") private var exportDPI = 1000
    @AppStorage("export.frame") private var exportFrame = ArtworkExport.FrameMode.board.rawValue
    /// Shared with the canvas: the export sweeps the path exactly as drawn.
    @AppStorage("previewShowToolWidth") private var showToolWidth = true

    var body: some View {
        Form {
            projectSection
            layerPickerSection
            contextualSections
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onTapGesture { resignTextFieldFocus() }
        .safeAreaInset(edge: .bottom) { warningsFooter }
        // A text field must never steal focus at launch — typing would edit it.
        // The sink takes the window's initial focus instead; the deferred call
        // only acts if a field got it anyway.
        .background(alignment: .topLeading) { FocusSink().frame(width: 1, height: 1) }
        .onAppear {
            DispatchQueue.main.async {
                // Dev hook: `-debugFocusLog 1` records who has focus at launch.
                if UserDefaults.standard.bool(forKey: "debugFocusLog") {
                    let who = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                    try? who.write(toFile: NSTemporaryDirectory() + "cnc-focus.txt", atomically: true, encoding: .utf8)
                }
                resignTextFieldFocus()
            }
        }
    }

    // MARK: - Selection model

    private var currentSection: SettingsSection {
        if let s = SettingsSection(rawValue: sectionOverride) { return s }
        if let kind = playback.selectedLayer, let s = kind.settingsSection { return s }
        return .isolation
    }

    private var selectedLayerForDisplay: ParsedLayer? {
        guard sectionOverride.isEmpty else { return nil }
        return playback.layer
    }

    private func select(layer: LayerKind) {
        playback.selectedLayer = layer
        sectionOverride = ""
    }

    private func select(section: SettingsSection) {
        sectionOverride = section.rawValue
        // If a program for this group exists, bring it into the preview too.
        if section != .setup,
           let match = preview.document?.layers.first(where: { $0.id.settingsSection == section }) {
            playback.selectedLayer = match.id
        }
    }

    /// Settings groups with no generated program to represent them (plus Setup,
    /// which is never a program) — still reachable from the picker.
    private var sectionsWithoutLayers: [SettingsSection] {
        let covered = Set((preview.document?.layers ?? []).compactMap { $0.id.settingsSection })
        // Hole milling only exists as a group while it is switched on.
        return SettingsSection.allCases.filter {
            $0 != .setup && $0 != .custom && !covered.contains($0) && ($0 != .holeMill || params.drillMillLarge)
        }
    }

    // MARK: - Project

    private var detectedSummary: String {
        let files = model.detectedFiles
        let layerCount = [files.front, files.back, files.outline, files.topMask, files.bottomMask,
                          files.topSilk, files.bottomSilk]
            .compactMap { $0 }.count
        var parts: [String] = []
        if layerCount > 0 { parts.append("\(layerCount) layer\(layerCount == 1 ? "" : "s")") }
        if !files.drills.isEmpty { parts.append("\(files.drills.count) drill file\(files.drills.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "No Gerber files recognized" : parts.joined(separator: " · ")
    }

    private var projectSection: some View {
        Section("Project") {
            HStack(spacing: 10) {
                Image(systemName: model.projectURL == nil ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectURL != nil ? model.projectName
                         : (model.projectFolder?.lastPathComponent ?? "No project"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.projectFolder == nil && !model.detectedFiles.hasAnything
                         ? "Open a project, a Gerber folder, or import layers"
                         : detectedSummary + (model.isProjectEdited ? " · edited" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Open") {
                    Button("Open Project…") { model.openProject() }
                    Button("Open Gerber Folder…") { model.openGerberFolder() }
                    Button("Import Layer…") { model.importLayers() }
                    if !model.recentProjects.isEmpty {
                        Divider()
                        ForEach(model.recentProjects, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { model.openProject(at: url) }
                        }
                    }
                }
                .fixedSize()
                .help("Open a saved project, an EasyEDA Gerber export folder (layers are detected by filename), or add single Gerber / drill files as layers.")
            }
            .help(model.projectURL?.path ?? model.projectFolder?.path ?? "")

            if model.projectFolder != nil || model.detectedFiles.hasAnything {
                DisclosureGroup(isExpanded: $filesExpanded) {
                    FileRow(slot: .front, model: model, url: model.detectedFiles.front,
                            help: "Top copper layer (Gerber_TopLayer.GTL). Becomes front-copper.ngc — isolation milling around every trace and pad.")
                    FileRow(slot: .back, model: model, url: model.detectedFiles.back,
                            help: "Bottom copper layer (Gerber_BottomLayer.GBL). Becomes back-copper.ngc, mirrored around the mirror axis so it machines correctly after flipping the board.")
                    FileRow(slot: .outline, model: model, url: model.detectedFiles.outline,
                            help: "Board outline (Gerber_BoardOutlineLayer.GKO). Becomes outline.ngc — the cutout program with holding bridges.")
                    FileRow(slot: .topMask, model: model, url: model.detectedFiles.topMask,
                            help: "Top solder-mask openings (.GTS) — pads/vias that must stay exposed.")
                    FileRow(slot: .bottomMask, model: model, url: model.detectedFiles.bottomMask,
                            help: "Bottom solder-mask openings (.GBS). Mirrored like bottom copper.")
                    FileRow(slot: .topSilk, model: model, url: model.detectedFiles.topSilk,
                            help: "Top printed legend (.GTO) — designators, outlines, text. Becomes top-silkscreen.ngc when Silkscreen is set to Engrave.")
                    FileRow(slot: .bottomSilk, model: model, url: model.detectedFiles.bottomSilk,
                            help: "Bottom printed legend (.GBO). Mirrored like bottom copper.")
                    ForEach(model.detectedFiles.drills, id: \.self) { url in
                        FileRow(slot: .drill, model: model, url: url, drill: url,
                                help: "Excellon drill file. EasyEDA splits PTH / via / NPTH holes into separate files; each becomes its own drill program.")
                    }
                    Button {
                        model.importLayers()
                    } label: {
                        Label("Import Layer…", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Add Gerber or Excellon drill files from anywhere as layers. Right-click a layer to replace or remove it.")
                } label: {
                    Text("Layer files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Layer picker

    private var layerPickerSection: some View {
        Section {
            layerMenu
        } footer: {
            if let doc = preview.document, doc.layers.count > 1 {
                let total = doc.layers.reduce(0) { $0 + $1.totalTime }
                let units = UnitSystem(rawValue: unitRaw) ?? .metric
                Text("Σ est. \(formatDuration(total)) across \(doc.layers.count) programs — rapids assumed \(units.feed(GCodeParser.assumedRapidFeed)) \(units.feedSymbol).")
            }
        }
    }

    private var layerMenu: some View {
        Menu {
            if let doc = preview.document, !doc.layers.isEmpty {
                ForEach(doc.layers) { layer in
                    Toggle(isOn: Binding(
                        get: { sectionOverride.isEmpty && playback.selectedLayer == layer.id },
                        set: { if $0 { select(layer: layer.id) } }
                    )) {
                        Text("\(layer.displayName)  ·  \(formatDuration(layer.totalTime))")
                    }
                }
            }
            // Drawn layers with nothing on them yet have no program; list them
            // here so they can be picked up and drawn on.
            let emptyCustom = model.customLayers.enumerated().filter { pair in
                !(preview.document?.layers.contains { $0.id == .custom(pair.element.ref(index: pair.offset)) } ?? false)
            }
            if !emptyCustom.isEmpty {
                Divider()
                ForEach(emptyCustom, id: \.element.id) { pair in
                    Toggle(isOn: Binding(
                        get: { sectionOverride.isEmpty && playback.selectedLayer?.customRef?.id == pair.element.id },
                        set: { if $0 { model.selectCustomLayer(pair.element.id) } }
                    )) {
                        Label("\(pair.element.name)  ·  empty", systemImage: "pencil.and.outline")
                    }
                }
            }
            Divider()
            Button {
                model.addCustomLayer()
            } label: {
                Label("New Custom Layer", systemImage: "plus")
            }
            let missing = sectionsWithoutLayers
            if !missing.isEmpty {
                Divider()
                ForEach(missing) { section in
                    Toggle(isOn: Binding(
                        get: { currentSection == section && !sectionOverride.isEmpty },
                        set: { if $0 { select(section: section) } }
                    )) {
                        Label(section.title, systemImage: section.icon)
                    }
                }
            }
            Divider()
            Toggle(isOn: Binding(
                get: { currentSection == .setup },
                set: { if $0 { select(section: .setup) } }
            )) {
                Label(SettingsSection.setup.title, systemImage: SettingsSection.setup.icon)
            }
        } label: {
            menuLabel
        }
        .buttonStyle(.plain)
        .help("Choose which program to preview — the settings below follow the selection. Machine setup holds the parameters shared by every program.")
    }

    private var menuLabel: some View {
        HStack(spacing: 10) {
            if let layer = selectedLayerForDisplay {
                Circle()
                    .fill(layer.id.color)
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.displayName)
                        .font(.headline)
                    Text("est. \(formatDuration(layer.totalTime)) · \(layer.moves.count) moves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if sectionOverride.isEmpty, let ref = playback.selectedLayer?.customRef,
                      let layer = model.customLayers.first(where: { $0.id == ref.id }) {
                Circle()
                    .fill(LayerKind.custom(ref).color)
                    .frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layer.name)
                        .font(.headline)
                    Text(layer.shapes.isEmpty ? "Empty — draw with the tools above the preview"
                         : "\(layer.shapes.count) shape\(layer.shapes.count == 1 ? "" : "s") · generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: currentSection.icon)
                    .foregroundStyle(currentSection.tint)
                    .font(.body)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentSection.title)
                        .font(.headline)
                    Text(preview.document == nil ? "No preview yet" : "Settings group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Contextual sections

    @ViewBuilder
    private var contextualSections: some View {
        if layerEditor.target != nil {
            // Editing a layer file: its aperture / drill-size table only. Tool,
            // export and laser settings return when editing ends.
            LayerFileSection(model: model, editor: layerEditor, selected: nil)
        } else {
            layerSections
            cncExportSection
            laserExportSection
        }
    }

    @ViewBuilder
    private var layerSections: some View {
        if sectionOverride.isEmpty, playback.selectedLayer == .test {
            Section {
                Label("Test board loaded", systemImage: "square.grid.3x3.topleft.filled")
            } footer: {
                Text("This program was generated by File → Generate Test Board with its own baked-in parameter sweep. The legend .txt next to the .ngc maps each patch to its depth and feed.")
            }
        } else {
            // The file behind the selected program, with its Edit button.
            if sectionOverride.isEmpty {
                LayerFileSection(model: model, editor: layerEditor, selected: playback.selectedLayer?.editTarget)
            }
            switch currentSection {
            case .isolation: isolationSections; motionSection(.iso)
            case .drilling: drillingSections; motionSection(.drill)
            case .holeMill:
                holeMillSections
                if params.drillMillLarge { motionSection(.holeMill) }
            case .cutout: cutoutSections; motionSection(.cut)
            case .mask:
                maskSections
                if params.maskMode == "gcode" { motionSection(.mask) }
            case .silk:
                silkSections
                if params.silkMode == "gcode" { motionSection(.silk) }
            case .custom: customSections
            case .setup: setupSections
            }
        }
    }

    /// A group's own heights, extra cut and directions (FlatCAM's per-tool
    /// Travel Z, Tool-change Z, Extra Cut, Milling Type, spindle direction).
    /// Empty heights and "Machine default" follow Machine setup.
    @ViewBuilder
    private func motionSection(_ group: ParametersStore.MotionGroup) -> some View {
        Section {
            if group.hasHeights, let travel = params.motionBinding("TravelZ", group),
               let change = params.motionBinding("ChangeZ", group) {
                ParamRow("Travel Z", value: travel, kind: .length,
                         help: "Height for moves between cuts in this program. Empty = Machine setup's Safe Z (shown greyed).",
                         placeholder: params.zSafe)
                ParamRow("Tool-change Z", value: change, kind: .length,
                         help: "Height for the tool-change pause and the end of this program. Empty = Machine setup's Tool-change Z (shown greyed).",
                         placeholder: params.zChange)
            }
            if group.hasExtraCut, let extra = params.motionBinding("ExtraCut", group) {
                ParamRow("Extra cut", value: extra, kind: .length,
                         help: "Every closed contour runs on past its start by this much, so the spot where the loop closes is cut twice and no copper sliver is left there. 0 = off. FlatCAM's default is 0.1–0.2 mm.")
            }
            if group.hasDirection, let direction = params.motionBinding("Direction", group) {
                Picker("Milling direction", selection: direction) {
                    Text("Machine default").tag("")
                    Text("Any").tag("any")
                    Text("Climb").tag("climb")
                    Text("Conventional").tag("conventional")
                }
                .help("Climb or conventional milling for this program. Machine default follows Machine setup → Milling direction.")
            }
            if let spindle = params.motionBinding("SpindleDir", group) {
                Picker("Spindle", selection: spindle) {
                    Text("Clockwise (M3)").tag("cw")
                    Text("Counter-clockwise (M4)").tag("ccw")
                }
                .help("Direction the spindle turns. Almost every bit cuts clockwise; pick counter-clockwise only for left-hand tools.")
            }
        } header: {
            Text("Heights & direction")
        } footer: {
            if group == .holeMill {
                Text("Hole milling runs in the drilling program's pass, so it uses the drilling travel and tool-change heights.")
            }
        }
    }

    @ViewBuilder
    private var customSections: some View {
        if sectionOverride.isEmpty, let ref = playback.selectedLayer?.customRef {
            CustomLayerSections(model: model, editor: model.editor, layerID: ref.id,
                                openLibrary: { openWindow(id: "tools") })
        } else {
            Section {
                Button {
                    model.addCustomLayer()
                } label: {
                    Label("New Custom Layer", systemImage: "plus")
                }
            } header: {
                sectionHeader(.custom)
            } footer: {
                Text("Draw lines, rectangles, circles and text on a layer of your own and machine them with a tool you choose.")
            }
        }
    }

    @ViewBuilder
    private var isolationSections: some View {
        Section {
            toolPicker(.isolation)
            bitShapePicker(params.$millShape)
            if params.millShape == "vbit" {
                ParamRow("V-bit tip", value: params.$millVTip, kind: .length,
                         help: "Flat width at the very point of the V-bit, as printed on the bit.")
                ParamRow("V-bit angle", value: params.$millVAngle, kind: .plain("°"),
                         help: "Included angle of the cone — a \"30°\" bit has 15° each side of the axis.")
                effectiveDiameterRow(params.effectiveMillDiameter)
            } else {
                ParamRow("Tool diameter", value: params.$millDiameter, kind: .length,
                         help: "Cutting diameter of a straight bit. For a V-bit pick V-bit above instead: its width grows with depth and is worked out for you from tip, angle and cut depth.")
            }
            ParamRow("Isolation width", value: params.$isolationWidth, kind: .length,
                     help: "Total width of copper cleared around every trace and pad. Wider = better clearance for soldering but more passes. Machining time scales almost linearly with this. 2–3× the tool diameter is a good starting point.")
            derivedRow("Passes", params.effectivePasses.map { "\($0)" },
                       help: "How many times the bit goes around each trace for this width, bit and overlap (FlatCAM's pass count): 1 pass clears one bit width, each extra pass adds a bit width minus the overlap.")
            ParamRow("Cut depth", value: params.$zWork, kind: .length,
                     help: "Z depth of isolation passes. Copper foil is ~0.035 mm, so −0.05…−0.08 mm cuts through with margin for board unevenness. Cutting deeper makes V-bits cut wider (thinner traces) and wears bits faster.")
            ParamRow("Depth per pass", value: params.$millInfeed, kind: .length,
                     help: "Reach the cut depth in several passes of at most this depth — gentler on fine bits, or for thick copper. 0 cuts the full depth in one pass.")
            ParamRow("Pass overlap", value: params.$millOverlap, kind: .plain("%"),
                     help: "How much neighbouring isolation passes overlap when the isolation width needs more than one. Higher leaves no copper slivers between passes but adds passes; 30–50% is typical.")
        } header: {
            sectionHeader(.isolation)
        } footer: {
            Text("Traces are never cut into — the first pass grazes the trace edge and isolation eats surrounding waste copper only.")
        }
        Section("Feeds & spindle") {
            ParamRow("XY feed", value: params.$millFeed, kind: .feed,
                     help: "Horizontal cutting speed during isolation. Time = path length ÷ feed. 200–300 mm/min works for small V-bits at 12000+ rpm on a rigid machine; reduce if traces chip or bits snap.")
            ParamRow("Z feed", value: params.$millVertFeed, kind: .feed,
                     help: "Plunge speed when the bit enters the copper. Keep slow (40–80 mm/min) — plunging is the hardest move on fine engraving bits.")
            ParamRow("Spindle", value: params.$millSpeed, kind: .plain("rpm"),
                     help: "Spindle speed written as the S-word. Small engraving bits like high RPM (12000+).")
            ParamRow("Spindle dwell", value: params.$millDwell, kind: .plain("s"),
                     help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
        }
    }

    @ViewBuilder
    private var drillingSections: some View {
        Section {
            toolPicker(.drilling)
            ParamRow("Drill depth", value: params.$zDrill, kind: .length,
                     help: "Final Z for every hole. Board thickness plus a small margin into the spoilboard: 1.6 mm stock → −1.8 mm.")
            ParamRow("Peck depth", value: params.$drillPeck, kind: .length,
                     help: "Drill in steps of this depth instead of one plunge: after each step the bit rapids up out of the hole to clear chips, rapids back to just above where it stopped, and feeds on (0.6 on −1.8 mm: −0.6, −1.2, −1.8). Stops chips packing the flutes and snapping small drills in FR4. 0 = one stroke. Drilled holes only — milled holes use their own pass depth.")
            ParamRow("Drill feed", value: params.$drillFeed, kind: .feed,
                     help: "Downward feed while drilling. Carbide PCB drills like fast RPM and moderate feed; 60–120 mm/min is typical.")
            ParamRow("Spindle", value: params.$drillSpeed, kind: .plain("rpm"),
                     help: "Spindle speed while drilling. As high as your spindle allows for clean small holes.")
            ParamRow("Spindle dwell", value: params.$drillDwell, kind: .plain("s"),
                     help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
        } header: {
            sectionHeader(.drilling)
        } footer: {
            Text("Each drill file becomes its own program — change bits at the M0 pauses.")
        }
        DrillBitsSection(params: params, library: model.tools, openLibrary: { openWindow(id: "tools") })
        Section {
            millLargeHolesToggle
            if params.drillMillLarge {
                millHolesFromRow
                LabeledContent("Milled with") {
                    Button(holeMillSummary) { select(section: .holeMill) }
                        .buttonStyle(.link)
                        .help("Open the hole-milling settings: bit, depth, feeds, spindle and dwell.")
                }
            }
        } header: {
            Label("Hole milling", systemImage: "circle.dashed")
        } footer: {
            if params.drillMillLarge {
                holeSplitText
            } else {
                Text("Off: every hole is drilled.")
            }
        }
    }

    private var millLargeHolesToggle: some View {
        Toggle("Mill large holes", isOn: params.$drillMillLarge)
            .help("Holes at or above \"Mill holes from\" are not drilled: an end mill cuts them in circles, spiralling down (helical G2 moves), into a separate \"… milled\" program. For holes larger than any drill you own — e.g. 3–4 mm mounting holes with a 2 mm end mill. Smaller holes in the same file are still drilled.")
    }

    private var millHolesFromRow: some View {
        ParamRow("Mill holes from", value: params.$drillMillFrom, kind: .length,
                 help: "Smallest hole diameter that is milled instead of drilled. At least the milling bit's diameter — a hole the bit's own size is simply plunged.")
    }

    /// This project's hole sizes on either side of "Mill holes from".
    private var holeSplit: (milled: [Double], drilled: [Double]) {
        let sizes = Set(model.drillHoleSizes.values.joined()).sorted()
        guard let from = Double(params.drillMillFrom.trimmingCharacters(in: .whitespaces)) else { return ([], sizes) }
        return (sizes.filter { $0 >= from - 1e-6 }, sizes.filter { $0 < from - 1e-6 })
    }

    /// Which of this project's holes are milled and which drilled, and a
    /// warning only for milled holes the bit is actually too big for.
    private var holeSplitText: Text {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        func list(_ sizes: [Double]) -> String {
            sizes.map { units.length($0, decimals: units.lengthDecimals + 1) }.joined(separator: ", ") + " " + units.lengthSymbol
        }
        let split = holeSplit
        guard !split.milled.isEmpty || !split.drilled.isEmpty else {
            return Text("Holes from this size up are cut in circles, spiralling down, into their own \"… milled\" program; smaller holes stay drilled.")
        }
        var text = Text(split.milled.isEmpty ? "No holes are large enough to mill." : "Milled: \(list(split.milled)).")
        if !split.drilled.isEmpty { text = Text("\(text) Drilled: \(list(split.drilled)).") }
        if let bit = Double(params.holeMillDiameter.trimmingCharacters(in: .whitespaces)) {
            let tooSmall = split.milled.filter { $0 < bit - 1e-6 }
            if !tooSmall.isEmpty {
                let warning = Text(" The \(units.length(bit)) \(units.lengthSymbol) bit is larger than the \(list(tooSmall)) holes — they would come out too big. Raise \"Mill holes from\" or pick a smaller bit.")
                    .foregroundStyle(.orange)
                text = Text("\(text)\(warning)")
            } else if !split.milled.isEmpty {
                text = Text("\(text) The \(units.length(bit)) \(units.lengthSymbol) bit fits all of them.")
            }
        }
        return text
    }

    private var holeMillSummary: String {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        let tool = model.tools.tool(id: params.holeMillToolID)?.name
        let size = Double(params.holeMillDiameter).map { "\(units.length($0)) \(units.lengthSymbol) bit" } ?? "bit"
        return tool ?? size
    }

    /// The "… milled" programs: holes too large to drill, cut in circles.
    @ViewBuilder
    private var holeMillSections: some View {
        Section {
            millLargeHolesToggle
            if params.drillMillLarge {
                millHolesFromRow
                toolPicker(.holeMill)
                ParamRow("Bit diameter", value: params.$holeMillDiameter, kind: .length,
                         help: "Diameter of the end mill (e.g. a 2 mm 2-flute corn bit). The circle is offset inward by half of it, so the hole comes out at its designed size.")
                ParamRow("Depth", value: params.$holeMillDepth, kind: .length,
                         help: "Final Z of the milled holes — board thickness plus a little: 1.6 mm stock → −1.8 mm.")
                ParamRow("Pass depth", value: params.$holeMillInfeed, kind: .length,
                         help: "Depth added per turn of the spiral. 0.3–0.6 mm for a 2 mm end mill in FR4. pcb2gcode spreads the depth evenly, so the real step may be a little smaller.")
            }
        } header: {
            sectionHeader(.holeMill)
        } footer: {
            if params.drillMillLarge {
                holeSplitText
            } else {
                Text("Off: every hole is drilled. Turn this on to mill holes larger than any drill you own.")
            }
        }
        if params.drillMillLarge {
            Section("Feeds & spindle") {
                ParamRow("XY feed", value: params.$holeMillFeed, kind: .feed,
                         help: "Speed around the circle.")
                ParamRow("Z feed", value: params.$holeMillVertFeed, kind: .feed,
                         help: "Plunge speed down to the start of each hole.")
                ParamRow("Spindle", value: params.$holeMillSpeed, kind: .plain("rpm"),
                         help: "Spindle speed for the hole-milling bit.")
                ParamRow("Spindle dwell", value: params.$holeMillDwell, kind: .plain("s"),
                         help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
            }
        }
    }

    @ViewBuilder
    private var cutoutSections: some View {
        Section {
            toolPicker(.cutout)
            ParamRow("Cutter diameter", value: params.$cutterDiameter, kind: .length,
                     help: "Diameter of the end mill that cuts the board outline. The path is offset outward by half of this so the finished board matches the designed outline.")
            ParamRow("Final depth", value: params.$zCut, kind: .length,
                     help: "Deepest cutout pass. Board thickness + ~0.2 mm into the spoilboard: 1.6 mm stock → −1.8 mm.")
            ParamRow("Pass depth", value: params.$cutInfeed, kind: .length,
                     help: "Depth removed per lap around the outline. 0.3–0.5 mm for a 1 mm end mill in FR laminate.")
            ParamRow("XY feed", value: params.$cutFeed, kind: .feed,
                     help: "Horizontal speed while cutting the outline. Full-depth slotting is heavy work — typically slower than isolation feed.")
            ParamRow("Z feed", value: params.$cutVertFeed, kind: .feed,
                     help: "Plunge speed between outline passes.")
            ParamRow("Spindle", value: params.$cutSpeed, kind: .plain("rpm"),
                     help: "Spindle speed for the cutout end mill.")
            ParamRow("Spindle dwell", value: params.$cutDwell, kind: .plain("s"),
                     help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
        } header: {
            sectionHeader(.cutout)
        }
        Section {
            ParamRow("Bridge width", value: params.$bridgeWidth, kind: .length,
                     help: "Width of each holding tab left uncut so the board can't break loose on the final pass. The cutter diameter is compensated — the finished tab really is this wide. Shown white in the preview.")
            ParamRow("Bridge count", value: params.$bridgeCount, kind: .plain(""),
                     help: "Number of holding tabs spread around the outline. 4 suits most small boards.")
            ParamRow("Bridge Z", value: params.$zBridge, kind: .length,
                     help: "Cut depth over the tabs. Tab thickness = board bottom − this value (e.g. −0.8 on 1.6 mm stock leaves 0.8 mm tabs).")
        } header: {
            Text("Holding bridges")
        } footer: {
            Text("Tabs keep the board captive until the last lap — snap it out and file them flush.")
        }
    }

    @ViewBuilder
    private var maskSections: some View {
        Section {
            Picker("Output", selection: params.$maskMode) {
                Text("Off").tag("off")
                Text("CNC etch").tag("gcode")
                Text("Laser SVGs").tag("svg")
            }
            .pickerStyle(.segmented)
            .help("What to do with the solder-mask layers. CNC etch: after painting and curing the mask, mill the openings clear. Laser SVGs: export opening shapes via gerbv for laser ablation. Off: ignore mask layers.")

            if params.maskMode == "gcode" {
                toolPicker(.mask)
                bitShapePicker(params.$maskShape)
                if params.maskShape == "vbit" {
                    ParamRow("V-bit tip", value: params.$maskVTip, kind: .length,
                             help: "Flat width at the point of the V-bit.")
                    ParamRow("V-bit angle", value: params.$maskVAngle, kind: .plain("°"),
                             help: "Included angle of the V-bit's cone.")
                    effectiveDiameterRow(params.effectiveMaskTool)
                } else {
                    ParamRow("Tool diameter", value: params.$maskTool, kind: .length,
                             help: "End mill used to clear mask openings. Openings SMALLER than this cannot be pocketed and are skipped — use a bit no larger than your smallest pad opening (check the Log for warnings).")
                }
                ParamRow("Etch depth", value: params.$maskDepth, kind: .length,
                         help: "How deep to mill the cured mask. It only needs to remove the paint layer, not copper: −0.05…−0.15 mm.")
                ParamRow("Clear width", value: params.$maskClearWidth, kind: .length,
                         help: "How far inward each opening is pocketed. Must be at least HALF the widest opening on the board. Larger values make G-code generation dramatically slower.")
                ParamRow("Pass overlap", value: params.$maskOverlap, kind: .plain("%"),
                         help: "Overlap between the pocketing passes inside each opening. Higher leaves fewer paint ridges; 40% is a good default.")
            }
        } header: {
            sectionHeader(.mask)
        } footer: {
            switch params.maskMode {
            case "gcode":
                Text("After painting and curing the mask, top-mask-etch.ngc / bottom-mask-etch.ngc mill the pad and via openings clear with overlapping pocketing passes.")
            case "svg":
                Text("Mask openings are exported as SVGs (via gerbv) for laser ablation instead of milling.")
            default:
                Text("Solder-mask layers are ignored.")
            }
        }
        if params.maskMode == "gcode" {
            Section("Feeds & spindle") {
                ParamRow("XY feed", value: params.$maskFeed, kind: .feed,
                         help: "Horizontal speed while etching mask. Cured mask is soft; this can usually match or exceed your isolation feed.")
                ParamRow("Z feed", value: params.$maskVertFeed, kind: .feed,
                         help: "Plunge speed into the mask.")
                ParamRow("Spindle", value: params.$maskSpeed, kind: .plain("rpm"),
                         help: "Spindle speed for mask etching.")
                ParamRow("Spindle dwell", value: params.$maskDwell, kind: .plain("s"),
                         help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
            }
        }
    }

    @ViewBuilder
    private var silkSections: some View {
        Section {
            Picker("Output", selection: params.$silkMode) {
                Text("Off").tag("off")
                Text("Engrave").tag("gcode")
            }
            .pickerStyle(.segmented)
            .help("Off: silkscreen layers are ignored (the default — engraving them costs generation and machining time). Engrave: mill the legend strokes themselves, so component outlines and labels end up cut into the board. Either way the layer can be sent to a laser from the export below once a program exists.")

            if params.silkMode == "gcode" {
                toolPicker(.silk)
                bitShapePicker(params.$silkShape)
                if params.silkShape == "vbit" {
                    ParamRow("V-bit tip", value: params.$silkVTip, kind: .length,
                             help: "Flat width at the point of the V-bit.")
                    ParamRow("V-bit angle", value: params.$silkVAngle, kind: .plain("°"),
                             help: "Included angle of the V-bit's cone.")
                    effectiveDiameterRow(params.effectiveSilkTool)
                } else {
                    ParamRow("Tool diameter", value: params.$silkTool, kind: .length,
                             help: "Bit used to engrave the legend. Silkscreen strokes are thin — typically 0.15–0.25 mm — and any stroke NARROWER than this bit cannot be engraved and is skipped, so use a fine V-bit or engraver (check the Log for warnings).")
                }
                ParamRow("Depth", value: params.$silkDepth, kind: .length,
                         help: "How deep to cut the legend. It only has to be visible, not structural: −0.03…−0.08 mm. On a finished board this cuts into the cured solder mask; on bare laminate it marks the substrate.")
                ParamRow("Clear width", value: params.$silkClearWidth, kind: .length,
                         help: "How far inward each stroke is cleared. Just over the widest stroke on the layer is enough — larger values make generation dramatically slower, exactly as with the solder mask.")
                ParamRow("Pass overlap", value: params.$silkOverlap, kind: .plain("%"),
                         help: "Overlap between the passes that clear each stroke.")
            }
        } header: {
            sectionHeader(.silk)
        } footer: {
            switch params.silkMode {
            case "gcode":
                Text("top-silkscreen.ngc / bottom-silkscreen.ngc engrave the printed legend — reference designators, outlines and text — with overlapping passes. Run it last, after the mask.")
            default:
                Text("Silkscreen layers are ignored.")
            }
        }
        if params.silkMode == "gcode" {
            Section("Feeds & spindle") {
                ParamRow("XY feed", value: params.$silkFeed, kind: .feed,
                         help: "Horizontal speed while engraving the legend. The cuts are shallow and short, so this can run faster than isolation milling.")
                ParamRow("Z feed", value: params.$silkVertFeed, kind: .feed,
                         help: "Plunge speed into each stroke. Keep it gentle — fine engraving bits break on the plunge.")
                ParamRow("Spindle", value: params.$silkSpeed, kind: .plain("rpm"),
                         help: "Spindle speed for legend engraving. Fine bits like high RPM.")
                ParamRow("Spindle dwell", value: params.$silkDwell, kind: .plain("s"),
                         help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
            }
        }
    }

    /// One picker for zeroing on/off and where the origin goes.
    private var originSelection: Binding<String> {
        Binding(
            get: { params.zeroStart ? params.originMode : "design" },
            set: { value in
                if value == "design" {
                    params.zeroStart = false
                } else {
                    params.zeroStart = true
                    params.originMode = value
                }
            }
        )
    }

    @ViewBuilder
    private var setupSections: some View {
        Section {
            Picker("X0 Y0 at", selection: originSelection) {
                Text("Lower-left corner").tag("bottomLeft")
                Text("Lower-right corner").tag("bottomRight")
                Text("Upper-left corner").tag("topLeft")
                Text("Upper-right corner").tag("topRight")
                Text("Centre").tag("center")
                Divider()
                Text("Custom point").tag("custom")
                Text("Design origin (no zeroing)").tag("design")
            }
            .help("Where the machine's X0 Y0 is on the board — every program shares it. Corners and Centre are of the whole project (all programs' extent) as the machine sees it on each side, so after flipping you touch off at the same corner of the fixture. Custom point: a point in design coordinates — the same physical spot on both sides, e.g. a registration hole; set it with the Set Origin button in the view. Design origin: the coordinates exactly as EasyEDA exported them.")
            Button {
                playback.placingOrigin = true
            } label: {
                Label("Set Origin in View", systemImage: "scope")
            }
            .disabled(preview.document == nil)
            .help("Then click in the toolpath view where X0 Y0 should be. You can also drag the origin marker there directly. Both snap to the project's corners, centre and drill holes.")
            if params.zeroStart, params.originMode == "custom" {
                ParamRow("Origin X", value: params.$originX, kind: .length,
                         help: "X of the origin in design coordinates — the Gerber/EasyEDA frame, unaffected by tool sizes. The Set Origin button in the view fills this in from a click.")
                ParamRow("Origin Y", value: params.$originY, kind: .length,
                         help: "Y of the origin in design coordinates.")
            }
        } header: {
            Label("Origin", systemImage: "scope")
                .foregroundStyle(.red)
        } footer: {
            Text(originFooter)
        }
        Section {
            Picker("Board flips", selection: params.$mirrorYAxis) {
                Text("Left–right").tag(false)
                Text("Top–bottom").tag(true)
            }
            .pickerStyle(.segmented)
            .help("How you physically turn the board over to machine the back — the back-side programs are ALWAYS mirrored to match, this only picks which way. Left–right: X coordinates are mirrored (turn it like a page, around a vertical line). Top–bottom: Y coordinates are mirrored (tip it towards you, around a horizontal line). Get this wrong and the back side machines as a mirror image of itself.")
            ParamRow("Mirror axis", value: params.$mirrorAxis, kind: .length,
                     help: params.zeroStart
                        ? "Inert unless Origin is set to Design origin: mirroring about this line moves the back programs by twice its value, and the shared origin then shifts them back by exactly the same amount, so the result is identical whatever you put here. Pick Design origin to use it."
                        : "The coordinate line the back side is mirrored around; it positions the mirrored programs directly. Set it to match your fixture — e.g. board width ÷ 2 when you flip around the board's centre line.")
                .disabled(params.zeroStart)
        } header: {
            sectionHeader(.setup)
        } footer: {
            Text("Back-side programs are always mirrored so they machine correctly after you turn the board over; the setting above only says which way you turn it. With an origin set, every program shares one origin per side — zero the machine once for the front programs and once after flipping, and Mirror axis has no effect (the shared origin absorbs it). Verify the flip direction with 'Un-mirror Back Side' in View Options: with the correct axis chosen, the un-mirrored back overlays the front.")
        }
        Section {
            ParamRow("Safe Z", value: params.$zSafe, kind: .length,
                     help: "Height for travel moves between cuts. High enough to clear clamps and board warp. Thanks to the plunge clearance below, extra height here costs almost no machining time. The default for every layer; a layer (or the tool picked for it) can set its own Travel Z.")
            ParamRow("Tool-change Z", value: params.$zChange, kind: .length,
                     help: "Height the spindle retracts to for tool changes (M6/M0 pauses) and at the end of each program — high enough to comfortably swap bits. The default for every layer; a layer can set its own.")
            ParamRow("Rapid feed", value: params.$rapidFeed, kind: .feed,
                     help: "Your machine's G0 speed (FlatCAM's FR Rapids). Only used for time estimates — the machine's own rapid rate is what it actually moves at.")
            ParamRow("Plunge clearance", value: params.$plungeClearance, kind: .length,
                     help: "Vertical moves cross the air at rapid speed and feed only below this height: descents rapid down to it, then plunge at the Z feed; retracts feed up to it, then rapid. Dramatically cuts plunge/drill time (often half the program). Must clear board warp — 0.2–0.5 mm typical; 0 disables.")
        } header: {
            Text("Safety heights")
        } footer: {
            Text("The tool always enters and leaves the material at the programmed Z feed — only air travel becomes rapid.")
        }
        Section {
            Picker("Milling direction", selection: params.$millDirection) {
                Text("Any").tag("any")
                Text("Climb").tag("climb")
                Text("Conventional").tag("conventional")
            }
            .pickerStyle(.segmented)
            .help("Direction the cutter travels relative to its rotation, for isolation, outline, mask and legend milling. Any: pcb2gcode picks whatever gives the shortest path. Climb: cleaner edges on rigid machines with little backlash. Conventional: safer on hobby machines with backlash. Fixing a direction switches off 2-opt path shortening, so programs get a little longer.")
        } header: {
            Text("Milling direction")
        } footer: {
            Text("The default for every milling program; each layer can pick its own under Heights & direction. Spindle dwell is set per layer, next to its spindle speed.")
        }
    }

    private var originFooter: String {
        guard params.zeroStart else {
            return "Programs keep the design's own coordinates — X0 Y0 is wherever EasyEDA put it, often far off the board."
        }
        if params.originMode == "custom" {
            return "The origin is the same physical point on both sides — for a two-sided board, pick a hole on the flip axis or re-find it after flipping. The marker in the view shows where X0 Y0 is."
        }
        return "Zero the machine at this corner of the board before the front programs, and at the same corner of the fixture after flipping. The marker in the view shows where X0 Y0 is — drag it to move the origin."
    }

    // MARK: - CNC export (per layer)

    private var originSummary: String {
        guard params.zeroStart else { return "the design's own origin" }
        return switch params.originMode {
        case "bottomRight": "the lower-right corner"
        case "topLeft": "the upper-left corner"
        case "topRight": "the upper-right corner"
        case "center": "the centre"
        case "custom": "a custom point"
        default: "the lower-left corner"
        }
    }

    @ViewBuilder
    private var cncExportSection: some View {
        if let layer = exportableLayer {
            let stale = preview.isStale || preview.phase == .running
            Section {
                Button {
                    model.exportProgram(layer: layer.id)
                } label: {
                    Label("Export \(layer.id.fileSlug).ngc…", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(stale)
                LabeledContent("X0 Y0 at") {
                    Button(originSummary) { select(section: .setup) }
                        .buttonStyle(.link)
                        .help("Change the origin in Machine setup, or drag the origin marker in the view.")
                }
            } header: {
                Label("CNC export", systemImage: "hammer.fill")
                    .foregroundStyle(.indigo)
            } footer: {
                Text(stale
                     ? "The preview is being updated — export is available once it shows the current settings."
                     : "Saves this program exactly as previewed (est. \(formatDuration(layer.totalTime))). Generate writes every program at once.")
            }
        }
    }

    // MARK: - Laser export (per layer)

    private var exportOptions: ArtworkExport.Options {
        ArtworkExport.Options(
            format: ArtworkExport.Format(rawValue: exportFormat) ?? .svg,
            polarity: ArtworkExport.Polarity(rawValue: exportPolarity) ?? .whiteOnBlack,
            dpi: exportDPI,
            frameMode: ArtworkExport.FrameMode(rawValue: exportFrame) ?? .board,
            toolWidth: showToolWidth
        )
    }

    /// The layer the export acts on: the one being previewed, and only while
    /// the sidebar is actually showing that layer.
    private var exportableLayer: ParsedLayer? {
        guard sectionOverride.isEmpty else { return nil }
        return playback.layer
    }

    private func exportFooter(for layer: ParsedLayer) -> String {
        let frame = switch ArtworkExport.FrameMode(rawValue: exportFrame) ?? .board {
        case .board: "the page is the finished board, so it lines up with the physical PCB"
        case .origin: "the page runs from X0/Y0, so the artwork keeps its position on the machine"
        case .project: "every layer shares one page, so exports overlay in register"
        case .layer: "cropped to this program's own extent"
        }
        if showToolWidth, let diameter = layer.toolDiameter, diameter > 0 {
            let units = UnitSystem(rawValue: unitRaw) ?? .metric
            return "Exports this program's toolpath at 1:1 — the cut swept at "
                + "\(units.length(diameter)) \(units.lengthSymbol), i.e. the copper the mill would clear. "
                + "Rapids are never included; \(frame)."
        }
        return "Exports this program's toolpath at 1:1 as bare centrelines "
            + "(turn on Tool Width in View Options to sweep them at the cutter diameter). "
            + "Rapids are never included; \(frame)."
    }

    @ViewBuilder
    private var laserExportSection: some View {
        if let layer = exportableLayer {
            Section {
                Picker("Format", selection: $exportFormat) {
                    ForEach(ArtworkExport.Format.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("SVG and PDF stay vector — the toolpath as paths a laser can follow; PNG is a bitmap at the resolution below. All three come out at the board's true physical size.")

                Picker("Polarity", selection: $exportPolarity) {
                    ForEach(ArtworkExport.Polarity.allCases) { polarity in
                        Text(polarity.title).tag(polarity.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("Which way round the toolpath is burned. White on black: the cut is white on a black field. Black on white: the inverse. The background is drawn into the file, so the polarity survives import.")

                if exportOptions.format == .png {
                    Picker("Resolution", selection: $exportDPI) {
                        Text("300 dpi").tag(300)
                        Text("600 dpi").tag(600)
                        Text("1000 dpi").tag(1000)
                        Text("2400 dpi").tag(2400)
                    }
                    .help("Pixels per inch of the exported bitmap, written into the PNG so laser software places it at its real size. 1000 dpi resolves a 0.15 mm trace across ~6 pixels.")
                }

                Picker("Frame", selection: $exportFrame) {
                    ForEach(ArtworkExport.FrameMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("What the page spans. Board: the finished board — the cutout path pulled back in by half the cutter, so a 70 × 30 mm board gives a 70 × 30 mm page you can align to the physical PCB. Origin: from X0/Y0 out to the far corner of every program, so placing the file at 0,0 puts it exactly where the mill would cut. Project: that same shared page cropped to the programs. Layer: this program's own extent only.")

                Button {
                    model.exportArtwork(layer: layer.id, options: exportOptions)
                } label: {
                    Label("Export \(layer.displayName)…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isExportingArtwork)
            } header: {
                Label("Laser export", systemImage: "rays")
                    .foregroundStyle(.pink)
            } footer: {
                Text(exportFooter(for: layer))
            }
        }
    }

    private func toolPicker(_ section: SettingsSection) -> some View {
        ToolPickerRow(section: section, params: params, library: model.tools,
                      openLibrary: { openWindow(id: "tools") })
    }

    private func bitShapePicker(_ shape: Binding<String>) -> some View {
        Picker("Bit", selection: shape) {
            Text("Straight").tag("flat")
            Text("V-bit").tag("vbit")
        }
        .pickerStyle(.segmented)
        .help("Straight bits cut their own diameter. V-bits cut wider the deeper they go: enter tip and angle and the width at depth is worked out for you — and follows the depth as you change it.")
    }

    /// A read-only value worked out from other fields.
    private func derivedRow(_ label: String, _ value: String?, help: String) -> some View {
        ParamRowLayout(label) { ParamReadout(value: value ?? "—", unit: "") }
            .help(help)
    }

    private func effectiveDiameterRow(_ diameter: Double?) -> some View {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        return ParamRowLayout("Width at depth") {
            ParamReadout(value: diameter.map { units.length($0, decimals: units.lengthDecimals + 1) } ?? "—",
                         unit: units.lengthSymbol)
        }
        .help("What the V-bit actually cuts at this depth: tip + 2 × |depth| × tan(angle ÷ 2). This is the diameter pcb2gcode is given.")
    }

    private func sectionHeader(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.icon)
            .foregroundStyle(section.tint)
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warningsFooter: some View {
        if model.pcb2gcodeURL == nil || params.validationError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if model.pcb2gcodeURL == nil {
                    WarningPill(text: "pcb2gcode not found — brew install pcb2gcode", color: .red,
                                icon: "exclamationmark.triangle.fill",
                                help: "The G-code generator binary is missing. Install Homebrew, then run: brew install pcb2gcode")
                }
                if let bad = params.validationError {
                    WarningPill(text: "Invalid value: \(bad)", color: .orange,
                                icon: "exclamationmark.circle",
                                help: "This field does not contain a valid number; generation and preview are paused until it is fixed.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// Tinted capsule status chip (fill 0.14, hairline stroke 0.25).
struct WarningPill: View {
    let text: String
    let color: Color
    let icon: String
    var help: String = ""

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
            .help(help)
    }
}

/// "Tool" row at the top of a settings group: picks a library tool and
/// copies its cutting data into the group, and says when the fields have
/// since been edited away from it.
private struct ToolPickerRow: View {
    let section: SettingsSection
    @ObservedObject var params: ParametersStore
    @ObservedObject var library: ToolLibrary
    let openLibrary: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

    var body: some View {
        let current = library.tool(id: params.toolID(for: section))
        let edited = current.map { !params.matches($0, for: section) } ?? false
        LabeledContent("Tool") {
            HStack(spacing: 6) {
                if let current, edited {
                    Button("Edited") { params.applyTool(current, to: section) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("These values no longer match \"\(current.name)\" in the library. Click to restore the tool's values.")
                }
                Menu {
                    let choices = library.tools(for: section)
                    if choices.isEmpty {
                        Text("No \(section.title.lowercased()) tools in the library")
                    }
                    ForEach(choices) { tool in
                        Toggle(isOn: Binding(
                            get: { current?.id == tool.id },
                            set: { _ in params.applyTool(tool, to: section) }
                        )) {
                            Text("\(tool.name)  ·  \(detail(tool))")
                        }
                    }
                    Divider()
                    Toggle("Custom", isOn: Binding(
                        get: { current == nil },
                        set: { _ in params.clearToolID(for: section) }
                    ))
                    Button("Edit Tool Library…", action: openLibrary)
                } label: {
                    Text(current?.name ?? "Custom")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .fixedSize()
            }
        }
        .help("Pick a tool from the library to fill in this layer's diameter, depths, feeds and spindle speed. The fields stay editable afterwards; Custom means they were entered by hand.")
    }

    private func detail(_ tool: MachineTool) -> String {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        let size = "\(units.length(tool.listDiameter)) \(units.lengthSymbol)"
        return tool.shape == .vBit ? "V \(ParametersStore.format(tool.tipAngle))° → \(size)" : "Ø \(size)"
    }
}

/// The drill bits you own. Checked bits replace exact hole sizes: every hole
/// within a bit's range is drilled with it, so a job needs only the bits on
/// hand (pcb2gcode --drills-available).
private struct DrillBitsSection: View {
    @ObservedObject var params: ParametersStore
    @ObservedObject var library: ToolLibrary
    let openLibrary: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

    var body: some View {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        let tolerance = Double(params.drillBitTolerance.trimmingCharacters(in: .whitespaces)) ?? 0.1
        let onHand = params.drillBitIDSet
        Section {
            if library.drills.isEmpty {
                Button("Add drill bits in the Tool Library…", action: openLibrary)
                    .buttonStyle(.link)
            }
            ForEach(library.drills) { bit in
                let range = bit.drillRange(defaultTolerance: tolerance)
                Toggle(isOn: Binding(
                    get: { onHand.contains(bit.id.uuidString) },
                    set: { params.setDrillBit(bit.id, onHand: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bit.name)
                        Text("holes \(units.length(range.lowerBound))–\(units.length(range.upperBound)) \(units.lengthSymbol)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !onHand.isEmpty {
                ParamRow("Bit tolerance", value: params.$drillBitTolerance, kind: .length,
                         help: "For bits without a hole range of their own in the library: the bit drills designed holes up to this much smaller or larger than itself.")
            }
        } header: {
            Text("Bits on hand")
        } footer: {
            Text(onHand.isEmpty
                 ? "None checked: every hole is drilled at its designed size, one bit per size."
                 : "Holes are drilled with the checked bit whose range covers them. Holes no bit covers keep their designed size — the Log names them.")
        }
    }
}

/// One detected-file row inside the Project disclosure.
private struct FileRow: View {
    let slot: LayerSlot
    let model: AppModel
    let url: URL?
    var drill: URL? = nil
    var help: String = ""

    private var editTarget: LayerEditTarget? {
        if let drill { return model.detectedFiles.drills.firstIndex(of: drill).map { .drill($0) } }
        return .layer(slot)
    }

    private var helpText: String {
        guard let url, let origin = model.layerOrigins[url] else { return help }
        if LayerFileEditor.isEditedCopy(url) {
            return help + "\n\nEdited in CNC G-Coder (from \(origin.path)); the original file is unchanged."
        }
        return help + "\n\nPacked in the project (originally \(origin.path))."
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(slot.title)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if let url {
                let edited = LayerFileEditor.isEditedCopy(url)
                Label {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: edited ? "pencil.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(edited ? .orange : .green)
                }
            } else {
                Label {
                    Text("Not found")
                } icon: {
                    Image(systemName: "questionmark.circle").foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .help(helpText)
        .contentShape(Rectangle())
        .contextMenu {
            if url != nil, let target = editTarget {
                Button("Edit…") { model.layerEditor.begin(target) }
                Divider()
            }
            Button(url == nil ? "Choose File…" : "Replace…") { model.replaceLayer(slot, drill: drill) }
            if let url {
                if let origin = model.layerOrigins[url], FileManager.default.fileExists(atPath: origin.path) {
                    Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([origin]) }
                } else {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Remove", role: .destructive) { model.removeLayer(slot, drill: drill) }
            }
        }
    }
}

/// The two columns every numeric row shares, so numbers and units line up
/// down the whole sidebar whether a row is a field or a read-only value.
enum ParamColumns {
    static let value: CGFloat = 68
    static let unit: CGFloat = 44
    static let spacing: CGFloat = 5
}

/// One sidebar row: the label on the left, the value (and unit) columns on
/// the right, all on one text baseline.
struct ParamRowLayout<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ParamColumns.spacing) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 8)
            content()
        }
    }
}

/// The unit column.
struct ParamUnit: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: ParamColumns.unit, alignment: .leading)
    }
}

/// A read-only value in the same columns as the editable fields.
struct ParamReadout: View {
    let value: String
    let unit: String

    var body: some View {
        Text(value)
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: ParamColumns.value, alignment: .trailing)
        ParamUnit(unit)
    }
}

/// What a parameter measures — decides the unit suffix and whether the value
/// is converted for display.
enum ParamKind {
    case length          // stored in mm
    case feed            // stored in mm/min
    case plain(String)   // unitless (rpm, counts)
}

/// A labeled numeric field row for the grouped form.
///
/// Parameters are always STORED in millimetres; when the imperial unit system
/// is selected this row converts on the way out and back. The field keeps its
/// own text so typing is never reformatted mid-edit, and commits every value
/// that parses, so the debounced preview still follows along live.
struct ParamRow: View {
    let label: String
    @Binding var value: String
    let kind: ParamKind
    var help: String = ""
    /// Shown greyed in an empty field — for optional values that fall back
    /// to another one (a layer's travel Z → Machine setup's Safe Z).
    var placeholder: String = ""

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: String, value: Binding<String>, kind: ParamKind, help: String = "", placeholder: String = "") {
        self.label = label
        self._value = value
        self.kind = kind
        self.help = help
        self.placeholder = placeholder
    }

    private var units: UnitSystem { UnitSystem(rawValue: unitRaw) ?? .metric }

    private var unitLabel: String {
        switch kind {
        case .length: units.lengthSymbol
        case .feed: units.feedSymbol
        case .plain(let text): text
        }
    }

    private var converts: Bool {
        guard units == .imperial else { return false }
        switch kind {
        case .length, .feed: return true
        case .plain: return false
        }
    }

    /// The stored (millimetre) string as it should appear in the field.
    private func display(_ stored: String) -> String {
        guard converts, let mm = Double(stored.trimmingCharacters(in: .whitespaces)) else { return stored }
        switch kind {
        case .feed: return units.feed(mm)
        default: return units.length(mm)
        }
    }

    /// The typed text as it should be stored — millimetres, always.
    private func stored(_ typed: String) -> String? {
        guard converts, !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return typed }
        guard let entered = Double(typed.trimmingCharacters(in: .whitespaces)) else { return nil }
        return units.canonicalMM(from: entered)
    }

    var body: some View {
        ParamRowLayout(label) {
            TextField("", text: $text, prompt: placeholder.isEmpty ? nil : Text(display(placeholder)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: ParamColumns.value)
                .focused($focused)
            ParamUnit(unitLabel)
        }
        .help(help)
        .onAppear { text = display(value) }
        // Commit only what the user actually typed. `text` also changes when
        // the field is reformatted (unit switch, preset load) — writing that
        // back would round every parameter to the display precision, so a mere
        // look at the imperial view would quietly rewrite 0.10 mm as 0.09906.
        .onChange(of: text) {
            guard text != display(value), let stored = stored(text) else { return }
            value = stored
        }
        .onChange(of: value) { if !focused { text = display(value) } }
        .onChange(of: unitRaw) { text = display(value) }
    }
}
