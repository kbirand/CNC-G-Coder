import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// The program controls shared by the Machine window's Program tab and the
/// main window's Machine panel: pick a generated layer (or an external
/// .ngc), the summary line, the height-map / backlash toggles with their
/// validity sheets, the tool-change banner, the error prompt, and the full
/// `JobBar`. Selecting a program prepares it at once
/// (`MachineController.prepareProgram` → `JobStreamer.load`), so the main
/// window's canvases already show the sent geometry before the first line
/// goes out. `middle` sits between the banner and the job bar — the window
/// puts the program text there, the panel nothing (the main window's G-code
/// tab already follows the job).
struct ProgramControls<Middle: View>: View {
    @Bindable var machine: MachineController
    /// Where "Probe Z" / "Re-probe" lead: the tab in the window, the
    /// section in the panel.
    var navigate: (MachineTab) -> Void
    @ViewBuilder var middle: () -> Middle
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ProgramControlsBody(machine: machine, navigate: navigate, model: model, preview: model.preview, middle: middle)
    }
}

extension ProgramControls where Middle == EmptyView {
    init(machine: MachineController, navigate: @escaping (MachineTab) -> Void) {
        self.init(machine: machine, navigate: navigate, middle: { EmptyView() })
    }
}

/// Split from `ProgramControls` so the preview controller is observed
/// explicitly (`@ObservedObject`): the document token and the job identity
/// are what the picker follows.
private struct ProgramControlsBody<Middle: View>: View {
    @Bindable var machine: MachineController
    var navigate: (MachineTab) -> Void
    @ObservedObject var model: AppModel
    @ObservedObject var preview: PreviewController
    @ViewBuilder var middle: () -> Middle

    @State private var selectedKind: LayerKind?
    @State private var applyBacklash = MachineSettings.applyBacklash
    @State private var clampZ = false
    @State private var preparing = false
    @State private var prepareError: String?
    @State private var prepareTask: Task<Void, Never>?
    @State private var awaitingExternal = false
    @State private var validityPrompt: ValidityPrompt?
    @State private var refusal: String?
    @State private var resumePlan: ResumePlan?
    @State private var originProbing = false
    @State private var originProbeResult: (text: String, failed: Bool)?
    @AppStorage(MachineSettings.Keys.confirmContinue) private var confirmContinue = MachineSettings.Defaults.confirmContinue

