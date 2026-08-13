import SwiftUI

/// Floating glass transport bar over the toolpath canvas: scrub through
/// simulated machine time or play back — 1× runs at 100% of real machining
/// speed (feed-rate accurate). The program itself is picked in the sidebar.
struct PlaybackControls: View {
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState

    var body: some View {
        if playback.layer != nil {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    Button {
                        playback.isPlaying = false
                        playback.currentTime = 0
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(playback.totalTime <= 0 || playback.currentTime == 0)
                    .help("Rewind to the start of the program")

                    Button {
                        if playback.currentTime >= playback.totalTime {
                            playback.currentTime = 0
                        }
                        playback.isPlaying.toggle()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(playback.totalTime <= 0)
                    .help("Play/pause a feed-rate-accurate simulation — at 1× it runs exactly as long as the real machining")

                    Text(paddedCurrentTime)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Slider(value: timeBinding, in: 0...max(playback.totalTime, 0.001))
                        .controlSize(.small)
                        .disabled(playback.totalTime <= 0)
                        .help("Scrub through machine time. Completed moves draw solid, the rest ghosted; the G-code tab follows the current line.")

                    Text(formatDuration(playback.totalTime))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $playback.speedMultiplier) {
                        Text("1× real").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("5×").tag(5.0)
                        Text("10×").tag(10.0)
                        Text("50×").tag(50.0)
                        Text("200×").tag(200.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Playback speed relative to real machining time (feed-rate accurate)")
                }

                Text(readout)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 760)
        }
    }

    private var timeBinding: Binding<Double> {
        Binding(
            get: { playback.currentTime },
            set: { newValue in
                playback.isPlaying = false
                playback.currentTime = min(playback.totalTime, max(0, newValue))
            }
        )
    }

    /// Current time padded to the total's width so the slider never shifts
    /// when the minute count gains a digit.
    private var paddedCurrentTime: String {
        let total = formatDuration(playback.totalTime)
        var current = formatDuration(playback.currentTime)
        while current.count < total.count { current = " " + current }
        return current
    }

    /// Every field has a fixed width (numbers padded to their maximum, kind and
    /// feed padded to their longest variant), so values never push each other
    /// around while the program plays.
    private var readout: String {
        guard let layer = playback.layer else { return "" }
        guard let move = playback.currentMove, let position = playback.toolPosition, let z = playback.toolZ else {
            return "\(layer.displayName) · \(layer.moves.count) moves · est. \(formatDuration(layer.totalTime)) total"
        }
        let kind = switch move.kind {
        case .rapid: "rapid "
        case .cut: "cut   "
        case .plunge: "plunge"
        }
        let feed = Int(move.kind == .rapid ? GCodeParser.assumedRapidFeed : (move.feed ?? 0))
        let moveIndex = pad(min(playback.completedMoves + 1, playback.moveCount), like: playback.moveCount)
        return "move \(moveIndex)/\(playback.moveCount)"
            + " · line \(pad(move.sourceLine, like: layer.lineCount))"
            + " · \(kind)"
            + String(format: " · X%7.2f Y%7.2f Z%7.3f", position.x, position.y, z)
            + " · F\(pad(feed, like: 9999))"
    }

    /// Left-pads `value` with spaces to the digit count of `reference`.
    private func pad(_ value: Int, like reference: Int) -> String {
        let width = String(reference).count
        var s = String(value)
        while s.count < width { s = " " + s }
        return s
    }
}
