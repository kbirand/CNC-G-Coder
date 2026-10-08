import SwiftUI
import Combine

/// Which group of machining parameters the sidebar shows.
enum SettingsSection: String, CaseIterable, Identifiable {
    case isolation, drilling, holeMill, cutout, mask, silk, custom, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolation: String(localized: "Copper isolation")
        case .drilling: String(localized: "Drilling")
        case .holeMill: String(localized: "Hole milling")
        case .cutout: String(localized: "Board cutout")
        case .mask: String(localized: "Solder mask")
        case .silk: String(localized: "Silkscreen")
        case .custom: String(localized: "Custom layer")
        case .setup: String(localized: "Machine setup")
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

    /// The groups whose settings belong to a drill file (each has its own).
    var isDrilling: Bool { self == .drilling || self == .holeMill }
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
    /// Machine properties: app-wide, never saved into projects.
    @AppStorage(BacklashCompensation.Settings.xKey) private var backlashX = "0"
    @AppStorage(BacklashCompensation.Settings.yKey) private var backlashY = "0"

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
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
        let layers = preview.document?.layers ?? []
        // Drilled ↔ milled holes of the SAME drill file: its other program,
        // when there is one (the settings stay that file's either way).
        if let sibling = playback.selectedLayer?.drillSibling, sibling.settingsSection == section,
           layers.contains(where: { $0.id == sibling }) {
            select(layer: sibling)
            return
        }
        sectionOverride = section.rawValue
        // If a program for this group exists, bring it into the preview too.
        if section != .setup, !(section.isDrilling && playback.selectedLayer?.drillIndex != nil),
           let match = layers.first(where: { $0.id.settingsSection == section }) {
            playback.selectedLayer = match.id
        }
    }

    /// Settings groups with no generated program to represent them (plus Setup,
    /// which is never a program) — still reachable from the picker.
    private var sectionsWithoutLayers: [SettingsSection] {
        let covered = Set((preview.document?.layers ?? []).compactMap { $0.id.settingsSection })
        // Hole milling only exists as a group while it is switched on.
        return SettingsSection.allCases.filter {
            $0 != .setup && $0 != .custom && !covered.contains($0) && ($0 != .holeMill || anyDrillMillLarge)
        }
    }

    // MARK: - The selected drill file

    /// The drill file whose settings the Drilling and Hole milling groups
    /// show: the one behind the selected drill program (drilled or milled
    /// holes), also while its Hole milling group is opened without a milled
    /// program. Nil: the defaults a new drill file starts from. Every drill
    /// file has its own settings (ParametersStore.drillLayerValues).
    private var drillFile: String? {
        guard currentSection.isDrilling, let kind = playback.selectedLayer else { return nil }
        return model.drillFile(for: kind)
    }

    /// A drilling or hole-milling value of the selected drill file.
    private func drill(_ key: String) -> Binding<String> {
        params.drillBinding(key, file: drillFile)
    }

    private func drillValue(_ key: String) -> String {
        params.drillValue(key, file: drillFile).trimmingCharacters(in: .whitespaces)
    }

    /// "Mill large holes" of the selected drill file.
    private var millLarge: Bool {
        params.drillBool("drillMillLarge", file: drillFile)
    }

    /// Whether any drill file of the project mills its large holes.
    private var anyDrillMillLarge: Bool {
        let files = model.detectedFiles.drills.map(\.lastPathComponent)
        guard !files.isEmpty else { return params.drillMillLarge }
        return files.contains { params.drillBool("drillMillLarge", file: $0) }
    }

    /// The group's header, naming the drill file the settings belong to.
    private func drillHeader(_ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(section)
            Text(drillFile ?? String(localized: "Defaults for new drill files"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Whose settings these are, for the groups' footers.
    private var drillScopeText: String {
        drillFile.map { "These settings belong to \($0) alone — every drill file has its own." }
            ?? String(localized: "Defaults — a drill file added to the project starts from these, then keeps its own settings.")
    }

    // MARK: - Project

    private var detectedSummary: String {
        let files = model.detectedFiles
        let layerCount = [files.front, files.back, files.outline, files.topMask, files.bottomMask,
                          files.topSilk, files.bottomSilk]
            .compactMap { $0 }.count
        var parts: [String] = []
        if layerCount > 0 {
            parts.append(layerCount == 1 ? String(localized: "1 layer") : String(localized: "\(layerCount) layers"))
        }
        if !files.drills.isEmpty {
            let n = files.drills.count
            parts.append(n == 1 ? String(localized: "1 drill file") : String(localized: "\(n) drill files"))
        }
        return parts.isEmpty ? String(localized: "No Gerber files recognized") : parts.joined(separator: " · ")
    }

    private var projectSection: some View {
        Section("Project") {
            HStack(spacing: 10) {
                Image(systemName: model.projectURL == nil ? "folder.fill" : "doc.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectURL != nil ? model.projectName
                         : (model.projectFolder?.lastPathComponent ?? String(localized: "No project")))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.projectFolder == nil && !model.detectedFiles.hasAnything
                         ? String(localized: "Open a project, a Gerber folder, or import layers")
                         : detectedSummary + (model.isProjectEdited ? String(localized: " · edited") : ""))
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
                .help("Open a saved project, an EasyEDA or KiCad Gerber export folder (layers are detected by filename), or add single Gerber / drill files as layers.")
            }
            .help(model.projectURL?.path ?? model.projectFolder?.path ?? "")

            if model.projectFolder != nil || model.detectedFiles.hasAnything {
                DisclosureGroup(isExpanded: $filesExpanded) {
                    FileRow(slot: .front, model: model, url: model.detectedFiles.front,
                            help: String(localized: "Top copper layer (Gerber_TopLayer.GTL). Becomes front-copper.ngc — isolation milling around every trace and pad."))
                    FileRow(slot: .back, model: model, url: model.detectedFiles.back,
                            help: String(localized: "Bottom copper layer (Gerber_BottomLayer.GBL). Becomes back-copper.ngc, mirrored around the mirror axis so it machines correctly after flipping the board."))
                    FileRow(slot: .outline, model: model, url: model.detectedFiles.outline,
                            help: String(localized: "Board outline (Gerber_BoardOutlineLayer.GKO). Becomes outline.ngc — the cutout program with holding bridges."))
                    FileRow(slot: .topMask, model: model, url: model.detectedFiles.topMask,
                            help: String(localized: "Top solder-mask openings (.GTS) — pads/vias that must stay exposed."))
                    FileRow(slot: .bottomMask, model: model, url: model.detectedFiles.bottomMask,
                            help: String(localized: "Bottom solder-mask openings (.GBS). Mirrored like bottom copper."))
                    FileRow(slot: .topSilk, model: model, url: model.detectedFiles.topSilk,
                            help: String(localized: "Top printed legend (.GTO) — designators, outlines, text. Becomes top-silkscreen.ngc when Silkscreen is set to Engrave."))
                    FileRow(slot: .bottomSilk, model: model, url: model.detectedFiles.bottomSilk,
                            help: String(localized: "Bottom printed legend (.GBO). Mirrored like bottom copper."))
                    ForEach(model.detectedFiles.drills, id: \.self) { url in
                        FileRow(slot: .drill, model: model, url: url, drill: url,
                                help: String(localized: "Excellon drill file. EasyEDA (and KiCad with separate PTH / NPTH files) splits holes into several files; each becomes its own drill program."))
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
                        if playback.job?.kind == layer.id {
                            Text("\(layer.displayName)  ·  ▶ running")
                        } else {
                            Text("\(layer.displayName)  ·  \(formatDuration(layer.totalTime))")
                        }
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
                    Text(drillFile.map { String(localized: "Settings of \($0)") } ?? (preview.document == nil ? String(localized: "No preview yet") : String(localized: "Settings group")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                if millLarge { motionSection(.holeMill) }
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
        // The drilling groups' heights and spindle are the drill file's own.
        let file = group == .drill || group == .holeMill ? drillFile : nil
        Section {
            if group.hasHeights, let travel = params.motionBinding("TravelZ", group, drill: file),
               let change = params.motionBinding("ChangeZ", group, drill: file) {
                ParamRow("Travel Z", value: travel, kind: .length,
                         help: "Height for moves between cuts in this program. Empty = Machine setup's Safe Z (shown greyed).",
                         placeholder: params.zSafe)
                ParamRow("Tool-change Z", value: change, kind: .length,
                         help: "Height for the tool-change pause and the end of this program. Empty = Machine setup's Tool-change Z (shown greyed).",
                         placeholder: params.zChange)
            }
            if group.hasExtraCut, let extra = params.motionBinding("ExtraCut", group, drill: file) {
                ParamRow("Extra cut", value: extra, kind: .length,
                         help: "Every closed contour runs on past its start by this much, so the spot where the loop closes is cut twice and no copper sliver is left there. 0 = off. FlatCAM's default is 0.1–0.2 mm.")
            }
            if group.hasDirection, let direction = params.motionBinding("Direction", group, drill: file) {
                Picker("Milling direction", selection: direction) {
                    Text("Machine default").tag("")
                    Text("Any").tag("any")
                    Text("Climb").tag("climb")
                    Text("Conventional").tag("conventional")
                }
                .help("Climb or conventional milling for this program. Machine default follows Machine setup → Milling direction.")
            }
            if let spindle = params.motionBinding("SpindleDir", group, drill: file) {
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
            ParamRow("Drill depth", value: drill("zDrill"), kind: .length,
                     help: "Final Z for every hole. Board thickness plus a small margin into the spoilboard: 1.6 mm stock → −1.8 mm.")
            holeToleranceRow
            ParamRow("Peck depth", value: drill("drillPeck"), kind: .length,
                     help: "Drill in steps of this depth instead of one plunge: after each step the bit rapids up out of the hole to clear chips, rapids back to just above where it stopped, and feeds on (0.6 on −1.8 mm: −0.6, −1.2, −1.8). Stops chips packing the flutes and snapping small drills in FR4. 0 = one stroke. Drilled holes only — milled holes use their own pass depth.")
            ParamRow("Drill feed", value: drill("drillFeed"), kind: .feed,
                     help: "Downward feed while drilling. Carbide PCB drills like fast RPM and moderate feed; 60–120 mm/min is typical.")
            ParamRow("Spindle", value: drill("drillSpeed"), kind: .plain("rpm"),
                     help: "Spindle speed while drilling. As high as your spindle allows for clean small holes.")
            ParamRow("Spindle dwell", value: drill("drillDwell"), kind: .plain("s"),
                     help: "Pause after the spindle starts so it is at full speed before the bit touches the board (and after it stops, before a tool change). Written as G4 P in seconds, as GRBL and LinuxCNC expect. 0 = no pause.")
        } header: {
            drillHeader(.drilling)
        } footer: {
            Text("\(drillScopeText) Each drill file becomes its own program — change bits at the M0 pauses.")
        }
        DrillBitsSection(params: params, library: model.tools, drill: drillFile, openLibrary: { openWindow(id: "tools") })
        Section {
            millLargeHolesToggle
            if millLarge {
                millHolesFromRow
                LabeledContent("Milled with") {
                    Button(holeMillSummary) { select(section: .holeMill) }
                        .buttonStyle(.link)
                        .help("Open this drill file's hole-milling settings: bit, depth, feeds, spindle and dwell.")
                }
            }
        } header: {
            Label("Hole milling", systemImage: "circle.dashed")
        } footer: {
            if millLarge {
                holeSplitText
            } else {
                Text("Off: every hole in this file is drilled.")
            }
        }
    }

    private var millLargeHolesToggle: some View {
        Toggle("Mill large holes", isOn: params.drillBoolBinding("drillMillLarge", file: drillFile))
            .help("Holes at or above \"Mill holes from\" are not drilled: an end mill cuts them in circles, spiralling down (helical G2 moves), into a separate \"… milled\" program. For holes larger than any drill you own — e.g. 3–4 mm mounting holes with a 2 mm end mill. Smaller holes in the same file are still drilled. This switch belongs to this drill file; other drill files keep their own setting.")
    }

    private var holeToleranceRow: some View {
        ParamRow("Hole tolerance", value: drill("drillHoleAllowance"), kind: .length,
                 help: "Added to every hole's designed diameter before bits are picked and large holes are milled: 0.125 on a 0.8 mm hole drills 0.925 mm. Drilled FR4 closes up a little, so leads and pins still fit. 0 = holes exactly as designed.")
    }

    private var millHolesFromRow: some View {
        ParamRow("Mill holes from", value: drill("drillMillFrom"), kind: .length,
                 help: "Smallest hole diameter that is milled instead of drilled. At least the milling bit's diameter — a hole the bit's own size is simply plunged.")
    }

    /// The selected drill file's hole sizes (every drill file's, for the
    /// defaults) on either side of "Mill holes from".
    private var holeSplit: (milled: [Double], drilled: [Double]) {
        let allowance = Double(drillValue("drillHoleAllowance")) ?? 0
        let holes: [Double]
        if let drillFile, let url = model.detectedFiles.drills.first(where: { $0.lastPathComponent == drillFile }) {
            holes = model.drillHoleSizes[url] ?? []
        } else {
            holes = Array(model.drillHoleSizes.values.joined())
        }
        let sizes = Set(holes.map { (($0 + allowance) * 1000).rounded() / 1000 }).sorted()
        guard let from = Double(drillValue("drillMillFrom")) else { return ([], sizes) }
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
        if let bit = Double(drillValue("holeMillDiameter")) {
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
        let tool = model.tools.tool(id: drillValue("holeMillToolID"))?.name
        let size = Double(drillValue("holeMillDiameter")).map { "\(units.length($0)) \(units.lengthSymbol) bit" } ?? "bit"
        return tool ?? size
    }

    /// The "… milled" programs: holes too large to drill, cut in circles.
    @ViewBuilder
    private var holeMillSections: some View {
        Section {
            millLargeHolesToggle
            if millLarge {
                millHolesFromRow
                holeToleranceRow
                toolPicker(.holeMill)
                ParamRow("Bit diameter", value: drill("holeMillDiameter"), kind: .length,
                         help: "Diameter of the end mill (e.g. a 2 mm 2-flute corn bit). The circle is offset inward by half of it, so the hole comes out at its designed size.")
                ParamRow("Depth", value: drill("holeMillDepth"), kind: .length,
                         help: "Final Z of the milled holes — board thickness plus a little: 1.6 mm stock → −1.8 mm.")
                ParamRow("Pass depth", value: drill("holeMillInfeed"), kind: .length,
                         help: "Depth added per turn of the spiral. 0.3–0.6 mm for a 2 mm end mill in FR4. The depth is spread evenly, so the real step may be a little smaller.")
            }
        } header: {
            drillHeader(.holeMill)
        } footer: {
            if millLarge {
                Text("\(drillScopeText) \(holeSplitText)")
            } else {
                Text("\(drillScopeText) Off: every hole in this file is drilled. Turn this on to mill holes larger than any drill you own.")
            }
        }
        if millLarge {
            Section("Feeds & spindle") {
                ParamRow("XY feed", value: drill("holeMillFeed"), kind: .feed,
                         help: "Speed around the circle.")
                ParamRow("Z feed", value: drill("holeMillVertFeed"), kind: .feed,
                         help: "Plunge speed down to the start of each hole.")
                ParamRow("Spindle", value: drill("holeMillSpeed"), kind: .plain("rpm"),
                         help: "Spindle speed for the hole-milling bit.")
                ParamRow("Spindle dwell", value: drill("holeMillDwell"), kind: .plain("s"),
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
                if params.maskClearAuto {
                    derivedRow("Clear width", params.automaticMaskClearWidth.map { display(length: $0) } ?? "—",
                               help: "How far inward each opening is pocketed: half the widest opening in the mask layers plus a little, so every opening is cleared right to its centre and no wider (wider makes generation dramatically slower).")
                } else {
                    ParamRow("Clear width", value: params.$maskClearWidth, kind: .length,
                             help: "How far inward each opening is pocketed. Must be at least HALF the widest opening on the board, or the middle of large openings stays covered. Larger values make G-code generation dramatically slower.")
                }
                Toggle("Clear width from the mask layers", isOn: params.$maskClearAuto)
                    .help("Measure the widest opening in the mask layers and clear by half of it, so every opening is cleared to its centre. Off: enter the clear width yourself.")
                ParamRow("Pass overlap", value: params.$maskOverlap, kind: .plain("%"),
                         help: "Overlap between the pocketing passes inside each opening. Higher leaves fewer paint ridges; 40% is a good default.")
            }
        } header: {
            sectionHeader(.mask)
        } footer: {
            switch params.maskMode {
            case "gcode":
                if params.maskClearAuto, let widest = params.widestMaskOpening {
                    Text("Widest opening \(display(length: ParametersStore.format(widest))). After painting and curing the mask, top-mask-etch.ngc / bottom-mask-etch.ngc mill the pad and via openings clear with overlapping pocketing passes.")
                } else {
                    Text("After painting and curing the mask, top-mask-etch.ngc / bottom-mask-etch.ngc mill the pad and via openings clear with overlapping pocketing passes.")
                }
            case "svg":
                Text("Mask openings are exported as 1:1 SVGs for laser ablation instead of milling.")
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
            .help("Where the machine's X0 Y0 is on the board — every program shares it. Corners and Centre are of the whole project (all programs' extent) as the machine sees it on each side, so after flipping you touch off at the same corner of the fixture. Custom point: a point in design coordinates — the same physical spot on both sides, e.g. a registration hole; set it with the Set Origin button in the view. Design origin: the coordinates exactly as the EDA tool exported them.")
            Button {
                playback.placingOrigin = true
            } label: {
                Label("Set Origin in View", systemImage: "scope")
            }
            .disabled(preview.document == nil)
            .help("Then click in the toolpath view where X0 Y0 should be. You can also drag the origin marker there directly. Both snap to the project's corners, centre and drill holes.")
            if params.zeroStart, params.originMode == "custom" {
                ParamRow("Origin X", value: params.$originX, kind: .length,
                         help: "X of the origin in design coordinates — the Gerber frame as exported, unaffected by tool sizes. The Set Origin button in the view fills this in from a click.")
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
        if !ToolLocator.isAppStoreBuild {
            Section {
                Picker("Engine", selection: params.$engine) {
                    Text("pcb2gcode").tag("pcb2gcode")
                    Text("Native").tag("native")
                }
                .pickerStyle(.segmented)
                .help("pcb2gcode: the proven open-source generator, built into the app. Native: the app's own toolpath engine (Clipper2 geometry) — faster, no external program. Both write programs the same way, so every setting applies to either.")
            } header: {
                Text("Toolpath engine")
            } footer: {
                Text(params.engine == "native"
                     ? "Native: isolation, outline, drilling, hole milling, mask and silkscreen are computed in the app."
                     : (model.pcb2gcodeURL == nil ? "pcb2gcode is not available in this build — the native engine is used."
                        : "pcb2gcode \(ToolLocator.pcb2gcodeIsBundled ? "(built into the app)" : "(Homebrew)") turns the Gerbers into programs."))
            }
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
            .help("Direction the cutter travels relative to its rotation, for isolation, outline, mask and legend milling. Any: whichever gives the shortest path. Climb: cleaner edges on rigid machines with little backlash. Conventional: safer on hobby machines with backlash. Fixing a direction switches off 2-opt path shortening, so programs get a little longer.")
        } header: {
            Text("Milling direction")
        } footer: {
            Text("The default for every milling program; each layer can pick its own under Heights & direction. Spindle dwell is set per layer, next to its spindle speed.")
        }
        Section {
            ParamRow("X backlash", value: $backlashX, kind: .length,
                     help: "Travel the X axis loses each time it reverses — the step the test cut's vertical line shows. 0 = off.")
            ParamRow("Y backlash", value: $backlashY, kind: .length,
                     help: "Travel the Y axis loses each time it reverses — the step the test cut's horizontal line shows. 0 = off.")
            Button {
                model.openBacklashTest()
            } label: {
                Label("Backlash Test…", systemImage: "ruler")
                    .frame(maxWidth: .infinity)
            }
            .help("Opens Generate Test on the backlash test: per axis, one line cut in two halves reached from opposite directions, plus a 50 mm square and a Ø30 circle, with the bit of your choice. It is compensated with the values above: adjust them until both lines come out straight.")
            Button {
                model.compensateGCodeFile()
            } label: {
                Label("Compensate a G-code File…", systemImage: "doc.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!BacklashCompensation.Settings.current.isActive)
            .help("Writes a compensated copy of a program made outside this app.")
        } header: {
            Text("Backlash compensation")
        } footer: {
            Text(backlashFooter)
        }
    }

    private var backlashFooter: String {
        let settings = BacklashCompensation.Settings.current
        guard settings.isActive else {
            return String(localized: "For axes with play: a value here is added to every program the app writes — Generate, Export, test boards — not to the preview. Belongs to this machine, not the project. Fixing the play mechanically is always better.")
        }
        return String(localized: "On (\(settings.summary)): every program the app writes gets a short take-up move wherever that axis reverses; the preview and G-code tab show the uncompensated program. Set back to 0 once the machine is repaired.")
    }

    private var originFooter: String {
        guard params.zeroStart else {
            return String(localized: "Programs keep the design's own coordinates — X0 Y0 is wherever the EDA tool put it, often far off the board (KiCad: the page corner).")
        }
        if params.originMode == "custom" {
            return String(localized: "The origin is the same physical point on both sides — for a two-sided board, pick a hole on the flip axis or re-find it after flipping. The marker in the view shows where X0 Y0 is.")
        }
        return String(localized: "Zero the machine at this corner of the board before the front programs, and at the same corner of the fixture after flipping. The marker in the view shows where X0 Y0 is — drag it to move the origin.")
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
                // Shows the Machine panel with this layer loaded in its
                // Program section; the panel's own Send button starts the job.
                Button {
                    model.requestedMachineLayer = layer.id
                    model.showMachineInspector = true
                } label: {
                    Label("Send \(layer.id.fileSlug).ngc to Machine…", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .disabled(stale || model.machine.isStreaming)
                .help(model.machine.isStreaming
                      ? "A program is already being sent — stop it in the Machine panel first."
                      : "Stream this program to the connected controller from the Machine panel: connect, zero, probe, then Send.")
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
        case .board: String(localized: "the page is the finished board, so it lines up with the physical PCB")
        case .origin: String(localized: "the page runs from X0/Y0, so the artwork keeps its position on the machine")
        case .project: String(localized: "every layer shares one page, so exports overlay in register")
        case .layer: String(localized: "cropped to this program's own extent")
        }
        if showToolWidth, let diameter = layer.toolDiameter, diameter > 0 {
            let units = UnitSystem(rawValue: unitRaw) ?? .metric
            return String(localized: "Exports this program's toolpath at 1:1 — the cut swept at \(units.length(diameter)) \(units.lengthSymbol), i.e. the copper the mill would clear. Rapids are never included; \(frame).")
        }
        return String(localized: "Exports this program's toolpath at 1:1 as bare centrelines (turn on Tool Width in View Options to sweep them at the cutter diameter). Rapids are never included; \(frame).")
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
                      drill: section.isDrilling ? drillFile : nil,
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
    private func derivedRow(_ label: LocalizedStringKey, _ value: String?, help: LocalizedStringKey) -> some View {
        ParamRowLayout(label) { ParamReadout(value: value ?? "—", unit: "") }
            .help(help)
    }

    /// A stored millimetre value in the chosen unit system, with its unit.
    private func display(length mm: String) -> String {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        guard let value = Double(mm) else { return mm }
        return "\(units.length(value, decimals: units.lengthDecimals + 1)) \(units.lengthSymbol)"
    }

    private func effectiveDiameterRow(_ diameter: Double?) -> some View {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        return ParamRowLayout("Width at depth") {
            ParamReadout(value: diameter.map { units.length($0, decimals: units.lengthDecimals + 1) } ?? "—",
                         unit: units.lengthSymbol)
        }
        .help("What the V-bit actually cuts at this depth: tip + 2 × |depth| × tan(angle ÷ 2). This is the diameter the toolpaths are computed with.")
    }

    private func sectionHeader(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.icon)
            .foregroundStyle(section.tint)
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warningsFooter: some View {
        let missingEngine = model.pcb2gcodeURL == nil && params.engine != "native" && !ToolLocator.isAppStoreBuild
        if missingEngine || params.validationError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if missingEngine {
                    WarningPill(text: "pcb2gcode missing — using the native engine", color: .orange,
                                icon: "exclamationmark.triangle.fill",
                                help: "This copy of the app has no pcb2gcode inside (it was built on a Mac without it), so the native toolpath engine is used. Machine setup → Toolpath engine.")
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
    var help: LocalizedStringKey = ""

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
    /// Drilling groups: the drill file whose settings the tool fills in.
    var drill: String? = nil
    let openLibrary: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

    var body: some View {
        let current = library.tool(id: params.toolID(for: section, drill: drill))
        let edited = current.map { !params.matches($0, for: section, drill: drill) } ?? false
        LabeledContent("Tool") {
            HStack(spacing: 6) {
                if let current, edited {
                    Button("Edited") { params.applyTool(current, to: section, drill: drill) }
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
                            set: { _ in params.applyTool(tool, to: section, drill: drill) }
                        )) {
                            Text("\(tool.name)  ·  \(detail(tool))")
                        }
                    }
                    Divider()
                    Toggle("Custom", isOn: Binding(
                        get: { current == nil },
                        set: { _ in params.clearToolID(for: section, drill: drill) }
                    ))
                    Button("Edit Tool Library…", action: openLibrary)
                } label: {
                    Text(current?.name ?? String(localized: "Custom"))
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
    /// The drill file these bits are for (nil: the defaults).
    let drill: String?
    let openLibrary: () -> Void

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

    var body: some View {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        let tolerance = Double(params.drillValue("drillBitTolerance", file: drill).trimmingCharacters(in: .whitespaces)) ?? 0.1
        let onHand = params.drillBitIDSet(file: drill)
        Section {
            if library.drills.isEmpty {
                Button("Add drill bits in the Tool Library…", action: openLibrary)
                    .buttonStyle(.link)
            }
            ForEach(library.drills) { bit in
                let range = bit.drillRange(defaultTolerance: tolerance)
                Toggle(isOn: Binding(
                    get: { onHand.contains(bit.id.uuidString) },
                    set: { params.setDrillBit(bit.id, onHand: $0, file: drill) }
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
                ParamRow("Bit tolerance", value: params.drillBinding("drillBitTolerance", file: drill), kind: .length,
                         help: "For bits without a hole range of their own in the library: the bit drills designed holes up to this much smaller or larger than itself.")
            }
        } header: {
            Text("Bits on hand")
        } footer: {
            Text(onHand.isEmpty
                 ? "None checked: every hole in this file is drilled at its designed size, one bit per size."
                 : "Holes in this file are drilled with the checked bit whose range covers them. Holes no bit covers keep their designed size — the Log names them.")
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
            return help + "\n\n" + String(localized: "Edited in CNC G-Coder (from \(origin.path)); the original file is unchanged.")
        }
        return help + "\n\n" + String(localized: "Packed in the project (originally \(origin.path)).")
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
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    init(_ label: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
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
    let label: LocalizedStringKey
    @Binding var value: String
    let kind: ParamKind
    var help: LocalizedStringKey = ""
    /// Shown greyed in an empty field — for optional values that fall back
    /// to another one (a layer's travel Z → Machine setup's Safe Z).
    var placeholder: String = ""

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: LocalizedStringKey, value: Binding<String>, kind: ParamKind, help: LocalizedStringKey = "", placeholder: String = "") {
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
