import Foundation
import Observation
import CoreGraphics

// Streams a prepared program to the controller: character-counting flow
// control through `StreamWindow`, the job states (pause, stateful stop,
// tool-change suspension, resume from a line, verify, height-map probing)
// and the position-matched progress that drives the preview clock.
//
// Division of labour with `MachineController`: the controller owns the
// link, the console and the order of acknowledgements; the streamer owns
// what to send next and what a job means. The controller forwards every
// `ok`/`error:`/`ALARM`/`[PRB:]` that belongs to a job line through
// `noteResponse`, every status report through `noteStatus`, and a banner
// (controller reset) through `noteBanner`.

@MainActor
@Observable
final class JobStreamer {

    enum SuspendReason: Equatable, Sendable {
        /// The program asked for a tool change (its `T`/`M6` block); the text
        /// is the `(MSG, …)` that preceded it.
        case toolChange(String)
        /// A bare `M0`.
        case programPause
    }

    enum State: Equatable, Sendable {
        case idle, verifying, running, pausedByUser
        case suspended(SuspendReason)
        case probing, stopping, completed
        case failed(String)
    }

    /// Set by the controller that owns this streamer.
    weak var controller: MachineController?

    private(set) var state: State = .idle {

        didSet { if state != oldValue { syncLiveClock() } }

    }
    private(set) var program: MachineProgram?
    /// 1-based number of the last program line handed to the controller.
    private(set) var sentLine = 0
    /// 1-based number of the last program line acknowledged.
    private(set) var ackedLine = 0
    /// Index into `program.parsed.moves` of the position-matched move.
    private(set) var matchedMove = 0
    /// Program line → decoded error, for the red marks in the Program tab.
    private(set) var lineErrors: [Int: String] = [:]
    /// Wall-clock seconds of the job, not counting time spent suspended.
    /// Updated on every status report, so it is not observable: views show
    /// `elapsedSeconds`, which only publishes once a second.
    @ObservationIgnored private(set) var elapsed: TimeInterval = 0 {
        didSet { let whole = Int(elapsed); if elapsedSeconds != whole { elapsedSeconds = whole } }
    }
    private(set) var elapsedSeconds = 0

    /// `parsed.totalTime − currentTime` while a program job is loaded and
    /// running or done; nil for verify/probe jobs and when idle.
    var remaining: TimeInterval? {
        guard mode == .run, let program, isActive || state == .completed else { return nil }
        let time = controller?.app?.player.currentTime ?? 0
        return max(0, program.parsed.totalTime - time)
    }

    /// 0…1: by time for a program job, by acknowledged lines otherwise.
    var progressFraction: Double {
        if mode == .run, let program {
            let total = program.parsed.totalTime
            guard total > 0 else { return state == .completed ? 1 : 0 }
            let time = controller?.app?.player.currentTime ?? 0
            return min(1, max(0, time / total))
        }
        guard !sequence.isEmpty else { return 0 }
        return min(1, max(0, Double(ackedCount) / Double(sequence.count)))
    }

    var isActive: Bool {
        switch state {
        case .running, .pausedByUser, .suspended, .probing, .stopping, .verifying: true
        case .idle, .completed, .failed: false
        }
    }

    var isSuspended: Bool {
        if case .suspended = state { return true }
        return false
    }

    /// Lines handed to the controller and not yet acknowledged.
    var hasInFlight: Bool { !window.isEmpty }

    struct ErrorPrompt: Equatable {
        var line: Int
        var message: String
    }
    /// Set when a program line returned `error:N`: the machine is feed-held
    /// and the UI asks "Ignore and continue" (`ignoreError`) or "Stop job"
    /// (`stopAfterError`).
    var errorPrompt: ErrorPrompt?
    /// Where Continue will resume while suspended; otherwise what "Send
    /// from line…" proposes (the position-matched line).
    var resumeLine: Int?
    /// The map being probed (`state == .probing`), with the points recorded so far.
    var heightMapTarget: HeightMap?
    /// Called with (probeIndex, machineZ) for every point while probing.
    var heightMapProbed: ((Int, Double) -> Void)?
    /// The last refusal, failure or completion text, for the UI and the log.
    private(set) var lastMessage: String?
    /// The stop sequence is waiting for `Hold:0` longer than expected: the
    /// UI offers `keepWaiting()` / `resetAnyway()`.
    private(set) var stopPrompt = false
    /// The program carries a height map that no longer matches the machine's
    /// work offset (XY moved, Z re-zeroed): the start is held until the UI
    /// answers with `applyAnyway()`, `runWithoutMap()` or `cancelValidity()`.
    /// A map of the wrong side, an incomplete one or an unknown offset is
    /// refused outright (`lastMessage`).
    private(set) var validityPrompt: [HeightMap.Issue]?

    // MARK: Private

    private enum Mode { case run, verify, probe }

