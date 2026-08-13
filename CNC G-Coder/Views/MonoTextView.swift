import SwiftUI
import AppKit

/// Read-only monospaced text view (NSTextView-backed) that stays responsive on
/// multi-megabyte G-code files. Content is replaced only when `contentVersion`
/// changes; `highlightRange` marks the current playback line.
struct MonoTextView: NSViewRepresentable {
    var text: String
    var contentVersion: Int
    var autoScrollToBottom = false
    var highlightRange: NSRange?

    final class Coordinator {
        var lastVersion = Int.min
        var lastHighlight: NSRange?
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
        guard let textView = scroll.documentView as? NSTextView else { return }

        if context.coordinator.lastVersion != contentVersion {
            context.coordinator.lastVersion = contentVersion
            context.coordinator.lastHighlight = nil
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor
            ]))
            if autoScrollToBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }

        if context.coordinator.lastHighlight != highlightRange, let storage = textView.textStorage {
            if let old = context.coordinator.lastHighlight, old.location + old.length <= storage.length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
            if let new = highlightRange, new.location + new.length <= storage.length {
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.findHighlightColor.withAlphaComponent(0.45),
                                     range: new)
                textView.scrollRangeToVisible(new)
            }
            context.coordinator.lastHighlight = highlightRange
        }
    }
}
