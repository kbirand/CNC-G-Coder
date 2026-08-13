import SwiftUI
import AppKit

/// File → Generate Test Board…: builds a parameter-calibration board.
/// Rows sweep cut depth, columns sweep XY feed; each patch carries production-
/// style trace tests and a pad. Grid size is suggested from the board size but
/// fully user-adjustable. Output: a .ngc file + a legend .txt, loaded straight
/// into the preview.
struct TestBoardDialog: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("testboard.width") private var width = "60"
    @AppStorage("testboard.height") private var height = "45"
    @AppStorage("testboard.rows") private var rowsText = "4"
    @AppStorage("testboard.cols") private var colsText = "5"
    @AppStorage("testboard.depthFrom") private var depthFrom = "-0.04"
    @AppStorage("testboard.depthTo") private var depthTo = "-0.12"
    @AppStorage("testboard.feedFrom") private var feedFrom = "120"
    @AppStorage("testboard.feedTo") private var feedTo = "360"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate Test Board")
                .font(.title3.bold())
            Text("A grid of test patches — each machined with its own depth/feed combination — to find the best parameters for production. Rows sweep depth, columns sweep feed. Every patch contains 0.2 / 0.3 / 0.4 mm trace tests and a pad, isolated exactly like production (multi-pass, using your isolation width).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            Text("Uses the current isolation tool ⌀\(model.parameters.millDiameter) mm, isolation width \(model.parameters.isolationWidth) mm, spindle \(model.parameters.millSpeed) rpm, plunge \(model.parameters.millVertFeed) mm/min, safe Z \(model.parameters.zSafe) mm, plunge clearance \(model.parameters.plungeClearance) mm.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Label {
                Text("Mill this with the **exact bit you'll use in production** — the results only transfer if the tool matches. V-bit users: the Tool diameter parameter must be the *effective* diameter at cut depth, not the tip size: effective ≈ tip + 2 × |depth| × tan(half-angle). A 0.1 mm 60° V-bit at −0.06 mm cuts ≈ 0.17 mm. Cross-check afterwards: if the 0.2 mm test trace measures ~0.13 mm, your entered diameter is ~0.07 mm too small.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate…") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(spec == nil)
                    .help("Choose where to save the .ngc; a legend .txt is written next to it and the board opens in the preview.")
            }
        }
        .padding(20)
        .frame(width: 500)
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
              let tool = Double(model.parameters.millDiameter.trimmingCharacters(in: .whitespaces)),
              let isolation = Double(model.parameters.isolationWidth.trimmingCharacters(in: .whitespaces)),
              let zsafe = Double(model.parameters.zSafe.trimmingCharacters(in: .whitespaces)),
              let plunge = Double(model.parameters.millVertFeed.trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0, dFrom < 0, dTo < 0, fFrom > 0, fTo > 0
        else { return nil }
        let s = TestBoardGenerator.Spec(
            width: w, height: h, rows: rows, cols: cols,
            depthFrom: dFrom, depthTo: dTo,
            feedFrom: fFrom, feedTo: fTo,
            tool: tool, isolationWidth: isolation,
            spindle: model.parameters.millSpeed.trimmingCharacters(in: .whitespaces),
            zsafe: zsafe, plungeFeed: plunge,
            plungeClearance: Double(model.parameters.plungeClearance.trimmingCharacters(in: .whitespaces)) ?? 0
        )
        return TestBoardGenerator.cellSize(for: s) != nil ? s : nil
    }

    private var summary: String {
        guard let rows = Int(rowsText), let cols = Int(colsText) else {
            return "Grid values must be whole numbers."
        }
        guard let spec, let cell = TestBoardGenerator.cellSize(for: spec) else {
            if rows < 2 || cols < 2 {
                return "Grid needs at least 2 × 2 combinations."
            }
            if rows > TestBoardGenerator.maxRows || cols > TestBoardGenerator.maxCols {
                return "Grid is limited to \(TestBoardGenerator.maxCols) feeds × \(TestBoardGenerator.maxRows) depths."
            }
            return "Grid doesn't fit this board — patches need at least ≈8.5 × 8 mm each. Reduce steps or enlarge the board (Suggest fills in what fits)."
        }
        let lastLetter = Character(UnicodeScalar(64 + spec.cols)!)
        return String(format: "Grid: %d feeds (A–%@) × %d depths (1–%d) = %d patches, each %.1f × %.1f mm.",
                      spec.cols, String(lastLetter), spec.rows, spec.rows, spec.cols * spec.rows, cell.w, cell.h)
    }

    private func generate() {
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

        model.appendLog("\nTest board written to \(url.path)\n")
        model.appendLog(result.legend)
        model.preview.loadExternal(url: url, toolDiameter: spec.tool)
        NSWorkspace.shared.activateFileViewerSelecting([url, legendURL])
        dismiss()
    }
}