    private struct Item {
        /// ≥ 1: a program line number; ≤ 0: a preamble line (−k).
        let index: Int
        let text: String
    }

    private var mode: Mode = .run
    private var window = StreamWindow(byteBudget: 128, lineBudget: 8)
    private var sequence: [Item] = []
    private var cursor = 0
    private var ackedCount = 0
    private var allSent = false
    @ObservationIgnored private var awaitingIdle = false
    private var suspending = false
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?
    @ObservationIgnored private var elapsedBase: TimeInterval = 0
    /// `moveStartByLine[n]` = index of the first move whose `sourceLine` ≥ n.
    private var moveStartByLine: [Int] = []
    @ObservationIgnored private var lastMatchedPosition: MachinePosition?
    private var stopWaiter: CheckedContinuation<Bool, Never>?
    /// The park sequence of a tool change (`beginSuspension`); cancelled by
    /// a stop so nothing of it goes out after the reset.
    private var suspensionTask: Task<Void, Never>?
    /// Idle reports seen in a row while `awaitingIdle`.
    @ObservationIgnored private var idleReports = 0
    /// The most free planner blocks any report showed (`Bf:`): a report with
    /// that many free again means the planner is empty.
    @ObservationIgnored private var maxPlannerBlocks: Int?
    /// What to do once the height-map prompt is answered.
    private enum StartRequest { case start, fromLine(Int), continueSuspend }
    private var pendingStart: StartRequest?

    /// What the current job is, for messages: the program's name, or the height map.
    var jobName: String {
        mode == .probe ? "height map" : (program?.name ?? "program")
    }

    // MARK: - Loading

    /// Loads a prepared program (no job may be active) and publishes it as
    /// the live job so the canvases draw the exact text being sent.
    func load(_ program: MachineProgram) {
        guard !isActive else { return }
        if let old = self.program, old.url != program.url {
            try? FileManager.default.removeItem(at: old.url)
        }
        self.program = program
        state = .idle
        mode = .run
        sentLine = 0
        ackedLine = 0
        ackedCount = 0
        matchedMove = 0
        lineErrors = [:]
        errorPrompt = nil
        validityPrompt = nil
        pendingStart = nil
        resumeLine = nil
        elapsed = 0
        elapsedBase = 0
        startedAt = nil
        window.reset()
        sequence = []
        buildMoveIndex(program.parsed)
        // The preview keeps its playback until the program is actually sent
        // (begin publishes the live job; finish clears it).
    }

    func unload() {
        guard !isActive else { return }
        if let program {
            try? FileManager.default.removeItem(at: program.url)
        }
        program = nil
        state = .idle
        sequence = []
        lineErrors = [:]
        errorPrompt = nil
        resumeLine = nil
        controller?.app?.player.job = nil
    }

    private func publishLiveJob(_ program: MachineProgram) {
        guard let app = controller?.app else { return }
        let document = app.preview.document
        app.player.job = LiveJob(token: program.token, kind: program.kind, layer: program.parsed, url: program.url,
                                 backToFront: document?.backToFront ?? .identity,
                                 projectSize: document?.projectSize)
    }

    private func buildMoveIndex(_ parsed: ParsedLayer) {
        let moves = parsed.moves
        let lineCount = max(parsed.lineCount, moves.last?.sourceLine ?? 0) + 2
        var index = [Int](repeating: moves.count, count: lineCount + 1)
        var moveIndex = moves.count - 1
        // Walk backwards so each line gets the first move at or after it.
        for line in stride(from: lineCount, through: 0, by: -1) {
            while moveIndex >= 0, moves[moveIndex].sourceLine >= line { moveIndex -= 1 }
            index[line] = moveIndex + 1
        }
        moveStartByLine = index
    }

    private func firstMove(atOrAfter line: Int) -> Int {
        guard !moveStartByLine.isEmpty else { return 0 }
        let clamped = min(max(line, 0), moveStartByLine.count - 1)
        return moveStartByLine[clamped]
    }

    // MARK: - Starting

    /// Streams the loaded program from line 1.
    func start() async {
        await start(checkingMap: true)
    }

    private func start(checkingMap: Bool) async {
        guard let program, let controller, !isActive else { return }
        if let reason = controller.preflight(program) { refuse(reason); return }
        if checkingMap, !heightMapAllows(program, request: .start) { return }
        begin(mode: .run, items: program.lines.enumerated().map { Item(index: $0.offset + 1, text: $0.element) },
              fromLine: 1, resetElapsed: true)
    }

    /// Streams from `line` after the preamble. A line in a later tool
    /// segment first enters `.suspended` so the right bit can be mounted and
    /// Z probed; `continueAfterSuspend` then sends the preamble and the rest.
    func start(fromLine line: Int, preamble: [String]) async {
        await start(fromLine: line, preamble: preamble, checkingMap: true)
    }

