import SwiftUI
import AppKit
import Combine

/// The Program tab of the Machine window: the shared `ProgramControls` with
/// the exact text that will be streamed in the middle, the current line
/// highlighted and error lines marked.
struct ProgramTab: View {
    @Bindable var machine: MachineController
    @Binding var tab: MachineTab
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ProgramTabBody(machine: machine, tab: $tab, player: model.player)
    }
}

/// Split from `ProgramTab` so the playback state is observed explicitly
/// (`@ObservedObject`): the job identity is what the text follows.
private struct ProgramTabBody: View {
    @Bindable var machine: MachineController
    @Binding var tab: MachineTab
    @ObservedObject var player: PlaybackState

    @State private var text = ""
    @State private var textVersion = 0

    private var streamer: JobStreamer { machine.streamer }

    var body: some View {
        ProgramControls(machine: machine, navigate: { tab = $0 }) {
            textBody
        }
        .onAppear { reloadText() }
        .onChange(of: streamer.program?.token) { _, _ in reloadText() }
    }

    private var textBody: some View {
        PlaybackTimeReader(clock: player.clock) {
            ProgramTextView(text: text, version: textVersion, currentLine: currentLine, errorLines: Set(streamer.lineErrors.keys))
        }
    }

    /// The source line of the position-matched move while the job runs.
    private var currentLine: Int? {
        guard streamer.isActive, player.job != nil else { return nil }
        return player.currentMove?.sourceLine
    }

    private func reloadText() {
        text = streamer.program?.lines.joined(separator: "\n") ?? ""
        textVersion += 1
    }
}

/// Read-only monospaced program text with the line being executed
/// highlighted (scrolled into view) and rejected lines tinted red. The
/// UTF-16 line offsets are computed once per text version.
struct ProgramTextView: NSViewRepresentable {
    var text: String
    var version: Int
    var currentLine: Int?
    var errorLines: Set<Int>

    final class Coordinator {
        var lastVersion = Int.min
        var lineStarts: [Int] = []
        var utf16Length = 0
        var lastCurrent: Int?
        var lastErrors: Set<Int> = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let c = context.coordinator

        if c.lastVersion != version {
            c.lastVersion = version
            c.lastCurrent = nil
            c.lastErrors = []
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]))
            var starts = [0]
            var offset = 0
            for unit in text.utf16 {
                offset += 1
                if unit == 10 { starts.append(offset) }
            }
            c.lineStarts = starts
            c.utf16Length = offset
            textView.scroll(.zero)
        }

        if c.lastErrors != errorLines {
            for line in c.lastErrors.subtracting(errorLines) {
                if let range = range(of: line, c) { storage.removeAttribute(.backgroundColor, range: range) }
            }
            for line in errorLines {
                if let range = range(of: line, c) {
                    storage.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.35), range: range)
                }
            }
            c.lastErrors = errorLines
            c.lastCurrent = nil   // re-apply the current line over the error tint
        }

        if c.lastCurrent != currentLine {
            if let old = c.lastCurrent, !errorLines.contains(old), let range = range(of: old, c) {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            if let new = currentLine, let range = range(of: new, c) {
                storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), range: range)
                textView.scrollRangeToVisible(range)
            }
            c.lastCurrent = currentLine
        }
    }

    /// UTF-16 range of a 1-based line, nil when out of range.
    private func range(of line: Int, _ c: Coordinator) -> NSRange? {
        guard line >= 1, line <= c.lineStarts.count else { return nil }
        let start = c.lineStarts[line - 1]
        let end = line < c.lineStarts.count ? c.lineStarts[line] : c.utf16Length
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
