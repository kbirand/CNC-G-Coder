import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Height map (autolevel), laid out like Candle: the border and grid of the
/// probe (or Auto from the program), the Z limits and probe feed, Probe /
/// Stop / Clear / Load / Save, the "use for sending" switch, a live
/// progress line while probing, the summary and the value table. The tab
/// works on the side of the program shown in the preview — the board is
/// flipped between the sides, so each has its own map — stored in
/// `model.heightMaps`; while probing, the streamer's live target is shown.
struct HeightMapTab: View {
    @Bindable var machine: MachineController

    var body: some View {
        ScrollView {
            HeightMapControls(machine: machine)
                .padding(16)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// The height-map form itself — the window's tab and the main window's
/// panel section both show it; it lays out in a column about 380 pt wide
/// (the value table scrolls sideways).
struct HeightMapControls: View {
    @Bindable var machine: MachineController
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // The side follows the shown program (`PlaybackState`), observed here.
        HeightMapControlsBody(machine: machine, model: model, player: model.player)
    }
}

private struct HeightMapControlsBody: View {
    @Bindable var machine: MachineController
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackState

    @State private var draft = HeightMapDraft()
    @State private var message: String?
    /// Candle's "interpolation grid": lines of the wireframe the preview draws.
    @AppStorage(HeightMapSurface.interpolationXKey) private var interpolationX = HeightMapSurface.interpolationDefault
    @AppStorage(HeightMapSurface.interpolationYKey) private var interpolationY = HeightMapSurface.interpolationDefault

    private var streamer: JobStreamer { machine.streamer }
    private var side: BoardSide { model.shownBoardSide }
    private var probing: Bool { streamer.state == .probing }

    /// The live map while probing, otherwise the stored one for this side.
    private var displayedMap: HeightMap? { model.displayedHeightMap(side: side) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sideSection
            gridSection
            progressSection
            summarySection
            if let map = displayedMap, map.probedCount > 0 {
                HeightMapTable(map: map, current: probing ? HeightMapSurface.nextProbe(map) : nil)
                    .machinePanel()
            }
        }
        .onAppear { loadDraft() }
        .onChange(of: side) { _, _ in loadDraft() }
        .onChange(of: model.heightMaps[side]?.probedAt) { _, _ in loadDraft() }
    }

    // MARK: Side

    private var sideSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: side == .front ? "square.fill.on.square" : "square.on.square.dashed")
                    .foregroundStyle(.teal)
                Text(side == .front
                     ? "Front side — copper top, drills, outline, top mask"
                     : "Back side — after flipping the board: back copper, bottom mask")
                    .font(.callout.weight(.semibold))
            }
            Text("Each side has its own map because the board is flipped between them. The map follows the program shown in the preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .machinePanel()
    }

    // MARK: Grid definition

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MachineSectionLabel(title: "Probe grid", detail: "board mm (design frame)")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Border X / Y")
                        .help("Lower-left corner of the probe grid, in the board's design coordinates (the Gerber frame, as in the preview). Auto fills the border from the shown program's cut area.")
                    field($draft.originX, help: "Lower-left corner of the probe grid, in the board's design coordinates (the Gerber frame, as in the preview)")
                    field($draft.originY, help: "Lower-left corner of the probe grid, in the board's design coordinates (the Gerber frame, as in the preview)")
                    Button("Auto", systemImage: "wand.and.stars") { autoGrid() }
                        .help("Border around the shown program's cut area plus 1 mm, points about 10 mm apart")
                        .disabled(autoBounds == nil)
                }
                GridRow {
                    Text("Border W / H")
                        .help("Width and height of the probe grid. It should cover everything the program cuts, with a little margin; the work coordinates of its corner are shown beside it.")
                    field($draft.width, help: "Size of the probe grid. It should cover everything the program cuts, with a little margin.")
                    field($draft.height, help: "Size of the probe grid. It should cover everything the program cuts, with a little margin.")
                    Text(workEquivalent).font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Points X / Y")
                        .help("Probe points along X and Y (2–15 each). Points about 10 mm apart follow a warped board well; more points take longer to probe.")
                    field($draft.nx, help: "Probe points along X (2–15). Points about 10 mm apart follow a warped board well; more points take longer to probe.")
                    field($draft.ny, help: "Probe points along Y (2–15). Points about 10 mm apart follow a warped board well; more points take longer to probe.")
                    Text("2–15 each").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Z clear / Z max depth")
                        .help("Z clear: the work Z the bit travels at between the points — above the highest spot of the board. Z max depth: the lowest work Z a probe may reach; it gives up there if nothing is touched.")
                    field($draft.zClear, help: "Work Z the bit travels at between the points — above the highest spot of the board")
                    field($draft.zMaxDepth, help: "Lowest work Z a probe may reach; the probe gives up there if nothing is touched")
                    Text("Zt / Zb").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Probe feed")
                        .help("Speed of the probing move at every point, mm/min — slow for precision, as in the Z probe")
                    field($draft.feedSlow, help: "Speed of the probing move at every point, mm/min — slow for precision, as in the Z probe")
                    Text("mm/min").font(.caption).foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
                GridRow {
                    Text("Interpolation grid X / Y")
                        .help("Lines of the wireframe the preview draws between the probed points (4–60) — display only; the program itself is interpolated continuously")
                    linesField(linesX, help: "Lines of the wireframe the preview draws between the probed points (4–60) — display only, the program itself is interpolated continuously")
                    linesField(linesY, help: "Lines of the wireframe the preview draws between the probed points (4–60) — display only, the program itself is interpolated continuously")
                    Text("4–60 lines").font(.caption).foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .disabled(probing)
            buttons
            Toggle("Use height map for sending", isOn: useBinding)
                .controlSize(.small)
                .disabled(streamer.isActive)
                .help(model.heightMaps[side] == nil
                      ? "Programs of this side will be warped by the map once one is probed (the Program tab's “Apply height map”)"
                      : "Warp the Z of programs of this side by the probed surface when sending (the Program tab's “Apply height map”)")
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .machinePanel()
    }

    /// The border's lower-left corner in the side's work frame, so the
    /// design values can be related to the machine.
    private var workEquivalent: String {
        guard let map = draft.map(side: side) else { return "mm" }
        let p = map.origin.applying(model.heightMapFrame(side: side))
        return "mm · work X\(formatMM(p.x, decimals: 1)) Y\(formatMM(p.y, decimals: 1))"
    }

    private func field(_ text: Binding<String>, help: String) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .help(help)
    }

    /// The line counts of the interpolation grid, clamped to 4…60 when a
    /// field commits (Return or focus loss).
    private var linesX: Binding<Int> {
        Binding(get: { HeightMapSurface.clampedLines(interpolationX) },
                set: { interpolationX = HeightMapSurface.clampedLines(max($0, 1)) })
    }

    private var linesY: Binding<Int> {
        Binding(get: { HeightMapSurface.clampedLines(interpolationY) },
                set: { interpolationY = HeightMapSurface.clampedLines(max($0, 1)) })
    }

    private func linesField(_ value: Binding<Int>, help: String) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            .multilineTextAlignment(.trailing)
            .help(help)
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                probeButtons
                Spacer(minLength: 0)
                fileButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { probeButtons }
                HStack(spacing: 8) { fileButtons }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var probeButtons: some View {
        if probing {
            Button("Stop", systemImage: "stop.fill") { Task { await streamer.stop() } }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("Stop probing (the points recorded so far are discarded)")
        } else {
            Button("Probe", systemImage: "arrow.down.to.line") { probe() }
                .buttonStyle(.borderedProminent)
                .disabled(!canProbe)
                .help(probeHelp)
        }
        Button("Clear", systemImage: "trash") { clear() }
            .disabled(model.heightMaps[side] == nil || probing)
            .help("Forget this side's map (it is deleted from disk too); programs are sent flat again")
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button("Load…", systemImage: "folder") { load() }
            .disabled(probing)
            .help("Read a map saved with Save… — it goes to the side it was probed on")
        Button("Save…", systemImage: "square.and.arrow.down") { save() }
            .disabled(model.heightMaps[side] == nil)
            .help("Write this side's map to a JSON file, e.g. to keep it with the project or reuse it on the same board")
    }

    // MARK: Progress

    @ViewBuilder
    private var progressSection: some View {
        if probing, let map = streamer.heightMapTarget {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progressText(map))
                        .font(.callout.monospacedDigit())
                }
                ProgressView(value: Double(map.probedCount), total: Double(max(map.totalCount, 1)))
                    .progressViewStyle(.linear)
                if map.side != side {
                    Text("Probing the \(map.side.title.lowercased()) side; the preview shows the \(side.title.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .machinePanel()
        }
    }

    private func progressText(_ map: HeightMap) -> String {
        guard map.referenceZ != nil else { return "Probing the reference at X0/Y0…" }
        let next = min(map.probedCount + 1, map.totalCount)
        var text = "Probing point \(next) of \(map.totalCount)"
        if let last = HeightMapSurface.lastProbed(map) {
            text += String(format: " — last Z %+.3f mm", last.z)
        }
        return text
    }

    // MARK: Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MachineSectionLabel(title: "\(side.title) map")
            if let map = displayedMap {
                HStack(spacing: 12) {
                    Text("\(map.nx)×\(map.ny)")
                    Text("\(map.probedCount) / \(map.totalCount) points")
                    if let dev = map.maxDeviation { Text("max dev \(formatMM(dev)) mm") }
                }
                .font(.callout.monospacedDigit())
                Text("\(formatMM(map.size.width, decimals: 1))×\(formatMM(map.size.height, decimals: 1)) mm at X\(formatMM(map.origin.x, decimals: 1)) Y\(formatMM(map.origin.y, decimals: 1))"
                     + (map.probedAt.map { " · probed " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let origin = map.probedDesignOrigin {
                    Text("Board origin when probed (machine): \(origin.summary)" + (map.referenceZ.map { " · reference Z \(formatMM($0))" } ?? ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !probing { validityBadge(map) }
            } else {
                Text("No height map for the \(side.title.lowercased()) side. Set the border and grid (or Auto) and Probe, or Load… a saved one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .machinePanel()
    }

    private func validityBadge(_ map: HeightMap) -> some View {
        let issues = map.validity(currentDesignOrigin: machine.currentDesignOrigin(side: side), programSide: side)
        let text: String
        let tint: Color
        if issues.isEmpty {
            text = "Matches the machine's current work offset"
            tint = .green
        } else {
            text = issues.map(describe).joined(separator: " · ")
            tint = issues.contains(.incomplete) || issues.contains(.sideMismatch) ? .red : .orange
        }
        return Label(text, systemImage: issues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(tint)
    }

    private func describe(_ issue: HeightMap.Issue) -> String {
        switch issue {
        case .sideMismatch: "other side"
        case .wcoUnknown: "work offset unknown (connect)"
        case .originUnknown: "board position at probing unknown"
        case .xyMoved(let dx, let dy): "work origin moved on the board X\(formatMM(dx)) Y\(formatMM(dy))"
        case .zRezeroed(let dz): "Z re-zeroed by \(formatMM(dz))"
        case .incomplete: "incomplete"
        }
    }

    // MARK: Use for sending

    /// The Program tab's "Apply height map", reachable from here: turning it
    /// on re-prepares the loaded program with the map right away.
    private var useBinding: Binding<Bool> {
        Binding(get: { machine.applyHeightMap }, set: { on in
            if on, let map = model.heightMaps[side], !map.isComplete {
                message = "The map is incomplete (\(map.probedCount) of \(map.totalCount) points) — probe it again before sending with it."
            }
            machine.applyHeightMap = on
            Task {
                if let failure = await machine.reprepareLoadedProgram() { message = failure }
            }
        })
    }

    // MARK: Actions

    /// Cut bounds of the shown program (the loaded machine program when it
    /// is of this side), else the preview document's layer of this side,
    /// else the document bounds — in design coordinates (through the
    /// inverse frame), where the map lives.
    private var autoBounds: CGRect? {
        programBounds?.applying(model.heightMapFrame(side: side).inverted())
    }

    private var programBounds: CGRect? {
        if let program = streamer.program, program.kind.boardSide == side, let bounds = program.parsed.cutBounds { return bounds }
        if let shown = player.layer, shown.id.boardSide == side, let bounds = shown.cutBounds { return bounds }
        let layers = model.preview.document?.layers ?? []
        if let bounds = layers.first(where: { $0.id.boardSide == side && $0.cutBounds != nil })?.cutBounds { return bounds }
        return model.preview.document?.bounds
    }

    private func autoGrid() {
        guard let bounds = autoBounds else { return }
        var map = HeightMap.auto(for: bounds, side: side)
        if let current = draft.map(side: side) {
            map.zClear = current.zClear
            map.zMaxDepth = current.zMaxDepth
            map.feedFast = current.feedFast
            map.feedSlow = current.feedSlow
        }
        draft = HeightMapDraft(map: map)
        message = "Border around \(formatMM(bounds.width, decimals: 1))×\(formatMM(bounds.height, decimals: 1)) mm plus 1 mm margin."
    }

    private var canProbe: Bool {
        machine.canProbe && !streamer.isActive && draft.map(side: side) != nil
    }

    private var probeHelp: String {
        if draft.map(side: side) == nil { return "Check the grid values" }
        if !machine.canProbe { return "Needs: connected, idle, no alarm, trusted position, known work offset" }
        if streamer.isActive { return "A job is active" }
        let n = draft.map(side: side)?.totalCount ?? 0
        return "Probe the reference at X0/Y0, then \(n) grid points"
    }

    private func probe() {
        guard let map = draft.map(side: side) else { return }
        message = nil
        // Show the map in the preview while it is probed; the View Options
        // toggle stays the user's switch afterwards.
        UserDefaults.standard.set(true, forKey: "previewShowHeightMap")
        Task { await machine.probeHeightMap(map) }
    }

    private func clear() {
        model.heightMaps[side] = nil
        if let key = model.heightMapKey {
            try? FileManager.default.removeItem(at: HeightMap.storageURL(projectKey: key, side: side))
        }
        Task { await machine.reprepareLoadedProgram() }
        message = "Cleared."
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let map = try HeightMap.read(from: url)
            model.heightMaps[map.side] = map
            model.saveHeightMap(map)
            if map.side == side {
                draft = HeightMapDraft(map: map)
                message = "Loaded \(url.lastPathComponent)."
            } else {
                message = "Loaded \(url.lastPathComponent) — a \(map.side.title.lowercased())-side map, stored for the \(map.side.title.lowercased()) side. The preview shows the \(side.title.lowercased())."
            }
            Task { await machine.reprepareLoadedProgram() }
        } catch {
            message = "Could not load: \(error.localizedDescription)"
        }
    }

    private func save() {
        guard let map = model.heightMaps[side] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "heightmap-\(side.rawValue).json"
        panel.directoryURL = model.projectFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try map.write(to: url)
            message = "Saved to \(url.lastPathComponent)."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func loadDraft() {
        if let map = model.heightMaps[side] {
            draft = HeightMapDraft(map: map)
        } else if draft.isEmpty, let bounds = autoBounds {
            draft = HeightMapDraft(map: HeightMap.auto(for: bounds, side: side))
        }
    }
}

/// The grid fields as text, so half-typed values never reach `HeightMap`.
private struct HeightMapDraft {
    var originX = "", originY = "", width = "", height = ""
    var nx = "", ny = ""
    var zClear = "1", zMaxDepth = "-2"
    var feedFast = "100", feedSlow = "20"

    init() {}

    init(map: HeightMap) {
        originX = formatMM(map.origin.x)
        originY = formatMM(map.origin.y)
        width = formatMM(map.size.width)
        height = formatMM(map.size.height)
        nx = "\(map.nx)"
        ny = "\(map.ny)"
        zClear = formatMM(map.zClear)
        zMaxDepth = formatMM(map.zMaxDepth)
        feedFast = formatMM(map.feedFast, decimals: 0)
        feedSlow = formatMM(map.feedSlow, decimals: 0)
    }

    var isEmpty: Bool { originX.isEmpty && width.isEmpty && nx.isEmpty }

    /// nil when any field is not a sensible number.
    func map(side: BoardSide) -> HeightMap? {
        guard let ox = parseNumber(originX), let oy = parseNumber(originY),
              let w = parseNumber(width), let h = parseNumber(height), w > 0, h > 0,
              let nxv = Int(nx.trimmingCharacters(in: .whitespaces)), let nyv = Int(ny.trimmingCharacters(in: .whitespaces)),
              HeightMap.countRange.contains(nxv), HeightMap.countRange.contains(nyv),
              let clear = parseNumber(zClear), let depth = parseNumber(zMaxDepth), depth < clear,
              let fast = parseNumber(feedFast), let slow = parseNumber(feedSlow), fast > 0, slow > 0 else { return nil }
        var map = HeightMap(origin: CGPoint(x: ox, y: oy), size: CGSize(width: w, height: h), nx: nxv, ny: nyv, side: side)
        map.zClear = clear
        map.zMaxDepth = depth
        map.feedFast = fast
        map.feedSlow = slow
        return map
    }
}

/// The probed values, row 0 (lowest Y) at the bottom like the canvas; the
/// point being probed is outlined in yellow.
private struct HeightMapTable: View {
    var map: HeightMap
    var current: HeightMapIndex?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MachineSectionLabel(title: "Values", detail: "mm relative to the reference at X0/Y0")
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 6, verticalSpacing: 3) {
                    ForEach((0..<map.ny).reversed(), id: \.self) { row in
                        GridRow {
                            Text("Y\(formatMM(map.gridPoint(row: row, col: 0).y, decimals: 1))")
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            ForEach(0..<map.nx, id: \.self) { col in
                                cell(HeightMapSurface.value(map, at: HeightMapIndex(row: row, col: col)),
                                     current: current == HeightMapIndex(row: row, col: col))
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        ForEach(0..<map.nx, id: \.self) { col in
                            Text("X\(formatMM(map.gridPoint(row: 0, col: col).x, decimals: 1))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func cell(_ value: Double?, current: Bool) -> some View {
        Text(value.map { String(format: "%+.3f", $0) } ?? (current ? "…" : "—"))
            .frame(width: 58, alignment: .trailing)
            .padding(.vertical, 1)
            .background(tint(value), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                if current {
                    RoundedRectangle(cornerRadius: 3).stroke(Color.yellow, lineWidth: 1.5)
                }
            }
    }

    /// Blue for the lowest, red for the highest, like the canvas.
    private func tint(_ value: Double?) -> Color {
        guard let value, let range = HeightMapSurface.range(map) else { return .clear }
        return HeightMapSurface.color(unit: HeightMapSurface.unit(value, in: range)).opacity(0.35)
    }
}
