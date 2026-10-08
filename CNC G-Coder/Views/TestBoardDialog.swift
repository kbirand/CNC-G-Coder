import SwiftUI
import AppKit

/// The tests File → Generate Test Board… can make.
enum TestKind: String, CaseIterable, Identifiable {
    case parameters, backlash, holes
    var id: String { rawValue }

    static let storageKey = "testboard.kind"

    var title: String {
        switch self {
        case .parameters: String(localized: "Parameter test board")
        case .backlash: String(localized: "Backlash test")
        case .holes: String(localized: "Hole fit test")
        }
    }

    var systemImage: String {
        switch self {
        case .parameters: "square.grid.3x3.topleft.filled"
        case .backlash: "arrow.left.and.right.square"
        case .holes: "circle.grid.3x3"
        }
    }

    var explanation: String {
        switch self {
        case .parameters:
            String(localized: "Finds the cut depth and feed for production isolation. A grid of patches — rows sweep depth, columns sweep feed — each with 0.2 / 0.3 / 0.4 mm traces. Every trace runs between two probe pads inside a closed isolation moat, so a multimeter tells you whether the trace survived (pad to pad beeps) and whether the isolation is complete (pad to surrounding copper stays silent).")
        case .backlash:
            String(localized: "Measures play in the X and Y axes (75 × 75 mm). Per axis, one straight line is cut in two halves reached from opposite directions: a step where the halves meet is that axis's backlash. A 50 mm square and a Ø30 circle show it too — short sides, an oval. Enter the step in Machine setup → Backlash compensation and cut it again until both lines are straight.")
        case .holes:
            String(localized: "Finds the hole size that fits a pin. Each hole size you list is milled in several variants — the size plus a clearance — the way production mills holes: a spiral down from the surface, then a clean-up circle. Push the pin into each hole of its row and keep the variant that fits the way you want; design the hole at that size. Mill it with the same bit as the real board.")
        }
    }
}

