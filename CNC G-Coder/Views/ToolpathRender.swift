import SwiftUI

/// Pre-built stroke paths for one layer under a 2D mapping (top view, side
/// projection, or profile), with prefix checkpoints so playback scrubbing can
/// rebuild "everything up to move N" cheaply.
struct MappedPaths {
    static let checkpointInterval = 1000

    var cutFull = Path()
    var travelFull = Path()
    var segments: [(p0: CGPoint, p1: CGPoint, kind: MoveKind)] = []
    // checkpoint k covers the first k * checkpointInterval moves
    var cutCheckpoints: [Path] = [Path()]
    var travelCheckpoints: [Path] = [Path()]

    /// `map` converts a move (plus the cumulative distance at its start) into
    /// a 2D segment in "world" coordinates for the particular view.
    static func build(moves: [ToolpathMove], map: (ToolpathMove, Double) -> (CGPoint, CGPoint)) -> MappedPaths {
        var result = MappedPaths()
        result.segments.reserveCapacity(moves.count)
        var cut = Path()
        var travel = Path()
        var previousDistance = 0.0
        var lastCutPoint: CGPoint?
        var lastTravelPoint: CGPoint?

        for (index, move) in moves.enumerated() {
            let (p0, p1) = map(move, previousDistance)
            previousDistance = move.cumulativeDistance
            result.segments.append((p0, p1, move.kind))

            switch move.kind {
            case .cut, .plunge:
                if lastCutPoint != p0 { cut.move(to: p0) }
                cut.addLine(to: p1)
                lastCutPoint = p1
            case .rapid:
                if lastTravelPoint != p0 { travel.move(to: p0) }
                travel.addLine(to: p1)
                lastTravelPoint = p1
            }

            if (index + 1) % checkpointInterval == 0 {
                result.cutCheckpoints.append(cut)
                result.travelCheckpoints.append(travel)
            }
        }
        result.cutFull = cut
        result.travelFull = travel
        return result
    }

    /// Paths covering the first `count` moves (checkpoint + remainder).
    func prefix(_ count: Int) -> (cut: Path, travel: Path) {
        let n = min(max(count, 0), segments.count)
        if n >= segments.count { return (cutFull, travelFull) }
        let k = min(n / Self.checkpointInterval, cutCheckpoints.count - 1)
        var cut = cutCheckpoints[k]
        var travel = travelCheckpoints[k]
        for index in (k * Self.checkpointInterval)..<n {
            let segment = segments[index]
            switch segment.kind {
            case .cut, .plunge:
                cut.move(to: segment.p0)
                cut.addLine(to: segment.p1)
            case .rapid:
                travel.move(to: segment.p0)
                travel.addLine(to: segment.p1)
            }
        }
        return (cut, travel)
    }
}

extension LayerKind {
    var color: Color {
        switch self {
        case .front: .blue
        case .back: .green
        case .outline: .orange
        case .drill(let index, _):
            [Color.purple, .pink, .teal, .indigo][index % 4]
        case .maskTop: .cyan
        case .maskBottom: .brown
        case .test: .mint
        }
    }
}
