import SwiftUI
import Combine

/// Which group of machining parameters the sidebar shows.
enum SettingsSection: String, CaseIterable, Identifiable {
    case isolation, drilling, cutout, mask, silk, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolation: "Copper isolation"
        case .drilling: "Drilling"
        case .cutout: "Board cutout"
        case .mask: "Solder mask"
        case .silk: "Silkscreen"
        case .setup: "Machine setup"
        }
    }

    var icon: String {
        switch self {
        case .isolation: "pencil.tip"
        case .drilling: "smallcircle.filled.circle"
        case .cutout: "scissors"
        case .mask: "paintbrush.pointed.fill"
        case .silk: "textformat"
        case .setup: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .isolation: .blue
        case .drilling: .purple
        case .cutout: .orange
        case .mask: .cyan
        case .silk: .yellow
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
        case .outline: .cutout
        case .maskTop, .maskBottom: .mask
        case .silkTop, .silkBottom: .silk
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

    /// Non-empty: the user explicitly opened a settings group that is not tied
    /// to the previewed layer (Machine setup, or a group with no program yet).
    @AppStorage("ui.sectionOverride") private var sectionOverride = ""
    @AppStorage("ui.filesExpanded") private var filesExpanded = false
    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

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
        .onAppear { DispatchQueue.main.async { resignTextFieldFocus() } }
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
        return SettingsSection.allCases.filter { $0 != .setup && !covered.contains($0) }
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
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectFolder?.lastPathComponent ?? "No folder selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.projectFolder == nil ? "Choose an EasyEDA Gerber export" : detectedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { model.chooseProjectFolder() }
                    .help("Pick the folder exported by EasyEDA (Gerber + drill files). Layers are auto-detected by filename; Generate asks separately where to write the G-code.")
            }
            .help(model.projectFolder?.path ?? "")

            if model.projectFolder != nil {
                DisclosureGroup(isExpanded: $filesExpanded) {
                    FileRow(label: "Top copper", url: model.detectedFiles.front,
                            help: "Top copper layer (Gerber_TopLayer.GTL). Becomes front-copper.ngc — isolation milling around every trace and pad.")
                    FileRow(label: "Bottom copper", url: model.detectedFiles.back,
                            help: "Bottom copper layer (Gerber_BottomLayer.GBL). Becomes back-copper.ngc, mirrored around the mirror axis so it machines correctly after flipping the board.")
                    FileRow(label: "Board outline", url: model.detectedFiles.outline,
                            help: "Board outline (Gerber_BoardOutlineLayer.GKO). Becomes outline.ngc — the cutout program with holding bridges.")
                    FileRow(label: "Top mask", url: model.detectedFiles.topMask,
                            help: "Top solder-mask openings (.GTS) — pads/vias that must stay exposed.")
                    FileRow(label: "Bottom mask", url: model.detectedFiles.bottomMask,
                            help: "Bottom solder-mask openings (.GBS). Mirrored like bottom copper.")
                    FileRow(label: "Top silkscreen", url: model.detectedFiles.topSilk,
                            help: "Top printed legend (.GTO) — designators, outlines, text. Becomes top-silkscreen.ngc when Silkscreen is set to Engrave.")
                    FileRow(label: "Bottom silkscreen", url: model.detectedFiles.bottomSilk,
                            help: "Bottom printed legend (.GBO). Mirrored like bottom copper.")
                    ForEach(model.detectedFiles.drills, id: \.self) { url in
                        FileRow(label: "Drill", url: url,
                                help: "Excellon drill file. EasyEDA splits PTH / via / NPTH holes into separate files; each becomes its own drill program.")
                    }
                } label: {
                    Text("Detected files")
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
        layerSections
        laserExportSection
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
            switch currentSection {
            case .isolation: isolationSections
            case .drilling: drillingSections
            case .cutout: cutoutSections
            case .mask: maskSections
            case .silk: silkSections
            case .setup: setupSections
            }
        }
    }

    @ViewBuilder
    private var isolationSections: some View {
        Section {
            ParamRow("Tool diameter", value: params.$millDiameter, kind: .length,
                     help: "EFFECTIVE cutting diameter of the isolation bit at cut depth. V-bits cut wider than their tip: effective ≈ tip + 2 × |cut depth| × tan(half-angle). Example: 0.1 mm tip, 60° V at −0.06 mm ≈ 0.17 mm. Enter the effective value or traces come out thinner than designed.")
            ParamRow("Isolation width", value: params.$isolationWidth, kind: .length,
                     help: "Total width of copper cleared around every trace and pad. Wider = better clearance for soldering but more passes. Machining time scales almost linearly with this. 2–3× the tool diameter is a good starting point.")
            ParamRow("Cut depth", value: params.$zWork, kind: .length,
                     help: "Z depth of isolation passes. Copper foil is ~0.035 mm, so −0.05…−0.08 mm cuts through with margin for board unevenness. Cutting deeper makes V-bits cut wider (thinner traces) and wears bits faster.")
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
        }
    }

    @ViewBuilder
    private var drillingSections: some View {
        Section {
            ParamRow("Drill depth", value: params.$zDrill, kind: .length,
                     help: "Final Z for every hole. Board thickness plus a small margin into the spoilboard: 1.6 mm stock → −1.8 mm.")
            ParamRow("Drill feed", value: params.$drillFeed, kind: .feed,
                     help: "Downward feed while drilling. Carbide PCB drills like fast RPM and moderate feed; 60–120 mm/min is typical.")
            ParamRow("Spindle", value: params.$drillSpeed, kind: .plain("rpm"),
                     help: "Spindle speed while drilling. As high as your spindle allows for clean small holes.")
        } header: {
            sectionHeader(.drilling)
        } footer: {
            Text("Each drill file becomes its own program — change bits at the M0 pauses.")
        }
    }

    @ViewBuilder
    private var cutoutSections: some View {
        Section {
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
                ParamRow("Tool diameter", value: params.$maskTool, kind: .length,
                         help: "End mill used to clear mask openings. Openings SMALLER than this cannot be pocketed and are skipped — use a bit no larger than your smallest pad opening (check the Log for warnings).")
                ParamRow("Etch depth", value: params.$maskDepth, kind: .length,
                         help: "How deep to mill the cured mask. It only needs to remove the paint layer, not copper: −0.05…−0.15 mm.")
                ParamRow("Clear width", value: params.$maskClearWidth, kind: .length,
                         help: "How far inward each opening is pocketed. Must be at least HALF the widest opening on the board. Larger values make G-code generation dramatically slower.")
            }
        } header: {
            sectionHeader(.mask)
        } footer: {
            switch params.maskMode {
            case "gcode":
                Text("After painting and curing the mask, top-mask-etch.ngc / bottom-mask-etch.ngc mill the pad and via openings clear with 40% overlapping passes.")
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
                ParamRow("Tool diameter", value: params.$silkTool, kind: .length,
                         help: "Bit used to engrave the legend. Silkscreen strokes are thin — typically 0.15–0.25 mm — and any stroke NARROWER than this bit cannot be engraved and is skipped, so use a fine V-bit or engraver (check the Log for warnings).")
                ParamRow("Depth", value: params.$silkDepth, kind: .length,
                         help: "How deep to cut the legend. It only has to be visible, not structural: −0.03…−0.08 mm. On a finished board this cuts into the cured solder mask; on bare laminate it marks the substrate.")
                ParamRow("Clear width", value: params.$silkClearWidth, kind: .length,
                         help: "How far inward each stroke is cleared. Just over the widest stroke on the layer is enough — larger values make generation dramatically slower, exactly as with the solder mask.")
            }
        } header: {
            sectionHeader(.silk)
        } footer: {
            switch params.silkMode {
            case "gcode":
                Text("top-silkscreen.ngc / bottom-silkscreen.ngc engrave the printed legend — reference designators, outlines and text — with 40% overlapping passes. Run it last, after the mask.")
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
            }
        }
    }

    @ViewBuilder
    private var setupSections: some View {
        Section {
            Picker("Board flips", selection: params.$mirrorYAxis) {
                Text("Left–right").tag(false)
                Text("Top–bottom").tag(true)
            }
            .pickerStyle(.segmented)
            .help("How you physically turn the board over to machine the back — the back-side programs are ALWAYS mirrored to match, this only picks which way. Left–right: X coordinates are mirrored (turn it like a page, around a vertical line). Top–bottom: Y coordinates are mirrored (tip it towards you, around a horizontal line). Get this wrong and the back side machines as a mirror image of itself.")
            Toggle("Zero project at X0 / Y0", isOn: params.$zeroStart)
                .help("Shift all programs to a shared origin: the project's corner becomes X0/Y0. Front-side programs share one origin and back-side programs share the mirrored one, so copper, drills and masks stay registered — zero the machine once per side, at the same physical board corner.")
            ParamRow("Mirror axis", value: params.$mirrorAxis, kind: .length,
                     help: params.zeroStart
                        ? "Inert while 'Zero project at X0/Y0' is on: mirroring about this line moves the back programs by twice its value, and the shared origin then shifts them back by exactly the same amount, so the result is identical whatever you put here. Turn zeroing off to use it."
                        : "The coordinate line the back side is mirrored around; it positions the mirrored programs directly. Set it to match your fixture — e.g. board width ÷ 2 when you flip around the board's centre line.")
                .disabled(params.zeroStart)
        } header: {
            sectionHeader(.setup)
        } footer: {
            Text("Back-side programs are always mirrored so they machine correctly after you turn the board over; the setting above only says which way you turn it. With zeroing on, every program shares one origin per side — zero the machine once for the front programs and once after flipping, and Mirror axis has no effect (the shared origin absorbs it). Verify the flip direction with 'Un-mirror Back Side' in View Options: with the correct axis chosen, the un-mirrored back overlays the front.")
        }
        Section {
            ParamRow("Safe Z", value: params.$zSafe, kind: .length,
                     help: "Height for travel moves between cuts. High enough to clear clamps and board warp. Thanks to the plunge clearance below, extra height here costs almost no machining time.")
            ParamRow("Tool-change Z", value: params.$zChange, kind: .length,
                     help: "Height the spindle retracts to for tool changes (M6/M0 pauses) — high enough to comfortably swap bits.")
            ParamRow("Plunge clearance", value: params.$plungeClearance, kind: .length,
                     help: "Vertical moves cross the air at rapid speed and feed only below this height: descents rapid down to it, then plunge at the Z feed; retracts feed up to it, then rapid. Dramatically cuts plunge/drill time (often half the program). Must clear board warp — 0.2–0.5 mm typical; 0 disables.")
        } header: {
            Text("Safety heights")
        } footer: {
            Text("The tool always enters and leaves the material at the programmed Z feed — only air travel becomes rapid.")
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

/// One detected-file row inside the Project disclosure.
private struct FileRow: View {
    let label: String
    let url: URL?
    var help: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if let url {
                Label {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
        .help(help)
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
private struct ParamRow: View {
    let label: String
    @Binding var value: String
    let kind: ParamKind
    var help: String = ""

    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ label: String, value: Binding<String>, kind: ParamKind, help: String = "") {
        self.label = label
        self._value = value
        self.kind = kind
        self.help = help
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
        guard converts else { return typed }
        guard let entered = Double(typed.trimmingCharacters(in: .whitespaces)) else { return nil }
        return units.canonicalMM(from: entered)
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 5) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 68)
                    .focused($focused)
                Text(unitLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
            }
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