    private func start(fromLine line: Int, preamble: [String], checkingMap: Bool) async {
        guard let program, let controller, !isActive else { return }
        let line = min(max(line, 1), program.lines.count)
        if let segment = program.segment(containing: line), segment != program.segments.first {
            lineErrors = [:]
            errorPrompt = nil
            mode = .run
            elapsed = 0
            elapsedBase = 0
            startedAt = nil
            resumeLine = line
            matchedMove = firstMove(atOrAfter: line)
            controller.app?.player.currentTime = startTime(ofMove: matchedMove)
            let reason: SuspendReason = segment.toolLabel == "Program pause" ? .programPause : .toolChange(segment.toolLabel)
            state = .suspended(reason)
            controller.noteJob("Send from line \(line): mount the bit for “\(segment.toolLabel)”, probe Z, then Continue.")
            return
        }
        if let reason = controller.preflight(program) { refuse(reason); return }
        if let reason = controller.preflight(lines: preamble) { refuse("Resume preamble: " + reason); return }
        if checkingMap, !heightMapAllows(program, request: .fromLine(line)) { return }
        begin(mode: .run, items: items(preamble: preamble, program: program, from: line), fromLine: line, resetElapsed: true)
    }

    /// Dry run in the controller's check mode (`$C`): every line is parsed,
    /// nothing moves. Completion is the last acknowledgement.
    func verify() async {
        guard let program, let controller, !isActive else { return }
        guard controller.isConnected else { refuse("Not connected."); return }
        guard controller.status.state == .idle, controller.alarmCode == nil else {
            refuse("The machine must be Idle to verify (now \(controller.status.state.name)).")
            return
        }
        do {
            try await controller.sendInternal(GRBLCommand.checkMode)
        } catch {
            refuse("Could not enter check mode: \(error.localizedDescription)")
            return
        }
        begin(mode: .verify, items: program.lines.enumerated().map { Item(index: $0.offset + 1, text: $0.element) },
              fromLine: 1, resetElapsed: true)
    }

    /// Runs the map's probe program (`frame` = design → work, see
    /// `HeightMap`), recording every `[PRB:]` into `heightMapTarget`.
    /// Completion leaves the recorded map there for the controller to store.
    func probe(map: HeightMap, frame: CGAffineTransform) async {
        guard let controller, !isActive else { return }
        guard controller.isConnected else { refuse("Not connected."); return }
        guard controller.status.state == .idle, controller.alarmCode == nil else {
            refuse("The machine must be Idle to probe (now \(controller.status.state.name)).")
            return
        }
        guard controller.positionTrusted else { refuse("Position may be lost — home the machine first."); return }
        guard controller.status.workOffset != nil else { refuse("Work offset unknown — wait for a status report."); return }
        var target = map
        target.clear()
        let lines = target.probeProgram(frame: frame)
        if let reason = controller.preflight(lines: lines) { refuse("Height map: " + reason); return }
        heightMapTarget = target
        begin(mode: .probe, items: lines.enumerated().map { Item(index: $0.offset + 1, text: $0.element) },
              fromLine: 1, resetElapsed: true)
    }

    private func items(preamble: [String], program: MachineProgram, from line: Int) -> [Item] {
        var items = preamble.enumerated().map { Item(index: -$0.offset, text: $0.element) }
        for number in line...program.lines.count {
            items.append(Item(index: number, text: program.lines[number - 1]))
        }
        return items
    }


    /// A running program never lets the preview clock free-run: every status
    /// report sets it from the matched position (see steerClock), and between
    /// reports a frame-rate task projects the smoothed machine position — the
    /// one the bit model follows — onto the current move, so the channel
    /// opens exactly under the bit.
    private func syncLiveClock() {
        guard let player = controller?.app?.player, player.job != nil else { stopFrameSync(); return }
        if player.isPlaying { player.isPlaying = false }
        if player.speedMultiplier != 1 { player.speedMultiplier = 1 }
        let shouldRun = state == .running && mode == .run
        if shouldRun, frameSync == nil {
            // Once per screen refresh, so the reveal moves with the bit
            // (which the 3D view places from the same interpolator per frame).
            let ticker = FrameTicker { [weak self] in
                guard let self, self.state == .running else { self?.stopFrameSync(); return }
                self.syncClockToSmoothedPosition()
            }
            ticker.start()
            frameSync = ticker
        } else if !shouldRun {
            stopFrameSync()
        }
    }

    private func stopFrameSync() {
        frameSync?.stop()
        frameSync = nil
    }

    /// Non-nil while the clock follows the machine at frame rate (`steerClock`
    /// then leaves the clock to it).
    @ObservationIgnored private var frameSync: FrameTicker?