    private var streamer: JobStreamer { machine.streamer }
    private var program: MachineProgram? { streamer.program }

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        VStack(spacing: 0) {
            header
            Divider()
            suspendedBanner
            middle()
            Divider()
            JobBar(machine: machine, onClampZ: { clampZ = true })
        }
        .onAppear { adoptLoadedProgram(); consumeRequest(); if selectedKind == nil { selectedKind = preview.document?.layers.first?.id } }
        .onChange(of: model.requestedMachineLayer) { _, _ in consumeRequest() }
        .onChange(of: selectedKind) { _, _ in prepare() }
        .onChange(of: preview.document?.token) { _, _ in documentChanged() }
        .onChange(of: applyBacklash) { _, on in MachineSettings.applyBacklash = on; prepare() }
        .onChange(of: clampZ) { _, _ in prepare() }
        .alert("Line \(streamer.errorPrompt?.line ?? 0): error", isPresented: errorPromptShown, presenting: streamer.errorPrompt) { _ in
            Button("Ignore and Continue") { streamer.ignoreError() }
            Button("Stop Job", role: .destructive) { streamer.stopAfterError() }
        } message: { prompt in
            Text("\(prompt.message)\n\nThe machine is in feed hold. Ignore skips nothing — the controller already rejected the line — and resumes with the next one.")
        }
        .alert("Cannot apply the height map", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK") { refusal = nil }
        } message: {
            Text(refusal ?? "")
        }
        .sheet(item: $validityPrompt) { prompt in
            // Switching the map on: nothing is loaded with it yet.
            validitySheet(prompt.issues, showRunWithoutMap: true,
                          reprobe: { validityPrompt = nil; machine.applyHeightMap = false; navigate(.heightMap) },
                          runWithoutMap: { validityPrompt = nil; machine.applyHeightMap = false; prepare() },
                          applyAnyway: { validityPrompt = nil; machine.applyHeightMap = true; prepare() })
        }
        .sheet(isPresented: Binding(get: { streamer.validityPrompt != nil }, set: { if !$0 { streamer.cancelValidity() } })) {
            // Sending: the streamer found the map stale against the current
            // work offset and holds the start until this is answered.
            validitySheet(streamer.validityPrompt ?? [], showRunWithoutMap: !streamer.isActive,
                          reprobe: { streamer.cancelValidity(); navigate(.heightMap) },
                          runWithoutMap: { machine.applyHeightMap = false; streamer.runWithoutMap() },
                          applyAnyway: { streamer.applyAnyway() })
        }
        .sheet(item: $resumePlan) { plan in
            ResumePreambleSheet(machine: machine, plan: plan)
        }
    }

    private var errorPromptShown: Binding<Bool> {
        Binding(get: { streamer.errorPrompt != nil }, set: { _ in })
    }

    // MARK: Header

    /// Picker, file buttons, summary, badges and the two toggles. The file
    /// buttons keep their titles in the Machine window and shrink to icons
    /// in the narrow Machine panel; the badges wrap under the summary there.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    layerPicker
                    fileButtons(iconOnly: false)
                }
                HStack(spacing: 8) {
                    layerPicker
                    fileButtons(iconOnly: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    programSummary
                    Spacer(minLength: 0)
                    badges
                }
                VStack(alignment: .leading, spacing: 2) {
                    programSummary
                    HStack(spacing: 6) { badges }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    optionToggles
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    optionToggles
                }
            }
            .controlSize(.small)
            if let prepareError {
                Text(prepareError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func fileButtons(iconOnly: Bool) -> some View {
        Button { openExternal() } label: {
            fileLabel("Open .ngc file…", systemImage: "folder", iconOnly: iconOnly)
        }
        .disabled(streamer.isActive)
        .help("Send a G-code file that is not part of this project")
        Spacer(minLength: 0)
        if preparing { ProgressView().controlSize(.small) }
        Button { saveSentProgram() } label: {
            fileLabel("Save sent program…", systemImage: "square.and.arrow.down", iconOnly: iconOnly)
        }
        .disabled(program == nil)
        .help("Save the exact text streamed to the machine (after height map and backlash)")
    }

    @ViewBuilder
    private func fileLabel(_ title: String, systemImage: String, iconOnly: Bool) -> some View {
        if iconOnly {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private var optionToggles: some View {
        Toggle("Apply height map", isOn: heightMapBinding)
            .disabled(streamer.isActive || selectedKind == nil || availableMap == nil)
            .help(availableMap == nil ? "No height map probed for this side yet (Height Map tab)" : "Warp the program's Z by the probed surface")
        Toggle("Backlash compensation", isOn: $applyBacklash)
            .disabled(streamer.isActive || !BacklashCompensation.Settings.current.isActive)
            .help(BacklashCompensation.Settings.current.isActive ? "Rewrite the program for the play set in Machine setup" : "No backlash play set in Machine setup")
        if clampZ || canClampZ {
            Toggle("Clamp Z to top", isOn: $clampZ)
                .disabled(streamer.isActive)
                .help("Lower every Z above the top of travel to just below it, so the program can run with work Z0 near the top (air tests); cutting depths are not changed")
        }
    }

    /// The pre-flight refuses the loaded program only for Z above the top.
    private var canClampZ: Bool {
        guard let program, !streamer.isActive else { return false }
        return machine.preflightResult(program)?.canClampZ ?? false
    }

    private var layerPicker: some View {
        Picker("Program", selection: $selectedKind) {
            if preview.document?.layers.isEmpty ?? true {
                Text("No program generated").tag(LayerKind?.none)
            }
            ForEach(preview.document?.layers ?? []) { layer in
                Text(layer.displayName).tag(LayerKind?.some(layer.id))
            }
        }
        .frame(minWidth: 160, maxWidth: 280)
        .disabled(streamer.isActive)
    }

    @ViewBuilder
    private var programSummary: some View {
        if let program {
            Text(program.name)
                .font(.callout.weight(.semibold))
                .help(program.notes.isEmpty ? program.url.path : program.notes.joined(separator: "\n"))
            Text("\(program.lines.count) lines · \(program.parsed.moves.count) moves · est. \(formatDuration(program.parsed.totalTime))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if program.segments.count > 1 {
                Text("\(program.segments.count) tool segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(program.segments.map { "\($0.toolLabel): lines \($0.lines.lowerBound)–\($0.lines.upperBound)" }.joined(separator: "\n"))
            }
        } else if selectedKind != nil, preparing {
            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Choose a program to send.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var badges: some View {
        if let program {
            if let map = program.options.heightMap {
                badge(heightMapText(map), tint: heightMapIssues(map).isEmpty ? .blue : .orange, systemImage: "square.grid.3x3")
            } else if availableMap != nil {
                badge("Height map available", tint: .secondary, systemImage: "square.grid.3x3")
            }
            if program.backlashApplied {
                let s = BacklashCompensation.Settings.current
                badge("Backlash X\(formatMM(s.x)) Y\(formatMM(s.y))", tint: .purple, systemImage: "arrow.left.and.right")
            }
            if let clamp = program.options.clampZAboveWork {
                badge("Z clamped to \(formatMM(clamp, decimals: 1))", tint: .orange, systemImage: "arrow.down.to.line.compact")
                    .help(program.notes.first { $0.hasPrefix("Z clamped") } ?? "Z words above the top of travel lowered to this work Z")
            }
        }
    }

    private func badge(_ title: String, tint: Color, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    // MARK: Suspended banner

    @ViewBuilder
    private var suspendedBanner: some View {
        if case .suspended(let reason) = streamer.state {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    suspendedText(reason)
                    Spacer(minLength: 8)
                    suspendedButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    suspendedText(reason)
                    HStack(spacing: 8) { suspendedButtons }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18))
            Divider()
        }
    }

    private func suspendedText(_ reason: JobStreamer.SuspendReason) -> some View {
        let mapped = program?.options.heightMap != nil
        return HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(suspendTitle(reason)).font(.headline)
                Text(mapped
                     ? "Spindle off, tool parked at the safe height. Change the bit, then probe Z at the work origin — the height map is relative to the Z probed at X0/Y0 — then Continue."
                     : "Spindle off, tool parked at the safe height. Change the bit, probe Z on the copper, then Continue.")
                    .font(.caption)
                if let result = originProbeResult {
                    Text(result.text)
                        .font(.caption)
                        .foregroundStyle(result.failed ? .red : .secondary)
                        .lineLimit(2)
                }
                preambleCaption
            }
        }
    }

    /// What Continue sends before the program resumes — visible in the
    /// banner since Continue no longer stops for the preamble sheet.
    @ViewBuilder
    private var preambleCaption: some View {
        if let line = streamer.resumeLine, let preamble = machine.resumePreamble(line: line), !preamble.isEmpty {
            Text("Will send: " + preamble.joined(separator: " · ") + " · then line \(line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(preamble.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private var suspendedButtons: some View {
        if program?.options.heightMap != nil {
            Button("Probe Z at origin", systemImage: "arrow.down.to.line") { probeAtOrigin() }
                .disabled(originProbing || machine.machineState != .idle || machine.alarmCode != nil)
                .help("Rapid to work X0 Y0 at the parked height, then run the Z touch-off there")
            if originProbing { ProgressView().controlSize(.small) }
        } else {
            Button("Probe Z", systemImage: "arrow.down.to.line") { navigate(.probe) }
        }
        Button("Continue", systemImage: "forward.fill") { continueSuspended() }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(machine.machineState != .idle || machine.alarmCode != nil)
        Button("Stop", systemImage: "stop.fill") { Task { await streamer.stop() } }
            .tint(.red)
    }

    private func suspendTitle(_ reason: JobStreamer.SuspendReason) -> String {
        switch reason {
        case .toolChange(let message): message.isEmpty ? "Tool change" : "Tool change: \(message)"
        case .programPause: "Program pause (M0)"
        }
    }

    /// Continue runs the controller's preamble at once (it is shown in the
    /// banner); the confirmation sheet comes back with the
    /// `machine.confirmContinue` setting.
    private func continueSuspended() {
        if confirmContinue {
            resumePlan = ResumePlan.make(mode: .continueSuspended, line: streamer.resumeLine ?? 1, machine: machine)
        } else {
            Task { await machine.continueJob() }
        }
    }

    /// The height-mapped tool change: the new bit is measured at work X0/Y0
    /// (`MachineController.probeZAtWorkOrigin`), where the map's reference
    /// was probed.
    private func probeAtOrigin() {
        originProbing = true
        originProbeResult = nil
        Task {
            let failure = await machine.probeZAtWorkOrigin()
            originProbing = false
            if let failure {
                originProbeResult = (failure, true)
            } else {
                let z = machine.lastProbe.map { formatMM($0.position.z) } ?? "?"
                originProbeResult = ("Z probed at the work origin (machine Z \(z)); work Z0 set there.", false)
            }
        }
    }

    // MARK: Selection / preparation

    /// A program loaded elsewhere (the sidebar's request, a dev hook, a
    /// reopened window) stays selected instead of being replaced by the
    /// document's first layer.
    private func adoptLoadedProgram() {
        guard selectedKind == nil, let program else { return }
        applyBacklash = program.options.applyBacklash
        clampZ = program.options.clampZAboveWork != nil
        machine.applyHeightMap = program.options.heightMap != nil
        selectedKind = program.kind
    }

    private func consumeRequest() {
        guard let kind = model.requestedMachineLayer else { return }
        model.requestedMachineLayer = nil
        guard !streamer.isActive else { return }
        if let program, program.kind == kind {   // already loaded for this layer: adopt it as is
            applyBacklash = program.options.applyBacklash
            machine.applyHeightMap = program.options.heightMap != nil
        }
        if selectedKind == kind { prepare() } else { selectedKind = kind }
    }

    private func documentChanged() {
        guard !streamer.isActive else { return }
        let layers = preview.document?.layers ?? []
        if awaitingExternal, layers.contains(where: { $0.id == .test }) {
            awaitingExternal = false
            if selectedKind == .test { prepare() } else { selectedKind = .test }
            return
        }
        if let selectedKind, layers.contains(where: { $0.id == selectedKind }) {
            prepare(force: true)
        } else if let loaded = program?.kind, layers.contains(where: { $0.id == loaded }) {
            adoptLoadedProgram()
            if selectedKind == loaded { prepare() }
        } else {
            selectedKind = layers.first?.id
        }
    }

    private var availableMap: HeightMap? {
        guard let kind = selectedKind else { return nil }
        return model.heightMaps[kind.boardSide]
    }

    /// Prepares the selected layer. `force` re-prepares even when the same
    /// program (layer, name, options) is already loaded — needed after the
    /// document regenerated, since the file on disk changed.
    private func prepare(force: Bool = false) {
        prepareTask?.cancel()
        guard !streamer.isActive else { return }
        guard let kind = selectedKind, let layer = preview.document?.layers.first(where: { $0.id == kind }) else {
            prepareError = nil
            return
        }
        let name = kind == .test ? layer.fileURL.lastPathComponent : "\(kind.fileSlug).ngc"
        let options = ProgramOptions(applyBacklash: applyBacklash,
                                     heightMap: machine.applyHeightMap ? availableMap : nil,
                                     applyBelowZ: MachineSettings.heightMapApplyBelowZ,
                                     frame: model.heightMapFrame(side: kind.boardSide),
                                     clampZAboveWork: clampZ ? machine.clampZWork() : nil)
        if !force, let program, program.kind == kind, program.name == name, program.options == options {
            preparing = false
            prepareError = nil
            return
        }
        preparing = true
        prepareError = nil
        prepareTask = Task {
            do {
                _ = try await machine.prepareProgram(layer: layer, name: name, options: options)
            } catch {
                if !Task.isCancelled { prepareError = error.localizedDescription }
            }
            if !Task.isCancelled { preparing = false }
        }
    }

    // MARK: Height map toggle

    private var heightMapBinding: Binding<Bool> {
        Binding(get: { machine.applyHeightMap }, set: { on in
            if on { requestHeightMap() } else { machine.applyHeightMap = false; prepare() }
        })
    }

    /// Turning the map on checks it against the machine's current work
    /// offset: a map of the other side is refused outright, a moved origin
    /// or re-zeroed Z asks before applying.
    private func requestHeightMap() {
        guard let kind = selectedKind, let map = availableMap else { return }
        let issues = map.validity(currentDesignOrigin: machine.currentDesignOrigin(side: kind.boardSide), programSide: kind.boardSide)
        if issues.contains(.sideMismatch) || issues.contains(.incomplete) {
            refusal = issues.contains(.sideMismatch)
                ? "The height map was probed on the \(map.side.title.lowercased()) side; this program is cut on the \(kind.boardSide.title.lowercased())."
                : "The height map is incomplete (\(map.probedCount) of \(map.totalCount) points). Probe it again."
            return
        }
        if issues.isEmpty {
            machine.applyHeightMap = true
            prepare()
        } else {
            validityPrompt = ValidityPrompt(issues: issues)
        }
    }

    private func heightMapIssues(_ map: HeightMap) -> [HeightMap.Issue] {
        guard let kind = selectedKind else { return [] }
        return map.validity(currentDesignOrigin: machine.currentDesignOrigin(side: kind.boardSide), programSide: kind.boardSide)
    }

    private func heightMapText(_ map: HeightMap) -> String {
        var parts = ["Height map \(map.nx)×\(map.ny)"]
        if let dev = map.maxDeviation { parts.append("max dev \(formatMM(dev)) mm") }
        if let date = map.probedAt {
            let time = date.formatted(date: .omitted, time: .shortened)
            if let origin = map.probedDesignOrigin {
                parts.append("probed \(time), board at X\(formatMM(origin.x)) Y\(formatMM(origin.y)) Z\(formatMM(origin.z))")
            } else {
                parts.append("probed \(time)")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func validitySheet(_ issues: [HeightMap.Issue], showRunWithoutMap: Bool,
                               reprobe: @escaping () -> Void, runWithoutMap: @escaping () -> Void,
                               applyAnyway: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The height map may not match the machine").font(.title3.weight(.semibold))
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issueText(issue), systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Text("The map is stored relative to the Z probed at work X0/Y0, so re-zeroing Z there after a tool change is fine; a moved XY origin means the grid no longer sits where it was probed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !showRunWithoutMap {
                Text("The program being sent is already warped by the map; stop it to send it without the map.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Re-probe") { reprobe() }
                Spacer()
                if showRunWithoutMap {
                    Button("Run Without Map") { runWithoutMap() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { reprobe() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Apply Anyway") { applyAnyway() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func issueText(_ issue: HeightMap.Issue) -> String {
        switch issue {
        case .sideMismatch: "Probed on the other side of the board"
        case .wcoUnknown: "The machine's work offset is not known yet"
        case .originUnknown: "The map does not record where the board was when it was probed"
        case .xyMoved(let dx, let dy): "The work origin moved on the board by X\(formatMM(dx)) Y\(formatMM(dy)) mm since probing"
        case .zRezeroed(let dz): "Z was re-zeroed by \(formatMM(dz)) mm since probing"
        case .incomplete: "The map is incomplete"
        }
    }

    // MARK: Files

    private func openExternal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["ngc", "nc", "gcode", "tap"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.message = "Choose a G-code file to send (absolute metric G0/G1/G2/G3)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        awaitingExternal = true
        preview.loadExternal(url: url, toolDiameter: parseNumber(model.parameters.millDiameter))
    }

    private func saveSentProgram() {
        guard let program else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = program.name
        panel.allowedContentTypes = [UTType(filenameExtension: "ngc") ?? .plainText]
        panel.directoryURL = model.projectFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: program.url, to: url)
            model.appendLog("[machine] saved sent program to \(url.path)\n")
        } catch {
            prepareError = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Wraps the validity issues so they can drive `.sheet(item:)`.
private struct ValidityPrompt: Identifiable {
    let id = UUID()
    var issues: [HeightMap.Issue]
}
