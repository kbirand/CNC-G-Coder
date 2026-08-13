import SwiftUI
import Combine

/// Which group of machining parameters the sidebar shows.
enum SettingsSection: String, CaseIterable, Identifiable {
    case isolation, drilling, cutout, mask, setup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .isolation: "Copper isolation"
        case .drilling: "Drilling"
        case .cutout: "Board cutout"
        case .mask: "Solder mask"
        case .setup: "Machine setup"
        }
    }

    var icon: String {
        switch self {
        case .isolation: "pencil.tip"
        case .drilling: "smallcircle.filled.circle"
        case .cutout: "scissors"
        case .mask: "paintbrush.pointed.fill"
        case .setup: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .isolation: .blue
        case .drilling: .purple
        case .cutout: .orange
        case .mask: .cyan
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
        let layerCount = [files.front, files.back, files.outline, files.topMask, files.bottomMask]
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
                            help: "Top copper layer (Gerber_TopLayer.GTL). Becomes front.ngc — isolation milling around every trace and pad.")
                    FileRow(label: "Bottom copper", url: model.detectedFiles.back,
                            help: "Bottom copper layer (Gerber_BottomLayer.GBL). Becomes back.ngc, mirrored around the mirror axis so it machines correctly after flipping the board.")
                    FileRow(label: "Board outline", url: model.detectedFiles.outline,
                            help: "Board outline (Gerber_BoardOutlineLayer.GKO). Becomes outline.ngc — the cutout program with holding bridges.")
                    FileRow(label: "Top mask", url: model.detectedFiles.topMask,
                            help: "Top solder-mask openings (.GTS) — pads/vias that must stay exposed.")
                    FileRow(label: "Bottom mask", url: model.detectedFiles.bottomMask,
                            help: "Bottom solder-mask openings (.GBS). Mirrored like bottom copper.")
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
                Text("Σ est. \(formatDuration(total)) across \(doc.layers.count) programs — rapids assumed \(Int(GCodeParser.assumedRapidFeed)) mm/min.")
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
            case .setup: setupSections
            }
        }
    }

    @ViewBuilder
    private var isolationSections: some View {
        Section {
            ParamRow("Tool diameter", value: params.$millDiameter, unit: "mm",
                     help: "EFFECTIVE cutting diameter of the isolation bit at cut depth. V-bits cut wider than their tip: effective ≈ tip + 2 × |cut depth| × tan(half-angle). Example: 0.1 mm tip, 60° V at −0.06 mm ≈ 0.17 mm. Enter the effective value or traces come out thinner than designed.")
            ParamRow("Isolation width", value: params.$isolationWidth, unit: "mm",
                     help: "Total width of copper cleared around every trace and pad. Wider = better clearance for soldering but more passes. Machining time scales almost linearly with this. 2–3× the tool diameter is a good starting point.")
            ParamRow("Cut depth", value: params.$zWork, unit: "mm",
                     help: "Z depth of isolation passes. Copper foil is ~0.035 mm, so −0.05…−0.08 mm cuts through with margin for board unevenness. Cutting deeper makes V-bits cut wider (thinner traces) and wears bits faster.")
        } header: {
            sectionHeader(.isolation)
        } footer: {
            Text("Traces are never cut into — the first pass grazes the trace edge and isolation eats surrounding waste copper only.")
        }
        Section("Feeds & spindle") {
            ParamRow("XY feed", value: params.$millFeed, unit: "mm/min",
                     help: "Horizontal cutting speed during isolation. Time = path length ÷ feed. 200–300 mm/min works for small V-bits at 12000+ rpm on a rigid machine; reduce if traces chip or bits snap.")
            ParamRow("Z feed", value: params.$millVertFeed, unit: "mm/min",
                     help: "Plunge speed when the bit enters the copper. Keep slow (40–80 mm/min) — plunging is the hardest move on fine engraving bits.")
            ParamRow("Spindle", value: params.$millSpeed, unit: "rpm",
                     help: "Spindle speed written as the S-word. Small engraving bits like high RPM (12000+).")
        }
    }

    @ViewBuilder
    private var drillingSections: some View {
        Section {
            ParamRow("Drill depth", value: params.$zDrill, unit: "mm",
                     help: "Final Z for every hole. Board thickness plus a small margin into the spoilboard: 1.6 mm stock → −1.8 mm.")
            ParamRow("Drill feed", value: params.$drillFeed, unit: "mm/min",
                     help: "Downward feed while drilling. Carbide PCB drills like fast RPM and moderate feed; 60–120 mm/min is typical.")
            ParamRow("Spindle", value: params.$drillSpeed, unit: "rpm",
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
            ParamRow("Cutter diameter", value: params.$cutterDiameter, unit: "mm",
                     help: "Diameter of the end mill that cuts the board outline. The path is offset outward by half of this so the finished board matches the designed outline.")
            ParamRow("Final depth", value: params.$zCut, unit: "mm",
                     help: "Deepest cutout pass. Board thickness + ~0.2 mm into the spoilboard: 1.6 mm stock → −1.8 mm.")
            ParamRow("Pass depth", value: params.$cutInfeed, unit: "mm",
                     help: "Depth removed per lap around the outline. 0.3–0.5 mm for a 1 mm end mill in FR laminate.")
            ParamRow("XY feed", value: params.$cutFeed, unit: "mm/min",
                     help: "Horizontal speed while cutting the outline. Full-depth slotting is heavy work — typically slower than isolation feed.")
            ParamRow("Z feed", value: params.$cutVertFeed, unit: "mm/min",
                     help: "Plunge speed between outline passes.")
            ParamRow("Spindle", value: params.$cutSpeed, unit: "rpm",
                     help: "Spindle speed for the cutout end mill.")
        } header: {
            sectionHeader(.cutout)
        }
        Section {
            ParamRow("Bridge width", value: params.$bridgeWidth, unit: "mm",
                     help: "Width of each holding tab left uncut so the board can't break loose on the final pass. The cutter diameter is compensated — the finished tab really is this wide. Shown white in the preview.")
            ParamRow("Bridge count", value: params.$bridgeCount, unit: "",
                     help: "Number of holding tabs spread around the outline. 4 suits most small boards.")
            ParamRow("Bridge Z", value: params.$zBridge, unit: "mm",
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
                ParamRow("Tool diameter", value: params.$maskTool, unit: "mm",
                         help: "End mill used to clear mask openings. Openings SMALLER than this cannot be pocketed and are skipped — use a bit no larger than your smallest pad opening (check the Log for warnings).")
                ParamRow("Etch depth", value: params.$maskDepth, unit: "mm",
                         help: "How deep to mill the cured mask. It only needs to remove the paint layer, not copper: −0.05…−0.15 mm.")
                ParamRow("Clear width", value: params.$maskClearWidth, unit: "mm",
                         help: "How far inward each opening is pocketed. Must be at least HALF the widest opening on the board. Larger values make G-code generation dramatically slower.")
            }
        } header: {
            sectionHeader(.mask)
        } footer: {
            switch params.maskMode {
            case "gcode":
                Text("After painting and curing the mask, mask_top.ngc / mask_bottom.ngc mill the pad and via openings clear with 40% overlapping passes.")
            case "svg":
                Text("Mask openings are exported as SVGs (via gerbv) for laser ablation instead of milling.")
            default:
                Text("Solder-mask layers are ignored.")
            }
        }
        if params.maskMode == "gcode" {
            Section("Feeds & spindle") {
                ParamRow("XY feed", value: params.$maskFeed, unit: "mm/min",
                         help: "Horizontal speed while etching mask. Cured mask is soft; this can usually match or exceed your isolation feed.")
                ParamRow("Z feed", value: params.$maskVertFeed, unit: "mm/min",
                         help: "Plunge speed into the mask.")
                ParamRow("Spindle", value: params.$maskSpeed, unit: "rpm",
                         help: "Spindle speed for mask etching.")
            }
        }
    }

    @ViewBuilder
    private var setupSections: some View {
        Section {
            Toggle("Mirror around Y axis", isOn: params.$mirrorYAxis)
                .help("Which axis the board flips around. Off: mirror X coordinates (flip left–right). On: mirror Y coordinates (flip top–bottom). Match how you physically flip the board.")
            Toggle("Zero project at X0 / Y0", isOn: params.$zeroStart)
                .help("Shift all programs to a shared origin: the project's corner becomes X0/Y0. Front-side programs share one origin and back-side programs share the mirrored one, so copper, drills and masks stay registered — zero the machine once per side, at the same physical board corner.")
            ParamRow("Mirror axis", value: params.$mirrorAxis, unit: "mm",
                     help: "The coordinate line the back side is mirrored around. With 'Zero project at X0/Y0' ON this value is absorbed by the shared origin and can stay 0. With zeroing OFF it positions the mirrored coordinates directly — set it to match your fixture (e.g. board width ÷ 2 when flipping around the board's center line).")
        } header: {
            sectionHeader(.setup)
        } footer: {
            Text("With zeroing on, every program shares one origin per side — zero the machine once for the front programs and once after flipping. Verify the flip direction with 'Flip Back View' in the preview.")
        }
        Section {
            ParamRow("Safe Z", value: params.$zSafe, unit: "mm",
                     help: "Height for travel moves between cuts. High enough to clear clamps and board warp. Thanks to the plunge clearance below, extra height here costs almost no machining time.")
            ParamRow("Tool-change Z", value: params.$zChange, unit: "mm",
                     help: "Height the spindle retracts to for tool changes (M6/M0 pauses) — high enough to comfortably swap bits.")
            ParamRow("Plunge clearance", value: params.$plungeClearance, unit: "mm",
                     help: "Vertical moves cross the air at rapid speed and feed only below this height: descents rapid down to it, then plunge at the Z feed; retracts feed up to it, then rapid. Dramatically cuts plunge/drill time (often half the program). Must clear board warp — 0.2–0.5 mm typical; 0 disables.")
        } header: {
            Text("Safety heights")
        } footer: {
            Text("The tool always enters and leaves the material at the programmed Z feed — only air travel becomes rapid.")
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

/// A labeled numeric field row for the grouped form.
private struct ParamRow: View {
    let label: String
    @Binding var value: String
    let unit: String
    var help: String = ""

    init(_ label: String, value: Binding<String>, unit: String, help: String = "") {
        self.label = label
        self._value = value
        self.unit = unit
        self.help = help
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 5) {
                TextField("", text: $value)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 68)
                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
            }
        }
        .help(help)
    }
}
