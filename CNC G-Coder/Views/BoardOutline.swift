import Foundation

/// The board's shape, read from the outline program: the channel that
/// program cuts (its cutting runs inflated by the tool radius, as
/// `GrooveMesh` draws it) has the board as its inner ring — pcb2gcode
/// offsets the outline cut outward, so the channel's inner wall is the
/// board edge. The 3D view masks the copper faces to this polygon, walls
/// the slab along it and clips every groove to it, so the board is drawn
/// as the outline Gerber describes it instead of as the rectangle round it.
nonisolated enum BoardOutline {
    /// Inner rings smaller than this (mm²) are not a board.
    static let minimumArea = 4.0

    /// Outer rings (counter-clockwise, Y up) in the program's frame, or nil
    /// without a closed cut.
    static func polygon(outline layer: ParsedLayer) -> Clipper.Paths? {
        let r = max((layer.toolDiameter ?? GrooveMesh.fallbackToolWidth) / 2, 0.02)
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        func flush() {
            if current.count >= 2 { runs.append(current) }
            current = []
        }
        for move in layer.moves {
            let planar = hypot(move.end.x - move.start.x, move.end.y - move.start.y) > 1e-6
            guard (move.kind == .cut || move.kind == .plunge), move.zEnd < -1e-9, planar else {
                flush()
                continue
            }
            if current.last != move.start {
                flush()
                current = [move.start]
            }
            current.append(move.end)
        }
        flush()
        guard !runs.isEmpty else { return nil }
        let channel = Clipper.inflate(runs, by: r, join: .round, end: .round, arcTolerance: GrooveMesh.arcTolerance)
        let boards = channel.filter { Clipper.area($0) < 0 && -Clipper.area($0) >= minimumArea }
            .map { Array($0.reversed()) }
        return boards.isEmpty ? nil : boards
    }
}