    /// Projects the smoothed machine position onto the matched move and its
    /// neighbours (a local search; the per-report matcher keeps `matchedMove`
    /// honest) and sets the preview clock from it.
    private func syncClockToSmoothedPosition() {
        guard let controller, let program,
              let position = controller.motion.position(at: ProcessInfo.processInfo.systemUptime),
              let player = controller.app?.player else { return }
        let moves = program.parsed.moves
        guard !moves.isEmpty else { return }
        let lower = max(0, matchedMove - 2)
        let upper = min(moves.count - 1, matchedMove + 4)
        var best = matchedMove, bestDistance = Double.greatestFiniteMagnitude, bestFraction = 0.0
        for i in lower...upper {
            let (distance, t) = Self.distance(from: position, to: moves[i])
            if distance < bestDistance - 1e-6 { bestDistance = distance; best = i; bestFraction = t }
        }
        guard bestDistance < 2 else { return }   // far off the path: leave it to the report matcher
        let start = best > 0 ? moves[best - 1].cumulativeTime : 0
        let duration = moves[best].cumulativeTime - start
        let time = start + duration * bestFraction
        if abs(time - player.currentTime) > 1e-4 { player.currentTime = time }
    }

    private func begin(mode: Mode, items: [Item], fromLine line: Int, resetElapsed: Bool) {
        if let program, controller?.app?.player.job?.token != program.token { publishLiveJob(program) }
        self.mode = mode
        sequence = items
        cursor = 0
        ackedCount = 0
        window.reset()
        allSent = false
        awaitingIdle = false
        idleReports = 0
        suspending = false
        suspensionTask?.cancel()
        suspensionTask = nil
        errorPrompt = nil
        resumeLine = nil
        validityPrompt = nil
        pendingStart = nil
        lastMatchedPosition = nil
        if mode == .run {
            lineErrors = [:]
            sentLine = line - 1
            ackedLine = line - 1
            matchedMove = firstMove(atOrAfter: line)
            controller?.app?.player.currentTime = startTime(ofMove: matchedMove)
        } else {
            sentLine = 0
            ackedLine = 0
        }
        if resetElapsed {
            elapsed = 0
            elapsedBase = 0
        }
        startedAt = ContinuousClock.now
        switch mode {
        case .run: state = .running
        case .verify: state = .verifying
        case .probe: state = .probing
        }
        lastMessage = nil
        let what: String
        switch mode {
        case .run: what = "Sending \(program?.name ?? "program") from line \(line) (\(items.count) lines)."
        case .verify: what = "Verifying \(program?.name ?? "program") in check mode (\(items.count) lines)."
        case .probe: what = "Probing height map (\(heightMapTarget?.totalCount ?? 0) points)."
        }
        controller?.noteJob(what)
        feed()
    }

    private func refuse(_ reason: String) {
        lastMessage = reason
        controller?.noteJob("Refused: " + reason)
    }

    // MARK: - Pause / resume / continue

    func pause() {
        guard state == .running, let controller else { return }
        state = .pausedByUser
        controller.feedHold()
        controller.noteJob("Hold.")
    }

    func resume() {
        guard state == .pausedByUser, let controller else { return }
        state = .running
        controller.resume()
        controller.noteJob("Resume.")
        feed()
    }

    /// Continues a suspended job: the preamble re-establishes the modal
    /// state safely, then the lines from `resumeLine` follow.
    func continueAfterSuspend(preamble: [String]) async {
        await continueAfterSuspend(preamble: preamble, checkingMap: true)
    }

    private func continueAfterSuspend(preamble: [String], checkingMap: Bool) async {
        guard case .suspended = state, let program, let controller, let line = resumeLine else { return }
        guard controller.status.state == .idle, controller.alarmCode == nil else {
            refuse("The machine must be Idle to continue (now \(controller.status.state.name)).")
            return
        }
        if let reason = controller.preflight(program) { refuse(reason); return }
        if let reason = controller.preflight(lines: preamble) { refuse("Resume preamble: " + reason); return }
        if checkingMap, !heightMapAllows(program, request: .continueSuspend) { return }
        begin(mode: .run, items: items(preamble: preamble, program: program, from: line), fromLine: line, resetElapsed: false)
    }

    // MARK: - Height map validity

    /// Whether the program's height map (if any) still matches the machine:
    /// true to go ahead. Hard problems refuse; a moved XY origin or a
    /// re-zeroed Z raises `validityPrompt` and remembers `request`.
    private func heightMapAllows(_ program: MachineProgram, request: StartRequest) -> Bool {
        guard let map = program.options.heightMap, let controller else { return true }
        let issues = map.validity(currentDesignOrigin: controller.currentDesignOrigin(side: program.kind.boardSide),
                                  programSide: program.kind.boardSide)
        if issues.isEmpty { return true }
        if issues.contains(.sideMismatch) {
            refuse("The height map was probed on the \(map.side.title.lowercased()) side; \(program.name) is cut on the "
                   + "\(program.kind.boardSide.title.lowercased()) side. Prepare the program without the map.")
            return false
        }
        if issues.contains(.incomplete) {
            refuse("The height map is incomplete (\(map.probedCount) of \(map.totalCount) points) — probe it again.")
            return false
        }
        if issues.contains(.wcoUnknown) {
            refuse("Work offset unknown — wait for a status report before sending a height-mapped program.")
            return false
        }
        if issues.contains(.originUnknown) {
            refuse("The height map does not record where the board was when it was probed — probe it again.")
            return false
        }
        pendingStart = request
        validityPrompt = issues
        controller.noteJob("Height map check: the work origin moved on the board since the map was probed — waiting for the operator.")
        return false
    }

