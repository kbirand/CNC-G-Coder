import SwiftUI
import Combine

nonisolated extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

/// Time-based playback through one generated G-code program (one .ngc file).
/// The clock advances in simulated machine seconds — each move takes as long
/// as its length divided by its actual feed rate (XY feed, Z plunge feed, or
/// the assumed rapid rate for G0) — so at 1× the playback runs at 100% of the
/// real machining speed and the tool travels smoothly along every move,
/// including rapids between sections.
/// A program being streamed to the machine. Identity only — it is set once
/// when the job starts and cleared when it ends, so the views that observe
/// `PlaybackState` re-render twice per job, not once per acknowledged line.
/// While it is set, its `layer` (parsed from the exact text sent) is the
/// geometry every canvas draws for the selected program; the preview document
/// only supplies the other overlay layers and the board frame.
struct LiveJob: Identifiable {
    let token: UUID
    var id: UUID { token }
    /// The program's layer kind (`.test` for an external file).
    let kind: LayerKind
    /// Parsed from the text that is actually sent, so `sourceLine`s match it.
    let layer: ParsedLayer
    /// The sent text on disk, for the G-code tab.
    let url: URL
    /// The document's back→front mapping when the job started, so a preview
    /// refresh mid-job cannot move the drawing.
    let backToFront: CGAffineTransform
    let projectSize: CGSize?
}

@MainActor
final class PlaybackState: ObservableObject {

    @Published var selectedLayer: LayerKind? {
        didSet {
            // The streamer owns the clock while a job runs.
            if selectedLayer != oldValue, job == nil {
                currentTime = 0
                isPlaying = false
            }
        }
    }
    /// The program being sent to the machine, if any (see LiveJob).
    @Published var job: LiveJob? {
        didSet {
            if let job {
                isPlaying = false
                selectedLayer = job.kind
                currentTime = 0
            } else if oldValue != nil {
                // Reconcile with whatever document exists now.
                documentToken = nil
                syncToDocument()
            }
        }
    }
    /// The layer kind the canvases show: the job's while one runs.
    var displayedKind: LayerKind? { job?.kind ?? selectedLayer }
    /// Cache key for the selected program's geometry: changes when a job
    /// starts/ends or the document is regenerated.
    var renderToken: UUID? { job?.token ?? preview?.document?.token }
    /// "Set Origin" mode: the next click in the toolpath view places X0/Y0.
    /// App-wide so the sidebar can start it too.
    @Published var placingOrigin = false
    /// Simulated seconds into the program. Lives on `clock`, NOT published
    /// here: it changes 30× a second while playing, and publishing it on this
    /// object re-rendered every view that merely reads the layer selection —
    /// the whole settings sidebar included. Views that move with playback
    /// observe `clock` (see PlaybackTimeReader).
    let clock = PlaybackClock()
    /// The live value is always current; SwiftUI is told at most ~30× a
    /// second (a streaming job advances it once per screen refresh, and
    /// the 3D view reads it directly in that same tick — see
    /// `PlaybackClock.liveTime`).
    var currentTime: Double {
        get { clock.liveTime }
        set { clock.advance(to: newValue) }
    }
    @Published var speedMultiplier: Double = 1    // 1 = real machining speed
    @Published var isPlaying = false {
        didSet {
            if isPlaying { startLoop() } else { loopTask?.cancel() }
        }
    }

    weak var preview: PreviewController?
    private var loopTask: Task<Void, Never>?
    private var documentToken: UUID?

    var layer: ParsedLayer? {
        if let job { return job.layer }
        guard let selectedLayer else { return nil }
        return preview?.document?.layers.first { $0.id == selectedLayer }
    }

    var moves: [ToolpathMove] { layer?.moves ?? [] }
    var moveCount: Int { moves.count }
    var totalTime: Double { layer?.totalTime ?? 0 }