/// File → Generate Test Board…: pick a test, the bit to cut it with, and the
/// test's own settings. Output: a .ngc (plus a legend for the parameter
/// board), loaded straight into the preview.
struct TestBoardDialog: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: ToolLibrary
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TestKind.storageKey) private var kindRaw = TestKind.parameters.rawValue
    /// Per test, a tool-library ID; "" = the project's settings for that
    /// kind of cut (copper isolation, or hole milling for the hole test).
    @AppStorage("testboard.toolID") private var parametersToolID = ""
    @AppStorage("testboard.toolID.backlash") private var backlashToolID = ""
    @AppStorage("testboard.toolID.holes") private var holesToolID = ""

    private var toolID: Binding<String> {
        switch kind {
        case .parameters: $parametersToolID
        case .backlash: $backlashToolID
        case .holes: $holesToolID
        }
    }

    @AppStorage("testboard.width") private var width = "60"
    @AppStorage("testboard.height") private var height = "45"
    @AppStorage("testboard.rows") private var rowsText = "4"
    @AppStorage("testboard.cols") private var colsText = "5"
    @AppStorage("testboard.depthFrom") private var depthFrom = "-0.04"
    @AppStorage("testboard.depthTo") private var depthTo = "-0.12"
    @AppStorage("testboard.feedFrom") private var feedFrom = "120"
    @AppStorage("testboard.feedTo") private var feedTo = "360"
    @AppStorage("testboard.holeSizes") private var holeSizes = "2 3 4"
    @AppStorage("testboard.holeVariants") private var holeVariants = "-0.05 0 0.05 0.10 0.15 0.20"

    init(model: AppModel) {
        self.model = model
        self._library = ObservedObject(wrappedValue: model.tools)
    }

    private var kind: TestKind { TestKind(rawValue: kindRaw) ?? .parameters }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Test")
                .font(.title3.bold())

            HStack(alignment: .top, spacing: 10) {
                ForEach(TestKind.allCases) { option in
                    kindCard(option)
                }
            }

            Text(kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            toolSection

            switch kind {
            case .parameters: parameterSettings
            case .backlash: backlashSettings
            case .holes: holeSettings
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate…") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((kind == .parameters && spec == nil) || (kind == .holes && holeSpec.problem != nil))
                    .help(kind == .backlash
                          ? "Choose where to save the .ngc; it opens in the preview."
                          : "Choose where to save the .ngc; a legend .txt is written next to it and the test opens in the preview.")
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    // MARK: - Test choice

    private func kindCard(_ option: TestKind) -> some View {
        let selected = option == kind
        return Button {
            kindRaw = option.rawValue
        } label: {
            HStack(spacing: 8) {
                Image(systemName: option.systemImage)
                    .font(.title3)
                    .frame(width: 26)
                Text(option.title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tool

    /// The copper isolation settings, as a tool.
    private var isolationTool: MachineTool {
        let p = model.parameters
        func n(_ text: String, _ fallback: Double) -> Double {
            Double(text.trimmingCharacters(in: .whitespaces)) ?? fallback
        }
        var t = MachineTool(name: "Copper isolation settings")
        t.shape = p.millShape == "vbit" ? .vBit : .flat
        t.diameter = n(p.millDiameter, 0.1)
        t.tipDiameter = n(p.millVTip, 0.1)
        t.tipAngle = n(p.millVAngle, 30)
        t.cutDepth = n(p.zWork, -0.1)
        t.feedXY = n(p.millFeed, 300)
        t.feedZ = n(p.millVertFeed, 60)
        t.spindle = n(p.millSpeed, 12000)
        t.dwell = n(p.millDwell, 0)
        t.spindleCCW = p.isoSpindleDir == "ccw"
        return t
    }

    /// The hole-milling settings, as a tool.
    private var holeMillTool: MachineTool {
        let p = model.parameters
        func n(_ text: String, _ fallback: Double) -> Double {
            Double(text.trimmingCharacters(in: .whitespaces)) ?? fallback
        }
        var t = MachineTool(name: "Hole milling settings")
        t.shape = .flat
        t.diameter = n(p.holeMillDiameter, 2)
        t.cutDepth = n(p.holeMillDepth, -1.8)
        t.depthPerPass = n(p.holeMillInfeed, 0.6)
        t.feedXY = n(p.holeMillFeed, 300)
        t.feedZ = n(p.holeMillVertFeed, 100)
        t.spindle = n(p.holeMillSpeed, 12000)
        t.dwell = n(p.holeMillDwell, 0)
        t.spindleCCW = p.holeMillSpindleDir == "ccw"
        return t
    }

    /// What "no library tool" means for the chosen test.
    private var defaultTool: MachineTool { kind == .holes ? holeMillTool : isolationTool }

    /// Milling bits: drills cannot cut these tests.
    private var libraryTools: [MachineTool] {
        library.tools.filter { $0.use != .drilling }
            .sorted { ($0.listDiameter, $0.name) < ($1.listDiameter, $1.name) }
    }

    private var tool: MachineTool {
        library.tool(id: toolID.wrappedValue).flatMap { $0.use == .drilling ? nil : $0 } ?? defaultTool
    }

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Bit", selection: toolID) {
                Text(defaultTool.name).tag("")
                if !libraryTools.isEmpty {
                    Divider()
                    ForEach(libraryTools) { t in
                        Text(t.name).tag(t.id.uuidString)
                    }
                }
            }
            .help("The bit the test is cut with: the project's settings for this kind of cut, or any milling bit from the Tool Library. Mill the test with the exact bit you will use — results only transfer if the tool matches.")
            Text(toolSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolSummary: String {
        let t = tool
        let shape = t.shape == .vBit
            ? String(format: "V-bit %.0f°, %.2f mm tip — cut width follows the depth", t.tipAngle, t.tipDiameter)
            : String(format: "%@ ⌀%.2f mm", t.shape == .ball ? "Ball nose" : "Flat", t.diameter)
        switch kind {
        case .parameters:
            return shape + String(format: " · plunge %.0f mm/min · spindle %.0f rpm", t.feedZ, t.spindle)
        case .backlash:
            return shape + String(format: " · depth %.3f mm · feed %.0f mm/min · plunge %.0f mm/min · spindle %.0f rpm",
                                  -abs(t.cutDepth), t.feedXY, t.feedZ, t.spindle)
        case .holes:
            return shape + String(format: " · depth %.2f mm%@ · feed %.0f mm/min · plunge %.0f mm/min · spindle %.0f rpm",
                                  -abs(t.cutDepth),
                                  t.depthPerPass > 0 ? String(format: " in %.2f mm passes", t.depthPerPass) : "",
                                  t.feedXY, t.feedZ, t.spindle)
        }
    }

    // MARK: - Parameter board

    private var parameterSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Board size")
                    HStack(spacing: 6) {
                        TextField("", text: $width).frame(width: 60)
                        Text("×").foregroundStyle(.secondary)
                        TextField("", text: $height).frame(width: 60)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    .help("Size of the copper-clad scrap you'll mill the test onto.")
                }
                GridRow {
                    Text("Grid")
                    HStack(spacing: 6) {
                        TextField("", text: $colsText).frame(width: 44)
                        Text("feeds ×").foregroundStyle(.secondary)
                        TextField("", text: $rowsText).frame(width: 44)
                        Text("depths").foregroundStyle(.secondary)
                        Button("Suggest") { applySuggestion() }
                            .controlSize(.small)
                            .help("Fill in how many patches comfortably fit this board size. Fewer steps = bigger patches with longer test traces; more steps = finer parameter resolution.")
                    }
                    .help("How many feed columns and depth rows to test. Your choice — patches scale to fill the board.")
                }
                GridRow {
                    Text("Cut depth sweep")
                    HStack(spacing: 6) {
                        TextField("", text: $depthFrom).frame(width: 60)
                        Text("to").foregroundStyle(.secondary)
                        TextField("", text: $depthTo).frame(width: 60)
                        Text("mm (rows)").foregroundStyle(.secondary)
                    }
                    .help("Shallowest to deepest isolation depth to test — one value per row, evenly spread.")
                }
                GridRow {
                    Text("XY feed sweep")
                    HStack(spacing: 6) {
                        TextField("", text: $feedFrom).frame(width: 60)
                        Text("to").foregroundStyle(.secondary)
                        TextField("", text: $feedTo).frame(width: 60)
                        Text("mm/min (columns)").foregroundStyle(.secondary)
                    }
                    .help("Slowest to fastest cutting feed to test — one value per column, evenly spread.")
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(summary)
                .font(.caption)
                .foregroundStyle(spec == nil ? .red : .secondary)

            Text("Isolation width \(model.parameters.isolationWidth) mm, safe Z \(model.parameters.zSafe) mm and plunge clearance \(model.parameters.plungeClearance) mm come from the project settings. A V-bit's cut width is worked out per row from its tip and angle, as in production.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func applySuggestion() {
        guard let w = Double(width), let h = Double(height) else { return }
        let suggestion = TestBoardGenerator.suggestedGrid(width: w, height: h)
        if suggestion.rows >= 2 && suggestion.cols >= 2 {
            rowsText = "\(suggestion.rows)"
            colsText = "\(suggestion.cols)"
        }
    }

    private var spec: TestBoardGenerator.Spec? {
        guard let w = Double(width), let h = Double(height),
              let rows = Int(rowsText), let cols = Int(colsText),
              let dFrom = Double(depthFrom), let dTo = Double(depthTo),
              let fFrom = Double(feedFrom), let fTo = Double(feedTo),
              let isolation = Double(model.parameters.isolationWidth.trimmingCharacters(in: .whitespaces)),
              let zsafe = Double(model.parameters.zSafe.trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0, dFrom < 0, dTo < 0, fFrom > 0, fTo > 0
        else { return nil }
        let s = TestBoardGenerator.Spec(
            width: w, height: h, rows: rows, cols: cols,
            depthFrom: dFrom, depthTo: dTo,
            feedFrom: fFrom, feedTo: fTo,
            tool: tool, isolationWidth: isolation, zsafe: zsafe,
            plungeClearance: Double(model.parameters.plungeClearance.trimmingCharacters(in: .whitespaces)) ?? 0
        )
        return TestBoardGenerator.cellSize(for: s) != nil ? s : nil
    }

    private var summary: String {
        guard let rows = Int(rowsText), let cols = Int(colsText) else {
            return String(localized: "Grid values must be whole numbers.")
        }
        guard let spec, let cell = TestBoardGenerator.cellSize(for: spec) else {
            if rows < 2 || cols < 2 {
                return String(localized: "Grid needs at least 2 × 2 combinations.")
            }
            if rows > TestBoardGenerator.maxRows || cols > TestBoardGenerator.maxCols {
                return String(localized: "Grid is limited to \(TestBoardGenerator.maxCols) feeds × \(TestBoardGenerator.maxRows) depths.")
            }
            return String(localized: "Grid doesn't fit this board — patches need at least ≈8.5 × 8 mm each, with room for a full cut around every trace. Reduce steps or enlarge the board (Suggest fills in what fits).")
        }
        let lastLetter = Character(UnicodeScalar(64 + spec.cols)!)
        return String(format: "Grid: %d feeds (A–%@) × %d depths (1–%d) = %d patches, each %.1f × %.1f mm.",
                      spec.cols, String(lastLetter), spec.rows, spec.rows, spec.cols * spec.rows, cell.w, cell.h)
    }

    // MARK: - Backlash test

    private var backlashSettings: some View {
        let settings = BacklashCompensation.Settings.current
        return Label {
            Text(settings.isActive
                 ? "The test is cut WITH the current compensation (\(settings.summary)): straight lines mean the values are right. To measure the raw play, set both values in Machine setup to 0 first."
                 : "Compensation is off, so the test shows the machine's raw play. Measure the step in each line and enter it in Machine setup → Backlash compensation, then cut the test again to check.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: settings.isActive ? "checkmark.seal" : "info.circle")
                .foregroundStyle(settings.isActive ? .green : .blue)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Hole fit test

    /// Numbers separated by spaces or semicolons ("." for decimals).
    private func numbers(_ text: String) -> [Double]? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "\t" })
        let values = parts.map { Double($0.replacingOccurrences(of: "+", with: "")) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.map { $0! }
    }

    private var holeSpec: TestBoardGenerator.HoleFitSpec {
        TestBoardGenerator.HoleFitSpec(
            diameters: numbers(holeSizes) ?? [], offsets: numbers(holeVariants) ?? [],
            tool: tool,
            zsafe: Double(model.parameters.zSafe.trimmingCharacters(in: .whitespaces)) ?? 3,
            plungeClearance: Double(model.parameters.plungeClearance.trimmingCharacters(in: .whitespaces)) ?? 0)
    }

    private var holeSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Hole sizes")
                    HStack(spacing: 6) {
                        TextField("", text: $holeSizes).frame(width: 200)
                        Text("mm (rows)").foregroundStyle(.secondary)
                    }
                    .help("Nominal hole sizes to test, separated by spaces — e.g. the pins you need to fit: 2 3 4. Use a point for decimals (3.175).")
                }
                GridRow {
                    Text("Variants")
                    HStack(spacing: 6) {
                        TextField("", text: $holeVariants).frame(width: 200)
                        Text("mm added (columns)").foregroundStyle(.secondary)
                    }
                    .help("Clearances added to every size, separated by spaces: each becomes a column. Negative values test a tighter fit.")
                }
            }
            .textFieldStyle(.roundedBorder)

            Text(holeSummary)
                .font(.caption)
                .foregroundStyle(holeSpec.problem == nil ? .secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var holeSummary: String {
        let s = holeSpec
        if numbers(holeSizes) == nil || numbers(holeVariants) == nil {
            return String(localized: "Separate the values with spaces and use a point for decimals, e.g. 2 3 4 and -0.05 0 0.05 0.10.")
        }
        if let problem = s.problem { return problem }
        let count = s.diameters.count * s.offsets.count
        return String(format: "%d holes (%d sizes × %d variants) on a %.0f × %.0f mm piece of scrap. The legend lists every hole's diameter.",
                      count, s.diameters.count, s.offsets.count, ceil(s.size.w), ceil(s.size.h))
    }

    // MARK: - Output

    private func generate() {
        switch kind {
        case .parameters: generateParameterBoard()
        case .backlash: generateBacklashTest()
        case .holes: generateHoleTest()
        }
    }

    private func generateParameterBoard() {
        guard let spec, let result = TestBoardGenerator.generate(spec) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "testboard.ngc"
        panel.title = "Save Test Board G-code"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let legendURL = url.deletingPathExtension().appendingPathExtension("legend.txt")
        do {
            try result.gcode.write(to: url, atomically: true, encoding: .utf8)
            try result.legend.write(to: legendURL, atomically: true, encoding: .utf8)
        } catch {
            model.appendLog("ERROR writing test board: \(error.localizedDescription)\n")
            return
        }
        model.appendLog(BacklashCompensation.apply(.current, files: [url]))

        model.appendLog("\nTest board written to \(url.path)\n")
        model.appendLog(result.legend)
        model.preview.loadExternal(url: url, toolDiameter: spec.widestCut)
        NSWorkspace.shared.activateFileViewerSelecting([url, legendURL])
        dismiss()
    }

    private func generateHoleTest() {
        let spec = holeSpec
        guard let result = TestBoardGenerator.holeFitTest(spec) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hole-fit-test.ngc"
        panel.title = "Save Hole Fit Test G-code"
        panel.directoryURL = model.chosenOutputDir ?? model.projectFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let legendURL = url.deletingPathExtension().appendingPathExtension("legend.txt")
        do {
            try result.gcode.write(to: url, atomically: true, encoding: .utf8)
            try result.legend.write(to: legendURL, atomically: true, encoding: .utf8)
        } catch {
            model.appendLog("ERROR writing the hole fit test: \(error.localizedDescription)\n")
            return
        }
        model.appendLog(BacklashCompensation.apply(.current, files: [url]))
        model.appendLog("\nHole fit test written to \(url.path)\n")
        model.appendLog(result.legend)
        model.preview.loadExternal(url: url, toolDiameter: spec.cut)
        NSWorkspace.shared.activateFileViewerSelecting([url, legendURL])
        dismiss()
    }

    private func generateBacklashTest() {
        let t = tool
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "backlash-test.ngc"
        panel.title = "Save Backlash Test G-code"
        panel.directoryURL = model.chosenOutputDir ?? model.projectFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let safeZ = Double(model.parameters.zSafe.trimmingCharacters(in: .whitespaces)) ?? 3
        do {
            try BacklashCompensation.testProgram(tool: t, safeZ: safeZ).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.appendLog("ERROR writing the backlash test: \(error.localizedDescription)\n")
            return
        }
        model.appendLog("\nBacklash test written to \(url.path) (bit: \(t.name))\n")
        model.appendLog(BacklashCompensation.apply(.current, files: [url]))
        model.preview.loadExternal(url: url, toolDiameter: t.effectiveDiameter(atDepth: t.cutDepth))
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
    }
}
