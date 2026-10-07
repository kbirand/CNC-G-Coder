import SwiftUI

/// Progress and transport for the program being streamed: progress bar,
/// "line a / b", elapsed / remaining, Hold–Resume, Stop and E-STOP; the full
/// variant (Program tab) adds Send, Verify, Send from line… and Continue
/// while the job is suspended for a tool change. The compact variant
/// replaces the playback controls over the main canvas while `player.job`
/// is set. Continue resumes at once unless `machine.confirmContinue` is on;
/// Send from line… always shows its preamble first.
struct JobBar: View {
    @Bindable var machine: MachineController
    var compact: Bool = false
    /// "Clamp Z to top" next to a pre-flight refusal that clamping would fix
    /// (the Program controls re-prepare with the clamp).
    var onClampZ: (() -> Void)? = nil

    @State private var showFromLine = false
    @State private var fromLineText = ""
    @State private var resumePlan: ResumePlan?
    @State private var actionError: String?
    @AppStorage(MachineSettings.Keys.confirmContinue) private var confirmContinue = MachineSettings.Defaults.confirmContinue

    private var streamer: JobStreamer { machine.streamer }

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        Group {
            if compact { compactBody } else { fullBody }
        }
        .sheet(item: $resumePlan) { plan in
            ResumePreambleSheet(machine: machine, plan: plan)
        }
        .sheet(isPresented: $showFromLine) { fromLineSheet }
        .alert("Cannot send", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Layouts

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            problemRow
            HStack(spacing: 10) {
                stateLabel
                progressBar
                lineCounter
                timeLabel
                holdResumeButton
                stopButton
                EmergencyStopButton(machine: machine, compact: true)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 760)
    }