    /// Answer to `validityPrompt`: send with the map as prepared.
    func applyAnyway() {
        guard let request = pendingStart else { validityPrompt = nil; return }
        validityPrompt = nil
        pendingStart = nil
        controller?.noteJob("Height map applied anyway.")
        Task { [weak self] in
            guard let self, let controller = self.controller else { return }
            switch request {
            case .start:
                await self.start(checkingMap: false)
            case .fromLine(let line):
                guard let preamble = controller.resumePreamble(line: line) else { return }
                await self.start(fromLine: line, preamble: preamble, checkingMap: false)
            case .continueSuspend:
                guard let line = self.resumeLine, let preamble = controller.resumePreamble(line: line) else { return }
                await self.continueAfterSuspend(preamble: preamble, checkingMap: false)
            }
        }
    }

    /// Answer to `validityPrompt`: prepare the program again without the
    /// map and send that instead. Not possible for a suspended job — its
    /// text is already warped.
    func runWithoutMap() {
        guard let request = pendingStart, let program, let controller else { validityPrompt = nil; return }
        validityPrompt = nil
        pendingStart = nil
        guard !isActive else {
            refuse("The running program is already warped by the height map — stop it to send it without the map.")
            return
        }
        guard let layer = controller.app?.preview.document?.layers.first(where: { $0.id == program.kind }) else {
            refuse("\(program.name) is no longer in the preview — choose it again.")
            return
        }
        var options = program.options
        options.heightMap = nil
        let name = program.name
        controller.noteJob("Preparing \(name) without the height map.")
        Task { [weak self] in
            do {
                _ = try await controller.prepareProgram(layer: layer, name: name, options: options)
            } catch {
                self?.refuse("Could not prepare \(name) without the height map: \(error.localizedDescription)")
                return
            }
            guard let self else { return }
            switch request {
            case .start:
                await self.start(checkingMap: false)
            case .fromLine(let line):
                guard let preamble = controller.resumePreamble(line: line) else { return }
                await self.start(fromLine: line, preamble: preamble, checkingMap: false)
            case .continueSuspend:
                break
            }
        }
    }

    /// Answer to `validityPrompt`: do nothing (re-probe first).
    func cancelValidity() {
        guard validityPrompt != nil else { return }
        validityPrompt = nil
        pendingStart = nil
        controller?.noteJob("Send cancelled: height map check.")
    }

    func ignoreError() {
        guard errorPrompt != nil, let controller else { return }
        errorPrompt = nil
        controller.resume()
        controller.noteJob("Error ignored, continuing.")
        if allSent, window.isEmpty { awaitingIdle = true } else { feed() }
    }

    func stopAfterError() {
        guard errorPrompt != nil else { return }
        errorPrompt = nil
        Task { await stop() }
    }

    // MARK: - Stop