    /// Index of the move in progress at `currentTime`; nil once the program is done.
    var progressIndex: Int? {
        let moves = self.moves
        guard !moves.isEmpty, currentTime < totalTime - 1e-9 else { return nil }
        var lo = 0
        var hi = moves.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if moves[mid].cumulativeTime <= currentTime { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Number of fully completed moves (prefix rendering).
    var completedMoves: Int { progressIndex ?? moveCount }

    /// Fraction (0...1) through the in-progress move.
    var progressFraction: Double {
        guard let index = progressIndex else { return 1 }
        let move = moves[index]
        let startTime = index > 0 ? moves[index - 1].cumulativeTime : 0
        let duration = move.cumulativeTime - startTime
        guard duration > 1e-12 else { return 1 }
        return min(1, max(0, (currentTime - startTime) / duration))
    }

    var currentMove: ToolpathMove? {
        if let index = progressIndex { return moves[index] }
        return moves.last
    }

    /// True while scrubbed to mid-program: views ghost the remainder.
    var isEngaged: Bool {
        if job != nil { return true }
        return selectedLayer != nil && moveCount > 0 && currentTime < totalTime - 1e-9
    }

    /// Tool XY position, interpolated along the in-progress move.
    var toolPosition: CGPoint? {
        guard let move = currentMove else { return nil }
        guard progressIndex != nil else { return move.end }
        let f = progressFraction
        return CGPoint(x: move.start.x + (move.end.x - move.start.x) * f,
                       y: move.start.y + (move.end.y - move.start.y) * f)
    }

    /// Tool Z, interpolated along the in-progress move.
    var toolZ: Double? {
        guard let move = currentMove else { return nil }
        guard progressIndex != nil else { return move.zEnd }
        return move.zStart + (move.zEnd - move.zStart) * progressFraction
    }

    /// Adopt a newly generated document. If the selected layer still exists,
    /// keep it AND keep the timeline position (clamped) and play state, so a
    /// parameter tweak doesn't throw away where you were. Otherwise fall back
    /// to the first layer, rewound.
    func syncToDocument() {
        // A running job keeps its layer and clock whatever the document does;
        // `job`'s didSet reconciles once it ends.
        guard job == nil else { return }
        guard let doc = preview?.document else {
            // A drawn layer stays selected with nothing generated yet: the
            // editor is open on it.
            if selectedLayer?.isCustom != true { selectedLayer = nil }
            currentTime = 0
            isPlaying = false
            documentToken = nil
            return
        }
        guard documentToken != doc.token else { return }
        documentToken = doc.token

        if let selectedLayer, doc.layers.contains(where: { $0.id == selectedLayer }) {
            let wasPlaying = isPlaying
            isPlaying = false
            currentTime = min(currentTime, totalTime)
            if wasPlaying, currentTime < totalTime {
                isPlaying = true
            }
        } else if selectedLayer?.isCustom == true {
            // An empty drawn layer has no program yet; keep editing it.
            isPlaying = false
            currentTime = 0
        } else {
            isPlaying = false
            selectedLayer = doc.layers.first?.id
            currentTime = 0
        }
    }

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                let now = clock.now
                let dt = last.duration(to: now).seconds
                last = now
                self.currentTime = min(self.totalTime, self.currentTime + dt * self.speedMultiplier)
                if self.currentTime >= self.totalTime {
                    self.isPlaying = false
                    break
                }
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30 fps
            }
        }
    }
}

/// The playback position alone, so only the views that animate with it
/// re-render on every tick.
@MainActor
final class PlaybackClock: ObservableObject {
    /// The published time: views that follow playback observe this.
    @Published private(set) var currentTime: Double = 0
    /// The latest time set, possibly ahead of `currentTime` by one refresh.
    private(set) var liveTime: Double = 0
    private var lastPublish: TimeInterval = 0
    /// Just under a 30 Hz frame: the simulation loop's ~30 Hz writes all
    /// pass, a streaming job's 60 Hz writes pass every other time.
    static let minimumPublishInterval: TimeInterval = 1.0 / 45

    /// Sets the time; publishes it unless the previous publish was less
    /// than `minimumPublishInterval` ago — except when the value jumps (a
    /// seek, a reset to zero), which is always published at once.
    func advance(to time: Double) {
        liveTime = time
        let now = ProcessInfo.processInfo.systemUptime
        let jump = abs(time - currentTime) > 0.5 || time == 0
        if jump || now - lastPublish >= Self.minimumPublishInterval {
            lastPublish = now
            currentTime = time
        } else if !flushScheduled {
            // Make sure the last value of a burst still gets published.
            flushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(34))
                guard let self else { return }
                self.flushScheduled = false
                if self.currentTime != self.liveTime { self.lastPublish = ProcessInfo.processInfo.systemUptime; self.currentTime = self.liveTime }
            }
        }
    }
    private var flushScheduled = false
}

/// Re-evaluates `content` on every playback tick, without invalidating the
/// view that contains it.
struct PlaybackTimeReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}