    private var fullBody: some View {
        VStack(spacing: 6) {
            problemRow
            // The progress row folds too: at the panel's narrowest the line
            // and time counters go under the bar.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    stateLabel
                    progressBar
                    lineCounter
                    timeLabel
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        stateLabel
                        progressBar
                    }
                    HStack(spacing: 10) {
                        lineCounter
                        Spacer(minLength: 0)
                        timeLabel
                    }
                }
            }
            // One row of buttons in the Machine window, two in the narrow
            // Machine panel of the main window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    startButtons
                    Spacer(minLength: 0)
                    transportButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { startButtons }
                    HStack(spacing: 8) { transportButtons }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var startButtons: some View {
        sendButton
        verifyButton
        fromLineButton
    }

    @ViewBuilder
    private var transportButtons: some View {
        continueButton
        holdResumeButton
        stopButton
        EmergencyStopButton(machine: machine, compact: true)
    }

    // MARK: Pieces

    /// The pre-flight refusal in full — wrapping, never truncated — above
    /// the progress row, with "Clamp Z to top" when that alone would fix it.
    @ViewBuilder
    private var problemRow: some View {
        if let problem = idleProblem {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                Text(problem.message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if problem.canClampZ, let onClampZ {
                    Button("Clamp Z to top", systemImage: "arrow.down.to.line.compact") { onClampZ() }
                        .tint(.orange)
                        .help("Re-prepare the program with every Z above the top of travel lowered to just below it (air tests); cutting depths are not changed")
                }
            }
        }
    }

    private var stateLabel: some View {
        Text(stateText)
            .font(.callout.weight(.semibold))
            .foregroundStyle(stateColor)
            .frame(minWidth: 72, alignment: .leading)
            .lineLimit(1)
    }

    private var progressBar: some View {
        ProgressView(value: min(max(streamer.progressFraction, 0), 1))
            .progressViewStyle(.linear)
            .frame(minWidth: 120)
    }

    private var lineCounter: some View {
        let total = streamer.program?.lines.count ?? 0
        return Text("line \(streamer.ackedLine) / \(total)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .help("Lines acknowledged by the controller / lines in the program")
    }

    private var timeLabel: some View {
        let elapsed = formatDuration(Double(streamer.elapsedSeconds))
        let remaining = streamer.remaining.map { "−" + formatDuration(max($0, 0)) }
            ?? (streamer.program.map { formatDuration($0.parsed.totalTime) } ?? "–:––")
        return Text("\(elapsed) · \(remaining)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .help("Elapsed · remaining (estimated from the program's feed rates)")
    }

    private var holdResumeButton: some View {
        Group {
            if streamer.state == .pausedByUser {
                Button("Resume", systemImage: "play.fill") { streamer.resume() }
                    .tint(.green)
            } else {
                Button("Hold", systemImage: "pause.fill") { streamer.pause() }
                    .disabled(streamer.state != .running)
            }
        }
        .help("Feed hold (!) / cycle start (~)")
    }

    private var stopButton: some View {
        Button("Stop", systemImage: "stop.fill") { Task { await streamer.stop() } }
            .tint(.red)
            .disabled(!streamer.isActive || streamer.state == .stopping)
            .help("Feed hold, wait for the machine to rest, reset, spindle off")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "paperplane.fill") { startJob() }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
            .help(startHelp)
    }

    private var verifyButton: some View {
        Button("Verify", systemImage: "checkmark.seal") { Task { await streamer.verify() } }
            .disabled(!canStart)
            .help("Dry run in check mode ($C): the controller parses every line without moving")
    }

    private var fromLineButton: some View {
        Button("Send from line…", systemImage: "text.insert") {
            fromLineText = "\(streamer.resumeLine ?? 1)"
            showFromLine = true
        }
        .disabled(!canStart)
        .help("Resume a stopped program from a line, with a safe approach preamble")
    }

    @ViewBuilder
    private var continueButton: some View {
        if case .suspended = streamer.state {
            Button("Continue", systemImage: "forward.fill") { continueSuspended() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!machine.isConnected || machine.machineState != .idle || machine.alarmCode != nil)
                .help("Spindle on, approach the next segment safely and carry on")
        }
    }

    // MARK: State

    private var canStart: Bool {
        guard machine.isConnected, !streamer.isActive, let program = streamer.program else { return false }
        return machine.preflight(program) == nil
    }

    private var startHelp: String {
        guard let program = streamer.program else { return "Choose a program first" }
        guard machine.isConnected else { return "Not connected" }
        // The pre-flight walks every move of the program and reads the live
        // status: never on a running job's re-renders.
        guard !streamer.isActive else { return "A job is in progress" }
        return machine.preflight(program) ?? "Stream \(program.name) to the machine"
    }

    /// Why Send is disabled while a program is loaded — shown in full in
    /// `problemRow` so a refused pre-flight never looks like a dead button.
    private var idleProblem: PreflightResult? {
        guard streamer.state == .idle, machine.isConnected, let program = streamer.program else { return nil }
        return machine.preflightResult(program)
    }

    private var stateText: String {
        switch streamer.state {
        case .idle: streamer.program == nil ? "No program" : (idleProblem == nil ? "Ready" : "Not ready")
        case .verifying: "Verifying"
        case .running: "Running"
        case .pausedByUser: "Held"
        case .suspended(let reason):
            switch reason {
            case .toolChange: "Tool change"
            case .programPause: "Paused (M0)"
            }
        case .probing: "Probing"
        case .stopping: "Stopping…"
        case .completed: "Completed"
        case .failed(let why): "Failed: \(why)"
        }
    }

    private var stateColor: Color {
        switch streamer.state {
        case .idle: idleProblem == nil ? .secondary : .orange
        case .verifying, .probing: .blue
        case .running: .green
        case .pausedByUser, .suspended, .stopping: .orange
        case .completed: .green
        case .failed: .red
        }
    }

    // MARK: Actions

    private func startJob() {
        guard let program = streamer.program else { return }
        if let problem = machine.preflight(program) {
            actionError = problem
            return
        }
        Task { await streamer.start() }
    }

    private func continueSuspended() {
        if confirmContinue {
            resumePlan = ResumePlan.make(mode: .continueSuspended, line: streamer.resumeLine ?? 1, machine: machine)
        } else {
            Task { await machine.continueJob() }
        }
    }

    private var fromLineSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send from line").font(.title3.weight(.semibold))
            HStack {
                Text("Line")
                TextField("1", text: $fromLineText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { confirmFromLine() }
                Text("of \(streamer.program?.lines.count ?? 0)")
                    .foregroundStyle(.secondary)
            }
            Text("The lines before it are scanned for the modal state (units, feed, spindle, position); a preamble then retracts, starts the spindle and approaches that position before sending from the line. A line inside a later tool segment first suspends for the tool change.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showFromLine = false }
                    .keyboardShortcut(.cancelAction)
                Button("Preview Preamble…") { confirmFromLine() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(fromLine == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var fromLine: Int? {
        guard let program = streamer.program, let line = Int(fromLineText.trimmingCharacters(in: .whitespaces)),
              line >= 1, line <= program.lines.count else { return nil }
        return line
    }

    private func confirmFromLine() {
        guard let line = fromLine else { return }
        showFromLine = false
        resumePlan = ResumePlan.make(mode: .fromLine, line: line, machine: machine)
    }
}

/// A resume preamble waiting for the operator's confirmation.
struct ResumePlan: Identifiable {
    enum Mode { case fromLine, continueSuspended }

    let id = UUID()
    var mode: Mode
    var line: Int
    var preamble: [String]
    /// Modal state the preamble was derived from, shown for a sanity check.
    var modal: ModalState

    /// The plan the controller would run: `MachineController.resumePreamble`
    /// is the single source of the preamble (the view only shows it). Nil
    /// while no program is loaded.
    static func make(mode: Mode, line: Int, machine: MachineController) -> ResumePlan? {
        guard let program = machine.streamer.program else { return nil }
        let clamped = min(max(line, 1), program.lines.count)
        guard let preamble = machine.resumePreamble(line: clamped) else { return nil }
        let modal = ProgramPreparer.modalState(lines: program.lines, before: clamped)
        return ResumePlan(mode: mode, line: clamped, preamble: preamble, modal: modal)
    }
}

/// Shows the preamble lines and runs the plan on confirmation.
struct ResumePreambleSheet: View {
    @Bindable var machine: MachineController
    var plan: ResumePlan
    @Environment(\.dismiss) private var dismiss

    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.mode == .fromLine ? "Send from line \(plan.line)" : "Continue from line \(plan.line)")
                .font(.title3.weight(.semibold))
            Text("These lines are sent first, then the program from line \(plan.line). Check that the position and feed look right.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(plan.preamble.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            modalSummary
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.mode == .fromLine ? "Send" : "Continue") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!machine.isConnected || machine.machineState != .idle || machine.alarmCode != nil || !machine.positionTrusted)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var modalSummary: some View {
        let m = plan.modal
        let position = [m.x.map { "X\(formatMM($0))" }, m.y.map { "Y\(formatMM($0))" }, m.z.map { "Z\(formatMM($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        let feed = m.feed.map { "F\(Int($0))" } ?? "no F yet"
        let spindle = m.spindleOn.map { "\($0) S\(Int(m.spindleRPM ?? 0))" } ?? "spindle off"
        return Text("Before line \(plan.line): \(m.units) \(m.distance) \(m.plane) · \(position.isEmpty ? "no position" : position) · \(feed) · \(spindle)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func run() {
        if let program = machine.streamer.program, let refusal = machine.preflight(program) {
            problem = refusal
            return
        }
        let plan = self.plan
        dismiss()
        Task {
            switch plan.mode {
            case .fromLine: await machine.streamer.start(fromLine: plan.line, preamble: plan.preamble)
            case .continueSuspended: await machine.streamer.continueAfterSuspend(preamble: plan.preamble)
            }
        }
    }
}