    /// Stateful stop: feed hold → wait for `Hold:0` (or Idle/Alarm) → soft
    /// reset → wait for the post-reset Idle → restore the modal state. The
    /// reset only happens once the machine has come to rest, so the position
    /// stays trusted; when that takes too long the UI is asked whether to
    /// keep waiting or reset anyway.
    func stop() async {
        guard let controller, isActive, state != .stopping else { return }
        let previous = state
        state = .stopping
        errorPrompt = nil
        validityPrompt = nil
        pendingStart = nil
        // A tool-change park in progress must not send anything after the reset.
        suspensionTask?.cancel()
        suspensionTask = nil
        controller.noteJob("Stopping.")

        switch previous {
        case .suspended:
            // Parked and idle: nothing is in flight.
            finish(.failed("Stopped by user"))
            return
        case .verifying:
            window.reset()
            try? await controller.sendInternal(GRBLCommand.checkMode)
            finish(.failed("Verification stopped"))
            return
        default:
            break
        }

        controller.feedHold()
        let atRest: (GRBLStatus) -> Bool = { $0.state.isHoldComplete || $0.state == .idle || $0.state == .alarm }
        var settled = await controller.waitForStatus(timeout: 3, atRest)
        // A link loss (or reset) meanwhile already finished the job with its
        // own reason: never finish it twice or overwrite that reason.
        guard state == .stopping else { return }
        while !settled {
            stopPrompt = true
            let keepWaiting = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                stopWaiter = continuation
            }
            stopPrompt = false
            guard state == .stopping else { return }
            guard keepWaiting else { break }
            settled = await controller.waitForStatus(timeout: 3, atRest)
            guard state == .stopping else { return }
        }
        await controller.softReset()
        window.reset()
        _ = await controller.waitForStatus(timeout: 3) { $0.state == .idle || $0.state == .alarm }
        guard state == .stopping else { return }
        if controller.status.state == .idle {
            try? await controller.sendInternal("G21 G90 \(controller.activeWCS) M5 M9")
        }
        guard state == .stopping else { return }
        finish(.failed("Stopped by user"))
    }

    /// Answer to `stopPrompt`: keep waiting for the hold to complete.
    func keepWaiting() {
        stopWaiter?.resume(returning: true)
        stopWaiter = nil
    }

    /// Answer to `stopPrompt`: reset now; the controller marks the position untrusted.
    func resetAnyway() {
        stopWaiter?.resume(returning: false)
        stopWaiter = nil
    }

    /// Waits until the job is no longer active (for scripts and the
    /// height-map store).
    func waitUntilFinished() async {
        while isActive {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Feeding

    private var canFeed: Bool {
        guard errorPrompt == nil, !suspending else { return false }
        switch state {
        case .running, .verifying, .probing: return true
        default: return false
        }
    }

    private func feed() {
        guard let controller, canFeed else { return }
        while cursor < sequence.count {
            let item = sequence[cursor]
            if mode == .run, item.index >= 1, let program, program.toolChangeLines.contains(item.index),
               let next = program.segment(after: item.index) {
                // Let the planner finish what it has before parking.
                guard window.isEmpty else { return }
                beginSuspension(atLine: item.index, next: next, program: program)
                return
            }
            guard window.canSend(item.text) else { return }
            window.didSend(item.text, index: item.index)
            cursor += 1
            if item.index >= 1 { sentLine = item.index }
            controller.enqueueJobLine(item.text)
        }
        allSent = true
        if window.isEmpty { noteAllAcknowledged() }
    }

    private func beginSuspension(atLine line: Int, next: ToolSegment, program: MachineProgram) {
        guard let controller else { return }
        suspending = true
        let reason: SuspendReason = next.toolLabel == "Program pause" ? .programPause : .toolChange(next.toolLabel)
        suspensionTask?.cancel()
        suspensionTask = Task { [weak self] in
            // The park runs while the job is still `.running` (or held); a
            // stop cancels it — nothing more may go out after the reset.
            @MainActor func live() -> Bool {
                guard let self, !Task.isCancelled else { return false }
                return self.state == .running || self.state == .pausedByUser
            }
            // Drain, spindle off, park high: the program's own M5/retract ran
            // just before, this makes sure of it whatever the file did.
            guard live() else { return }
            try? await controller.sync()
            guard live() else { return }
            try? await controller.sendInternal(GRBLCommand.spindleOff)
            guard live() else { return }
            if let safe = controller.safePositionLine() {
                try? await controller.sendInternal(safe)
            } else {
                try? await controller.sendInternal("G90 G0 Z" + GRBLCommand.number(max(program.parsed.zMax, program.safeZ)))
            }
            // The park's ok comes when it is planned; Continue needs Idle.
            guard live() else { return }
            try? await controller.sync()
            guard live() else { return }
            _ = await controller.waitForStatus(timeout: 5) { $0.state == .idle }
            guard live(), let self else { return }
            self.suspensionTask = nil
            self.resumeLine = next.resumeLine
            self.cursor = self.sequence.firstIndex { $0.index == next.resumeLine } ?? self.sequence.count
            self.elapsedBase = self.elapsed
            self.startedAt = nil
            self.suspending = false
            self.state = .suspended(reason)
            switch reason {
            case .toolChange(let message): controller.noteJob("Tool change at line \(line): \(message) — probe Z, then Continue.")
            case .programPause: controller.noteJob("Program pause at line \(line) — Continue when ready.")
            }
        }
    }

    private func noteAllAcknowledged() {
        switch mode {
        case .verify:
            Task { [weak self] in
                guard let self, let controller = self.controller else { return }
                // Leaving check mode resets the controller; the banner that
                // follows is expected (see noteBanner).
                try? await controller.sendInternal(GRBLCommand.checkMode)
                guard self.state == .verifying else { return }
                let errors = self.lineErrors.count
                self.finish(.completed, message: errors == 0 ? "Verified: no errors." : "Verified: \(errors) line\(errors == 1 ? "" : "s") with errors.")
            }
        case .run, .probe:
            // Done when the machine has executed it all, not when the last
            // line was merely planned (see noteStatus).
            idleReports = 0
            awaitingIdle = true
        }
    }

    // MARK: - Responses from the controller

    /// `ok`/`error:`/`ALARM`/`[PRB:]` for the line at the window's head
    /// (`line` is informational; the window keeps the order).
    func noteResponse(_ response: GRBLResponse, forLine line: Int?) {
        switch response {
        case .ok:
            guard let index = window.ack() else { return }
            didAcknowledge(index)

        case .error(let code):
            guard let index = window.ack() else { return }
            let description = "error:\(code) — \(GRBLError.description(for: code))"
            if index >= 1 { lineErrors[index] = description }
            switch mode {
            case .verify:
                didAcknowledge(index)
            case .probe:
                fail("Probe program line \(index): \(description)")
            case .run:
                guard state == .running || state == .pausedByUser else { didAcknowledge(index); return }
                ackedCount += 1
                if index >= 1 { ackedLine = index }
                controller?.feedHold()
                let label = index >= 1 ? "Line \(index)" : "Resume preamble line \(1 - index)"
                errorPrompt = ErrorPrompt(line: max(index, 0), message: "\(label): \(description)")
                controller?.noteJob("\(label): \(description) — machine held.")
            }

        case .alarm(let code):
            guard isActive, state != .stopping else { return }
            fail("ALARM:\(code) — \(GRBLAlarm.description(for: code))")

        case .probe(let position, let success):
            guard mode == .probe, state == .probing, var map = heightMapTarget,
                  let head = window.pendingIndices.first,
                  let probeIndex = map.probeIndex(forProgramLine: head - 1) else { return }
            let label = probeIndex < 0 ? "the reference point" : "point \(probeIndex + 1) of \(map.totalCount)"
            guard success else {
                fail("Probe did not trigger at \(label).")
                return
            }
            let workZ = position.z - (controller?.status.workOffset?.z ?? 0)
            guard workZ <= map.zClear - 0.5 else {
                fail("Probe triggered at work Z \(GRBLCommand.number(workZ)) at \(label), right under the clearance height — a short circuit?")
                return
            }
            guard workZ >= map.zMaxDepth - 1e-6 else {
                fail("Probe at \(label) reached the maximum depth without contact.")
                return
            }
            map.record(probeIndex: probeIndex, machineZ: position.z)
            heightMapTarget = map
            heightMapProbed?(probeIndex, position.z)

        default:
            break
        }
    }

    private func didAcknowledge(_ index: Int) {
        ackedCount += 1
        if index >= 1 { ackedLine = index }
        guard errorPrompt == nil else { return }
        if allSent, window.isEmpty {
            noteAllAcknowledged()
        } else {
            feed()
        }
    }

    /// The controller reset (banner): nothing in flight will be answered.
    func noteBanner() {
        window.reset()
        switch state {
        case .stopping, .idle, .completed, .failed:
            break
        case .verifying where allSent:
            // The reset that leaving check mode causes.
            break
        default:
            fail("Controller reset")
        }
    }

    /// The operator hit E-STOP: the controller is being reset without
    /// waiting for a hold, so nothing in flight will be answered and the job
    /// ends at once (the banner that follows then finds it already over).
    func noteEmergencyStop() {
        window.reset()
        guard isActive else { return }
        fail("Emergency stop")
    }

    /// The link died or was closed.
    func noteLinkLost() {
        guard isActive else { return }
        window.reset()
        fail("Connection lost")
    }

    // MARK: - Status reports

    func noteStatus(_ status: GRBLStatus) {
        if let startedAt {
            elapsed = elapsedBase + startedAt.duration(to: ContinuousClock.now).seconds
        }
        if let blocks = status.plannerBlocks { maxPlannerBlocks = max(maxPlannerBlocks ?? 0, blocks) }
        if awaitingIdle, errorPrompt == nil {
            // One Idle can be a report generated before the last line was
            // planned: completion needs two in a row, or one whose planner
            // is entirely free (`Bf:` back at the most free blocks seen).
            guard status.state == .idle else { idleReports = 0; return }
            idleReports += 1
            let plannerEmpty = status.plannerBlocks.map { $0 >= max(maxPlannerBlocks ?? 0, 15) } ?? false
            guard idleReports >= 2 || plannerEmpty else { return }
            awaitingIdle = false
            idleReports = 0
            switch mode {
            case .run: finish(.completed, message: "Program complete.")
            case .probe: finish(.completed, message: "Height map probed: \(heightMapTarget?.probedCount ?? 0) points.")
            case .verify: break
            }
            return
        }
        guard mode == .run, let program, let position = status.workPosition else { return }
        switch state {
        case .running, .pausedByUser, .stopping: break
        default: return
        }
        matchPosition(position, in: program)
    }

    /// Finds the move nearest the reported work position among the moves
    /// between the last match and the acknowledged line (the planner can
    /// only be executing something already acknowledged), and sets the
    /// preview clock to that point in the move — one publish per report.
    /// A plunge and its retract share the same line, so a move running
    /// against the observed direction of travel is penalised; ties go to
    /// the earlier move.
    private func matchPosition(_ position: MachinePosition, in program: MachineProgram) {
        let moves = program.parsed.moves
        guard !moves.isEmpty else { return }
        let upper = min(firstMove(atOrAfter: ackedLine + 1) - 1, moves.count - 1)
        let lower = min(matchedMove, moves.count - 1)
        guard upper >= lower else { return }
        var travel: (x: Double, y: Double, z: Double)?
        if let previous = lastMatchedPosition {
            let d = (x: position.x - previous.x, y: position.y - previous.y, z: position.z - previous.z)
            if d.x * d.x + d.y * d.y + d.z * d.z > 1e-6 { travel = d }
        }
        lastMatchedPosition = position
        // Bound the scan: a report arrives every 200 ms; the window never
        // holds more than a few lines, but one line can be a long arc.
        let last = min(upper, lower + 4000)
        var best = lower
        var bestScore = Double.infinity
        var bestFraction = 0.0
        for i in lower...last {
            let move = moves[i]
            var (score, fraction) = Self.distance(from: position, to: move)
            if let travel {
                let dx = move.end.x - move.start.x, dy = move.end.y - move.start.y, dz = move.zEnd - move.zStart
                if dx * travel.x + dy * travel.y + dz * travel.z < -1e-9 { score += 0.5 }
            }
            if score < bestScore - 1e-4 {
                bestScore = score
                best = i
                bestFraction = fraction
            }
        }
        if matchedMove != best { matchedMove = best }
        let start = best > 0 ? moves[best - 1].cumulativeTime : 0
        let duration = moves[best].cumulativeTime - start
        steerClock(toward: start + duration * bestFraction)
        if state == .running, resumeLine != moves[best].sourceLine { resumeLine = moves[best].sourceLine }
    }

    /// The preview clock follows the matched machine position on every
    /// report. It does not run on its own between reports: the bit model is
    /// the (smoothed) machine itself, and the reveal — holes, channels,
    /// progress — must stay locked to it rather than to an estimate.
    private func steerClock(toward matched: Double) {
        guard let player = controller?.app?.player else { return }
        if player.isPlaying { player.isPlaying = false }
        if player.speedMultiplier != 1 { player.speedMultiplier = 1 }   // assigning publishes even when unchanged
        // While running, the frame-rate sync (the bit's own smoothed
        // position) is the only writer: the mask only ever grows, so a
        // report landing ahead of the bit would open the channel in front
        // of it. Reports then only keep `matchedMove` honest. Held or
        // suspended, the report is the position.
        if frameSync == nil { player.currentTime = matched }
    }

    /// 3D distance from a point to a move's segment, with the parameter of
    /// the closest point along it.
    private static func distance(from p: MachinePosition, to move: ToolpathMove) -> (Double, Double) {
        let ax = move.start.x, ay = move.start.y, az = move.zStart
        let dx = move.end.x - ax, dy = move.end.y - ay, dz = move.zEnd - az
        let length2 = dx * dx + dy * dy + dz * dz
        var t = 0.0
        if length2 > 1e-12 {
            t = ((p.x - ax) * dx + (p.y - ay) * dy + (p.z - az) * dz) / length2
            t = min(1, max(0, t))
        }
        let cx = ax + dx * t - p.x, cy = ay + dy * t - p.y, cz = az + dz * t - p.z
        return ((cx * cx + cy * cy + cz * cz).squareRoot(), t)
    }

    private func startTime(ofMove index: Int) -> Double {
        guard let moves = program?.parsed.moves, !moves.isEmpty else { return 0 }
        let i = min(max(index, 0), moves.count - 1)
        return i > 0 ? moves[i - 1].cumulativeTime : 0
    }

    // MARK: - Ending

    private func fail(_ reason: String) {
        guard isActive else { return }
        finish(.failed(reason), message: reason)
    }

    private func finish(_ end: State, message: String? = nil) {
        // Hand the preview back to playback; the job bar's summary keeps the result.
        controller?.app?.player.job = nil
        if let startedAt {
            elapsed = elapsedBase + startedAt.duration(to: ContinuousClock.now).seconds
        }
        startedAt = nil
        elapsedBase = elapsed
        awaitingIdle = false
        idleReports = 0
        allSent = false
        suspending = false
        suspensionTask?.cancel()
        suspensionTask = nil
        errorPrompt = nil
        validityPrompt = nil
        pendingStart = nil
        stopPrompt = false
        stopWaiter?.resume(returning: false)
        stopWaiter = nil
        window.reset()
        state = end
        if mode == .run, end == .completed, let program {
            controller?.app?.player.currentTime = program.parsed.totalTime
            matchedMove = max(program.parsed.moves.count - 1, 0)
            resumeLine = nil
        }
        if let message {
            lastMessage = message
            controller?.noteJob(message)
        }
        controller?.noteJobFinished(end)
    }
}
