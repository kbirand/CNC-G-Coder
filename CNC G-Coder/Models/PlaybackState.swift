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
@MainActor
final class PlaybackState: ObservableObject {

    @Published var selectedLayer: LayerKind? {
        didSet {
            if selectedLayer != oldValue {
                currentTime = 0
                isPlaying = false
            }
        }
    }
    @Published var currentTime: Double = 0        // simulated seconds into the program
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
        selectedLayer != nil && moveCount > 0 && currentTime < totalTime - 1e-9
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
        guard let doc = preview?.document else {
            selectedLayer = nil
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
